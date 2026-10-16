import AppKit
import OrbitAPI
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// A Markdown file rendered as it changes, unsaved edits included (D89).
struct MarkdownPreview: View {
    let url: URL
    let workspace: Workspace
    let highlighter: SyntaxHighlighting?

    var body: some View {
        // The open buffer when there is one, else the disk (re-read when it changes).
        let text = workspace.documents.existingDocument(for: url)?.text
            ?? { _ = workspace.fileSystemGeneration; return try? String(contentsOf: url, encoding: .utf8) }()
            ?? ""
        MarkdownWebView(text: text, url: url, workspace: workspace, highlighter: highlighter)
    }
}

private struct MarkdownWebView: NSViewRepresentable {
    let text: String
    let url: URL
    let workspace: Workspace
    let highlighter: SyntaxHighlighting?

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(LocalFileScheme(), forURLScheme: LocalFileScheme.scheme)
        // The file's own HTML can't run scripts; only ours (setting the body) runs.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        context.coordinator.view = view
        view.loadHTMLString(MarkdownPage.template, baseURL: url.deletingLastPathComponent())
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.workspace = workspace
        context.coordinator.update(text: text, url: url, highlighter: highlighter)
    }

    func makeCoordinator() -> Coordinator { Coordinator(workspace: workspace) }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var view: WKWebView?
        var workspace: Workspace
        private var isLoaded = false
        private var rendered: String?
        private var pending: (text: String, url: URL, highlighter: SyntaxHighlighting?)?
        private var renderTask: Task<Void, Never>?

        init(workspace: Workspace) {
            self.workspace = workspace
        }

        func update(text: String, url: URL, highlighter: SyntaxHighlighting?) {
            guard text != rendered else { return }
            pending = (text, url, highlighter)
            guard isLoaded else { return }
            renderTask?.cancel()
            // Typing re-renders at most every 150 ms.
            renderTask = Task {
                if rendered != nil { try? await Task.sleep(for: .milliseconds(150)) }
                guard !Task.isCancelled, let pending else { return }
                await render(pending.text, url: pending.url, highlighter: pending.highlighter)
            }
        }

        private func render(_ text: String, url: URL, highlighter: SyntaxHighlighting?) async {
            let directory = url.deletingLastPathComponent()
            var blocks: [(code: String, language: String)] = []
            var html = MarkdownHTML.render(text, options: .init(
                resolveImage: { LocalFileScheme.url(for: $0, relativeTo: directory) },
                code: { code, language in
                    blocks.append((code, language))
                    return "\u{0}CODE\(blocks.count - 1)\u{0}"
                }
            ))
            for (index, block) in blocks.enumerated() {
                let colored = await MarkdownPage.highlight(block.code, language: block.language, highlighter: highlighter)
                guard !Task.isCancelled else { return }
                html = html.replacingOccurrences(of: "\u{0}CODE\(index)\u{0}", with: colored)
            }
            rendered = text
            _ = try? await view?.callAsyncJavaScript("document.body.innerHTML = html", arguments: ["html": html], contentWorld: .defaultClient)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !isLoaded else { return }
            isLoaded = true
            if let pending { rendered = nil; update(text: pending.text, url: pending.url, highlighter: pending.highlighter) }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard action.navigationType == .linkActivated, let target = action.request.url else { return .allow }
            if target.fragment != nil, target.path == webView.url?.path || target.scheme == "about" {
                return .allow
            }
            if target.isFileURL || target.scheme == LocalFileScheme.scheme {
                let file = target.scheme == LocalFileScheme.scheme ? URL(fileURLWithPath: target.path) : target
                if FileManager.default.fileExists(atPath: file.path) {
                    workspace.openFile(file)
                    return .cancel
                }
            }
            NSWorkspace.shared.open(target)
            return .cancel
        }
    }
}

/// Serves local files (images next to the Markdown) to the page: a page from
/// `loadHTMLString` may not read `file:` URLs.
final class LocalFileScheme: NSObject, WKURLSchemeHandler {
    static let scheme = "orbit-file"

    static func url(for source: String, relativeTo directory: URL) -> String {
        if let url = URL(string: source), let scheme = url.scheme, scheme != "file" { return source }
        let path = source.hasPrefix("file://") ? (URL(string: source)?.path ?? source) : source
        let file = path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path.removingPercentEncoding ?? path)
        var components = URLComponents()
        components.scheme = scheme
        components.host = ""
        components.path = file.standardizedFileURL.path
        return components.string ?? source
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let data = FileManager.default.contents(atPath: url.path) else {
            task.didFailWithError(CocoaError(.fileNoSuchFile))
            return
        }
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

enum MarkdownPage {
    private static let aliases = [
        "typescript": "ts", "javascript": "js", "python": "py", "rust": "rs", "ruby": "rb", "kotlin": "kt",
        "shell": "sh", "bash": "sh", "zsh": "sh", "console": "sh", "yaml": "yml", "markdown": "md", "csharp": "cs",
        "c#": "cs", "c++": "cpp", "golang": "go", "objective-c": "m", "objc": "m", "elixir": "ex", "haskell": "hs",
    ]

    @MainActor
    static func highlight(_ code: String, language: String, highlighter: SyntaxHighlighting?) async -> String {
        let name = language.lowercased()
        guard let highlighter, !name.isEmpty else { return MarkdownHTML.escape(code) }
        let spans = await highlighter.highlight(code, as: URL(fileURLWithPath: "code.\(aliases[name] ?? name)"))
        guard !spans.isEmpty else { return MarkdownHTML.escape(code) }
        let text = code as NSString
        var html = "", position = 0
        for span in spans.sorted(by: { $0.range.location < $1.range.location }) where span.range.location >= position {
            let end = min(NSMaxRange(span.range), text.length)
            guard span.range.location < end else { continue }
            html += MarkdownHTML.escape(text.substring(with: NSRange(location: position, length: span.range.location - position)))
            html += "<span style=\"color:\(hex(span.color))\">\(MarkdownHTML.escape(text.substring(with: NSRange(location: span.range.location, length: end - span.range.location))))</span>"
            position = end
        }
        return html + MarkdownHTML.escape(text.substring(from: min(position, text.length)))
    }

    @MainActor
    private static func hex(_ color: Color) -> String {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return "inherit" }
        return String(format: "#%02x%02x%02x", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
    }

    /// GitHub's layout in the system font and colors; the window's theme shows through.
    static let template = """
    <!doctype html>
    <html><head><meta charset="utf-8">
    <style>
    :root { color-scheme: light dark; }
    html { background: transparent; }
    body { font: 14px/1.6 -apple-system, sans-serif; color: -apple-system-label; max-width: 820px;
           margin: 0 auto; padding: 24px 32px 64px; word-wrap: break-word; -webkit-font-smoothing: antialiased; }
    h1, h2, h3, h4, h5, h6 { font-weight: 600; line-height: 1.25; margin: 24px 0 12px; }
    h1 { font-size: 2em; padding-bottom: .3em; border-bottom: 1px solid -apple-system-separator; }
    h2 { font-size: 1.5em; padding-bottom: .3em; border-bottom: 1px solid -apple-system-separator; }
    h3 { font-size: 1.25em; } h4 { font-size: 1em; } h5 { font-size: .875em; }
    h6 { font-size: .85em; color: -apple-system-secondary-label; }
    body > :first-child { margin-top: 0; }
    p, ul, ol, blockquote, pre, table { margin: 0 0 16px; }
    a { color: -apple-system-control-accent; text-decoration: none; }
    a:hover { text-decoration: underline; }
    ul, ol { padding-left: 2em; }
    li > p { margin: 0; }
    li + li { margin-top: .25em; }
    li:has(> p > input[type=checkbox]), li:has(> input[type=checkbox]) { list-style: none; margin-left: -1.4em; }
    code { font: 12px ui-monospace, SFMono-Regular, Menlo, monospace; background: rgba(128,128,128,.14);
           padding: .15em .4em; border-radius: 5px; }
    pre { background: rgba(128,128,128,.09); padding: 12px 14px; border-radius: 10px; overflow: auto; line-height: 1.45; }
    pre code { background: none; padding: 0; font-size: 12px; }
    blockquote { margin-left: 0; padding: 0 1em; color: -apple-system-secondary-label;
                 border-left: 3px solid -apple-system-separator; }
    hr { border: none; height: 1px; background: -apple-system-separator; margin: 24px 0; }
    table { border-collapse: collapse; display: block; overflow: auto; }
    th, td { border: 1px solid -apple-system-separator; padding: 6px 13px; }
    th { font-weight: 600; }
    tr:nth-child(2n) td { background: rgba(128,128,128,.05); }
    img { max-width: 100%; }
    table.front-matter { display: table; width: 100%; font-size: 12.5px; }
    table.front-matter th { text-align: left; vertical-align: top; white-space: nowrap; width: 1%;
                            color: -apple-system-secondary-label; font-weight: 500; }
    table.front-matter td { background: none; }
    del { color: -apple-system-secondary-label; }
    </style>
    </head><body></body></html>
    """
}
