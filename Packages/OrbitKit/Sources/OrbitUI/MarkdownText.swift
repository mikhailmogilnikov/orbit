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
                }
            }
        }
    }

    enum Segment {
        case prose(String)
        case code(language: String, code: String)
    }

    static func segments(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var prose: [Substring] = []
        var code: [Substring] = []
        var language: String?

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
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
        let joined = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
        if !joined.isEmpty { segments.append(.prose(joined)) }
        return segments
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

    private var colored: AttributedString {
        var result = AttributedString(code)
        for span in spans {
            guard let range = Range(span.range, in: code), let attributed = Range(range, in: result) else { continue }
            result[attributed].foregroundColor = span.color
        }
        return result
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
                Text(code)
                    .font(.orbit(.code))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.smallCorner))
        .overlay(RoundedRectangle(cornerRadius: Theme.smallCorner).strokeBorder(Theme.hairline))
    }
}
