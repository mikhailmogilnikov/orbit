import OrbitAPI
import SwiftUI

/// Lightweight Markdown renderer for agent output: fenced code blocks become
/// monospaced cards, everything else uses SwiftUI's inline Markdown.
public struct MarkdownText: View {
    public enum CodeStyle: Sendable {
        /// A card with the language and a copy button (agent output).
        case card
        /// Just the code in code type, as in the editor's popups.
        case plain
    }

    let text: String
    let codeStyle: CodeStyle
    /// Colors for a plain code block: its text and the language its fence names.
    let highlight: (@MainActor (_ code: String, _ language: String) async -> [SyntaxSpan])?

    public init(
        _ text: String, codeStyle: CodeStyle = .card,
        highlight: (@MainActor (_ code: String, _ language: String) async -> [SyntaxSpan])? = nil
    ) {
        self.text = text
        self.codeStyle = codeStyle
        self.highlight = highlight
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.segments(text).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let prose):
                    Text(Self.attributed(prose))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let language, let code):
                    switch codeStyle {
                    case .card:
                        CodeBlockView(language: language, code: code)
                    case .plain:
                        PlainCodeView(code: code, language: language, highlight: highlight)
                    }
                case .details(let summary, let body):
                    DetailsBlockView(summary: summary) {
                        MarkdownText(body, codeStyle: codeStyle, highlight: highlight)
                    }
                case .image(let alt, let source):
                    ImageBlockView(alt: alt, source: source)
                }
            }
        }
    }

    enum Segment: Equatable {
        case prose(String)
        case code(language: String, code: String)
        /// HTML `<details>` agents put around screenshots and logs: folded, like GitHub.
        case details(summary: String, body: String)
        /// An image alone on its line (`![alt](path)`); inline Markdown drops images.
        case image(alt: String, source: String)
    }

    static func segments(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var prose: [Substring] = []
        var code: [Substring] = []
        var language: String?
        var details: [Substring] = []
        var detailsDepth = 0

        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty { segments.append(.prose(joined)) }
            prose.removeAll()
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if language == nil, detailsDepth > 0 || trimmed.lowercased().hasPrefix("<details") {
                if detailsDepth == 0 { flushProse() }
                let lower = trimmed.lowercased()
                detailsDepth += lower.components(separatedBy: "<details").count - 1
                detailsDepth -= lower.components(separatedBy: "</details>").count - 1
                details.append(line)
                if detailsDepth <= 0 {
                    segments.append(detailsSegment(details.joined(separator: "\n")))
                    details.removeAll()
                    detailsDepth = 0
                }
            } else if language == nil, let image = imageSegment(trimmed) {
                flushProse()
                segments.append(image)
            } else if trimmed.hasPrefix("```") {
                if let lang = language {
                    segments.append(.code(language: lang, code: code.joined(separator: "\n")))
                    code.removeAll()
                    language = nil
                } else {
                    let joined = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
                    if !joined.isEmpty { segments.append(.prose(joined)) }
                    prose.removeAll()
                    language = String(trimmed.dropFirst(3))
                }
            } else if language != nil {
                code.append(line)
            } else {
                prose.append(line)
            }
        }
        if let lang = language {
            // Unterminated fence while streaming.
            segments.append(.code(language: lang, code: code.joined(separator: "\n")))
        }
        if !details.isEmpty { segments.append(detailsSegment(details.joined(separator: "\n"))) }
        flushProse()
        return segments
    }

    /// The outer tags off, the summary out; what's left is Markdown again.
    private static func detailsSegment(_ html: String) -> Segment {
        var body = html
        for pattern in [#"^\s*<details[^>]*>"#, #"</details>\s*$"#] {
            if let range = body.range(of: pattern, options: [.regularExpression, .caseInsensitive]) { body.removeSubrange(range) }
        }
        var summary = "Details"
        if let range = body.range(of: #"<summary[^>]*>[\s\S]*?</summary>"#, options: [.regularExpression, .caseInsensitive]) {
            let tag = String(body[range])
            let text = tag.replacingOccurrences(of: #"</?summary[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { summary = text }
            body.removeSubrange(range)
        }
        return .details(summary: summary, body: body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func imageSegment(_ line: String) -> Segment? {
        guard line.hasPrefix("!["), line.hasSuffix(")"),
              let close = line.range(of: "]("), close.lowerBound > line.index(line.startIndex, offsetBy: 1) else { return nil }
        let alt = String(line[line.index(line.startIndex, offsetBy: 2)..<close.lowerBound])
        var source = String(line[close.upperBound..<line.index(before: line.endIndex)]).trimmingCharacters(in: .whitespaces)
        if source.hasPrefix("<"), source.hasSuffix(">") { source = String(source.dropFirst().dropLast()) }
        return source.isEmpty ? nil : .image(alt: alt, source: source)
    }

    /// While a reply streams in, its earlier paragraphs come back unchanged on
    /// every chunk; parsing all of it again each time made long replies quadratic.
    private static let attributedCache: NSCache<NSString, AttributedBox> = {
        let cache = NSCache<NSString, AttributedBox>()
        cache.totalCostLimit = 4_000_000
        return cache
    }()

    /// Parsed a paragraph at a time (inline Markdown doesn't span blank lines).
    static func attributed(_ prose: String) -> AttributedString {
        var result = AttributedString()
        for (index, paragraph) in prose.components(separatedBy: "\n\n").enumerated() {
            if index > 0 { result.append(AttributedString("\n\n")) }
            if let cached = attributedCache.object(forKey: paragraph as NSString) {
                result.append(cached.value)
            } else {
                let value = parse(paragraph)
                attributedCache.setObject(AttributedBox(value), forKey: paragraph as NSString, cost: paragraph.utf16.count)
                result.append(value)
            }
        }
        return result
    }

    private static func parse(_ prose: String) -> AttributedString {
        // Headings and bullets aren't supported by inline parsing; normalize them.
        let normalized = prose.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var line = String(line)
            if let range = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                line = "**" + line[range.upperBound...] + "**"
            } else if let range = line.range(of: #"^(\s*)[-*]\s+"#, options: .regularExpression) {
                let indent = line[range].prefix { $0 == " " }
                line = indent + "•  " + line[range.upperBound...]
            }
            return line
        }.joined(separator: "\n")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: normalized, options: options)) ?? AttributedString(prose)
    }
}

private final class AttributedBox {
    let value: AttributedString
    init(_ value: AttributedString) { self.value = value }
}

/// Code in code type, colored once the highlighter answers.
private struct PlainCodeView: View {
    let code: String
    let language: String
    let highlight: (@MainActor (_ code: String, _ language: String) async -> [SyntaxSpan])?
    @State private var spans: [SyntaxSpan] = []

    var body: some View {
        Text(colored)
            .font(.orbit(.code))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .task(id: code) {
                spans = await highlight?(code, language) ?? []
            }
    }

    private var colored: AttributedString { HighlightedCode.colored(code, spans) }
}

/// Code colored by the environment's highlighter (`syntaxHighlighter`), in
/// the language a fence names; plain until it answers or without one.
public struct HighlightedCode: View {
    let code: String
    let language: String
    @Environment(\.syntaxHighlighter) private var highlighter
    @State private var spans: [SyntaxSpan] = []

    public init(_ code: String, language: String) {
        self.code = code
        self.language = language
    }

    public var body: some View {
        Text(Self.colored(code, spans))
            .task(id: "\(language)\n\(code)") {
                guard let highlighter, !language.isEmpty else { return }
                spans = await highlighter.highlight(code, language: language)
            }
    }

    static func colored(_ code: String, _ spans: [SyntaxSpan]) -> AttributedString {
        var result = AttributedString(code)
        for span in spans {
            guard let range = Range(span.range, in: code), let attributed = Range(range, in: result) else { continue }
            result[attributed].foregroundColor = span.color
        }
        return result
    }
}

/// A `<details>` block: its summary as a line that opens it.
private struct DetailsBlockView<Content: View>: View {
    let summary: String
    @ViewBuilder let content: Content
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Text(summary)
                    DisclosureChevron(isExpanded: isExpanded)
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if isExpanded {
                content
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.hairline).frame(width: 2) }
            }
        }
    }
}

/// A local image (a screenshot the agent took); remote or missing ones show their alt text.
private struct ImageBlockView: View {
    let alt: String
    let source: String
    @State private var image: NSImage?
    @State private var isLoaded = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: min(image.size.width, 480), maxHeight: 320, alignment: .leading)
                    .clipShape(.rect(cornerRadius: Theme.smallCorner))
                    .overlay(RoundedRectangle(cornerRadius: Theme.smallCorner).strokeBorder(Theme.hairline))
                    .onTapGesture { if let url { NSWorkspace.shared.open(url) } }
                    .help(alt.isEmpty ? "Open the image" : alt)
            } else if isLoaded {
                Label(alt.isEmpty ? source : alt, systemImage: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: source) {
            image = url.flatMap { NSImage(contentsOf: $0) }
            isLoaded = true
        }
    }

    private var url: URL? {
        if source.hasPrefix("file://") { return URL(string: source) }
        let path = (source as NSString).expandingTildeInPath
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : nil
    }
}

struct CodeBlockView: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Copy")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider().opacity(0.5)
            ScrollView(.horizontal, showsIndicators: false) {
                HighlightedCode(code, language: language)
                    .font(.orbit(.code))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.smallCorner))
        .overlay(RoundedRectangle(cornerRadius: Theme.smallCorner).strokeBorder(Theme.hairline))
    }
}
