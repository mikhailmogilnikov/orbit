import OrbitAPI
import SwiftUI

/// Images and PDFs open in a viewer instead of the text editor; Markdown gets
/// a live preview tab (D89).
public final class PreviewPlugin: OrbitPlugin {
    public static let manifest = PluginManifest(
        id: "orbit.preview",
        name: "Preview",
        summary: "View images and PDFs, preview Markdown.",
        systemImage: "eye"
    )

    static let markdownKind = "markdown.preview"
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "ico", "icns", "avif"]
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdx", "mdown"]

    private var browser: BrowserStore?
    private let svgSource = SVGSourceMode()

    public init() {}

    public func deactivate() {
        browser?.closeAll()
    }

    public func activate(_ context: PluginContext) {
        let workspace = context.workspace
        let services = context.services
        let commands = context.commands
        registerBrowser(context)

        // Above the text editor (priority 0) for files it can't show.
        context.ui.addEditorProvider(EditorProvider(
            id: "preview.media",
            priority: 10,
            accepts: { tab in
                guard tab.kind == EditorTab.fileKind, let ext = tab.url?.pathExtension.lowercased() else { return false }
                return Self.imageExtensions.contains(ext) || ext == "pdf"
            }
        ) { tab in
            MediaView(url: tab.url!, workspace: workspace)
                .id(tab.id)
        })

        context.ui.addEditorProvider(EditorProvider(
            id: "preview.markdown",
            accepts: { $0.kind == Self.markdownKind && $0.url != nil }
        ) { tab in
            MarkdownPreview(url: tab.url!, workspace: workspace, highlighter: services.resolve(SyntaxHighlighting.self))
                .overlay(alignment: .topTrailing) {
                    Button {
                        commands.run("preview.markdown", teaching: true)
                    } label: {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.orbit(.body))
                            .frame(width: 22, height: 20)
                    }
                    .buttonStyle(.glass)
                    .help(commands.help("preview.markdown", "Show Source"))
                    .padding(10)
                }
                .id(tab.id)
        })

        // An SVG opens as its picture, in its own tab; Show Source flips that tab to the code (D145).
        let svgSource = svgSource
        context.ui.addEditorProvider(EditorProvider(
            id: "preview.svg",
            priority: 10,
            accepts: { tab in
                guard tab.kind == EditorTab.fileKind, let url = tab.url, url.pathExtension.lowercased() == "svg" else { return false }
                return !svgSource.showsSource.contains(url.standardizedFileURL)
            }
        ) { tab in
            SVGPreview(url: tab.url!, workspace: workspace)
                .overlay(alignment: .topTrailing) {
                    Button {
                        commands.run("preview.markdown", teaching: true)
                    } label: {
                        Label("Show Source", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    .buttonStyle(.glass)
                    .help(commands.help("preview.markdown", "Show Source"))
                    .padding(10)
                }
                .id(tab.id)
        })

        // Markdown's preview to the side, and an SVG's picture / source in its tab (D145);
        // the id stays for shortcuts set before SVG joined.
        context.commands.register(OrbitCommand(
            id: "preview.markdown",
            title: "Toggle Preview",
            category: "File",
            systemImage: "eye",
            shortcut: KeyboardShortcut("v", modifiers: [.command, .shift]),
            isEnabled: { Self.markdownURL(workspace) != nil || workspace.activeTab?.url?.pathExtension.lowercased() == "svg" }
        ) {
            if let tab = workspace.activeTab, tab.kind == EditorTab.fileKind, let url = tab.url?.standardizedFileURL, url.pathExtension.lowercased() == "svg" {
                if svgSource.showsSource.contains(url) { svgSource.showsSource.remove(url) } else { svgSource.showsSource.insert(url) }
                return
            }
            guard let url = Self.markdownURL(workspace) else { return }
            let preview = Self.previewTab(for: url)
            if workspace.activeTab?.kind == Self.markdownKind {
                // Back to the source, on whichever side it is.
                workspace.openFile(url)
            } else if workspace.tabs.contains(where: { $0.id == preview.id }) {
                workspace.open(preview)
            } else {
                // Beside the source, which keeps focus for typing (D90).
                workspace.openBeside(preview)
            }
        })
        context.ui.addEditorAction(EditorAction(commandID: "preview.markdown", systemImage: "eye") { url in
            Self.previewExtensions.contains(url.pathExtension.lowercased())
        })
    }

    /// Web pages in editor tabs, for a dev server's localhost first (D143).
    private func registerBrowser(_ context: PluginContext) {
        let store = BrowserStore(workspace: context.workspace)
        browser = store
        let services = context.services
        context.services.register(WebPreviewing.self, store)
        context.ui.addEditorProvider(EditorProvider(id: "preview.browser", accepts: { $0.kind == BrowserStore.kind }) { tab in
            if let page = store.page(for: tab) {
                BrowserView(page: page, store: store).id(tab.id)
            }
        })
        let ui = context.ui
        context.commands.register(OrbitCommand(
            id: "preview.browser",
            title: "Open Browser…",
            category: "View",
            systemImage: "globe"
        ) {
            let servers = services.resolve(LocalServers.self)?.localURLs ?? []
            ui.presentQuickPick(QuickPick(id: "browser", placeholder: "Address, e.g. localhost:3000") { query in
                var urls: [URL] = []
                if let typed = BrowserPage.address(query) { urls.append(typed) }
                for url in servers + store.recent + [URL(string: "http://localhost:3000")!] where !urls.contains(url) {
                    guard query.isEmpty || url.absoluteString.localizedCaseInsensitiveContains(query) else { continue }
                    urls.append(url)
                }
                return urls.map { url in
                    QuickPickItem(
                        id: url.absoluteString, title: AttributedString(url.absoluteString),
                        subtitle: servers.contains(url) ? "Printed by a running task" : nil,
                        systemImage: servers.contains(url) ? "play.circle" : "globe"
                    ) { store.openBrowser(url) }
                }
            })
        })
    }

    static var previewExtensions: Set<String> { markdownExtensions.union(["svg"]) }

    /// The active Markdown file, or the file of the active preview (⇧⌘V there goes back to it).
    private static func markdownURL(_ workspace: Workspace) -> URL? {
        guard let tab = workspace.activeTab, let url = tab.url else { return nil }
        if tab.kind == markdownKind { return url }
        return tab.kind == EditorTab.fileKind && markdownExtensions.contains(url.pathExtension.lowercased()) ? url : nil
    }

    static func previewTab(for url: URL) -> EditorTab {
        let url = url.standardizedFileURL
        return EditorTab(id: "preview:\(url.path)", kind: markdownKind, title: "Preview \(url.lastPathComponent)", systemImage: "eye", url: url)
    }
}

/// SVG tabs showing their code instead of their picture (D145).
@MainActor
@Observable
final class SVGSourceMode {
    var showsSource: Set<URL> = []
}

