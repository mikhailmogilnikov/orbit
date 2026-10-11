import SwiftUI

/// Lightweight Markdown renderer for agent output: fenced code blocks become
/// monospaced cards, everything else uses SwiftUI's inline Markdown.
public struct MarkdownText: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.segments(text).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let prose):
                    Text(Self.attributed(prose))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let language, let code):
                    CodeBlockView(language: language, code: code)
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

    static func attributed(_ prose: String) -> AttributedString {
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
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.smallCorner))
        .overlay(RoundedRectangle(cornerRadius: Theme.smallCorner).strokeBorder(Theme.hairline))
    }
}
