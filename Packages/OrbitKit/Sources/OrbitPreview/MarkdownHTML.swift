import Foundation

/// GitHub-flavored Markdown to HTML with Foundation's parser (cmark-gfm under
/// `AttributedString(markdown:)`), so the preview needs no dependency (D89).
/// Code blocks call `code` for their HTML (syntax colors).
enum MarkdownHTML {
    struct Options {
        /// Turns a relative or file link into what the page loads (`orbit-file:`).
        var resolveImage: (String) -> String = { $0 }
        var code: (_ code: String, _ language: String) -> String = { code, _ in escape(code) }
    }

    static func render(_ markdown: String, options: Options = Options()) -> String {
        guard let (fields, body) = frontMatter(markdown) else { return renderBody(markdown, options: options) }
        return frontMatterHTML(fields) + renderBody(body, options: options)
    }

    // MARK: Front matter

    /// YAML between `---` lines at the very top (skills, Jekyll, Hugo, Astro):
    /// its top-level keys, or nil when there's none. A value is what follows
    /// the colon plus its indented or `- ` continuation lines.
    static func frontMatter(_ markdown: String) -> (fields: [(key: String, value: String)], body: String)? {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first.map({ $0.trimmingCharacters(in: .whitespaces) }) == "---",
              let end = lines.dropFirst().firstIndex(where: { ["---", "..."].contains($0.trimmingCharacters(in: .whitespaces)) })
        else { return nil }
        var fields: [(key: String, value: String)] = []
        for line in lines[1..<end] {
            if let match = line.wholeMatch(of: #/([^\s#:][^:]*):(?:\s+(.*))?\s*/#) {
                var value = String(match.2 ?? "")
                if ["|", ">", "|-", ">-"].contains(value) { value = "" }
                fields.append((String(match.1), value))
            } else if !fields.isEmpty, !line.trimmingCharacters(in: .whitespaces).isEmpty, line.first?.isWhitespace == true || line.hasPrefix("-") {
                var item = line.trimmingCharacters(in: .whitespaces)
                let isListItem = item.hasPrefix("- ")
                if isListItem { item = unquote(String(item.dropFirst(2))) }
                let separator = fields[fields.count - 1].value.isEmpty ? "" : (isListItem ? ", " : " ")
                fields[fields.count - 1].value += separator + item
            }
        }
        // Quoted values may span lines: unquoted once whole.
        return (fields.map { ($0.key, unquote($0.value)) }, lines[(end + 1)...].joined(separator: "\n"))
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" else { return value }
        return String(value.dropFirst().dropLast())
    }

    private static func frontMatterHTML(_ fields: [(key: String, value: String)]) -> String {
        guard !fields.isEmpty else { return "" }
        let rows = fields.map { "<tr><th>\(escape($0.key))</th><td>\(escape($0.value))</td></tr>" }.joined(separator: "\n")
        return "<table class=\"front-matter\"><tbody>\n\(rows)\n</tbody></table>\n"
    }

    // MARK: Body

    private static func renderBody(_ markdown: String, options: Options) -> String {
        guard let parsed = try? AttributedString(
            markdown: markdown,
            options: .init(allowsExtendedAttributes: true, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        ) else { return "<pre>\(escape(markdown))</pre>" }

        var html = ""
        var open: [PresentationIntent.IntentType] = []
        var slugs: [String: Int] = [:]
        // A header's text arrives in several runs; its id is written once the header closes.
        var header: (offset: Int, text: String)?
        var codeBlock: (language: String, text: String)?
        var columns: [PresentationIntent.TableColumn] = []
        var isHeaderCell = false

        func close(_ intent: PresentationIntent.IntentType) {
            switch intent.kind {
            case .paragraph: html += "</p>\n"
            case .header(let level):
                if let started = header {
                    let slug = slugify(started.text, &slugs)
                    // After "<hN".
                    html.insert(contentsOf: " id=\"\(slug)\"", at: html.utf8.index(html.startIndex, offsetBy: started.offset + 3))
                    header = nil
                }
                html += "</h\(level)>\n"
            case .orderedList: html += "</ol>\n"
            case .unorderedList: html += "</ul>\n"
            case .listItem: html += "</li>\n"
            case .codeBlock:
                if let block = codeBlock {
                    var code = block.text
                    if code.hasSuffix("\n") { code.removeLast() }
                    let language = block.language.isEmpty ? "" : " class=\"language-\(escape(block.language))\""
                    html += "<pre><code\(language)>\(options.code(code, block.language))</code></pre>\n"
                    codeBlock = nil
                }
            case .blockQuote: html += "</blockquote>\n"
            case .table: html += "</tbody></table>\n"
            case .tableHeaderRow: html += "</tr></thead><tbody>\n"
            case .tableRow: html += "</tr>\n"
            case .tableCell: html += isHeaderCell ? "</th>" : "</td>"
            default: break
            }
        }

        func openBlock(_ intent: PresentationIntent.IntentType) {
            switch intent.kind {
            case .paragraph: html += "<p>"
            case .header(let level):
                header = (html.utf8.count, "")
                html += "<h\(level)>"
            case .orderedList: html += "<ol>\n"
            case .unorderedList: html += "<ul>\n"
            // A list starting at another number than 1.
            case .listItem(let ordinal): html += ordinal != 1 && html.hasSuffix("<ol>\n") ? "<li value=\"\(ordinal)\">" : "<li>"
            case .codeBlock(let language): codeBlock = (language ?? "", "")
            case .blockQuote: html += "<blockquote>\n"
            case .thematicBreak: html += "<hr>\n"
            case .table(let tableColumns):
                columns = tableColumns
                html += "<table>"
            case .tableHeaderRow:
                isHeaderCell = true
                html += "<thead><tr>"
            case .tableRow:
                isHeaderCell = false
                html += "<tr>"
            case .tableCell(let column):
                let tag = isHeaderCell ? "th" : "td"
                let align = column < columns.count ? alignment(columns[column].alignment) : nil
                html += align.map { "<\(tag) style=\"text-align:\($0)\">" } ?? "<\(tag)>"
            default: break
            }
            open.append(intent)
        }

        for run in parsed.runs {
            // Outermost block first.
            let path = Array((run.presentationIntent?.components ?? []).reversed())
            var shared = 0
            while shared < min(path.count, open.count), path[shared].identity == open[shared].identity { shared += 1 }
            while open.count > shared { close(open.removeLast()) }
            for intent in path[shared...] { openBlock(intent) }

            let text = String(parsed[run.range].characters)
            if path.last?.kind == .thematicBreak { continue }
            if codeBlock != nil {
                codeBlock?.text += text
                continue
            }
            if header != nil { header?.text += text }
            html += inline(text, run: run, options: options, isListStart: isListItemStart(path, html: html))
        }
        while let last = open.popLast() { close(last) }
        return html
    }

    /// `[ ]` / `[x]` at the start of a list item's text: a task list checkbox.
    private static func isListItemStart(_ path: [PresentationIntent.IntentType], html: String) -> Bool {
        guard path.count >= 2, case .listItem = path[path.count - 2].kind, path.last?.kind == .paragraph else { return false }
        return html.hasSuffix("<li><p>") || html.hasSuffix("\"><p>")
    }

    private static func inline(_ text: String, run: AttributedString.Runs.Run, options: Options, isListStart: Bool) -> String {
        if let image = run.imageURL {
            return "<img src=\"\(escape(options.resolveImage(image.relativeString)))\" alt=\"\(escape(text))\">"
        }
        let intent = run.inlinePresentationIntent ?? []
        if intent.contains(.blockHTML) || intent.contains(.inlineHTML) { return text }
        var body = escape(text)
        if isListStart, let match = body.firstMatch(of: #/^\[([ xX])\] /#) {
            let checked = match.1 != " " ? " checked" : ""
            body = "<input type=\"checkbox\" disabled\(checked)> " + body[match.range.upperBound...]
        }
        if intent.contains(.lineBreak) { return "<br>\n" }
        if intent.contains(.softBreak) { return "\n" }
        if intent.contains(.code) { body = "<code>\(body)</code>" }
        if intent.contains(.stronglyEmphasized) { body = "<strong>\(body)</strong>" }
        if intent.contains(.emphasized) { body = "<em>\(body)</em>" }
        if intent.contains(.strikethrough) { body = "<del>\(body)</del>" }
        if let link = run.link { body = "<a href=\"\(escape(link.relativeString))\">\(body)</a>" }
        return body
    }

    private static func alignment(_ alignment: PresentationIntent.TableColumn.Alignment) -> String? {
        switch alignment {
        case .center: "center"
        case .right: "right"
        default: nil
        }
    }

    /// GitHub's anchors: lowercased, punctuation dropped, spaces to dashes, `-1`… for repeats.
    static func slugify(_ text: String, _ used: inout [String: Int]) -> String {
        let base = String(text.lowercased().compactMap { character -> Character? in
            if character.isLetter || character.isNumber || character == "-" || character == "_" { return character }
            return character == " " ? "-" : nil
        })
        let count = used[base, default: 0]
        used[base] = count + 1
        return count == 0 ? base : "\(base)-\(count)"
    }

    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            default: result.append(character)
            }
        }
        return result
    }
}
