import AppKit
import OrbitAPI
import STTextView

/// Comments and brackets by the file's language, from Zed's language configs
/// (D73): nothing per language is written here.
@MainActor
enum EditingRules {
    private static func text(_ textView: STTextView) -> NSString {
        ((textView.textContentManager as? NSTextContentStorage)?.textStorage?.string ?? textView.text ?? "") as NSString
    }

    // MARK: ⌘/

    /// Comments the selected lines out with the language's line comment, or back in
    /// when they all are; languages without one (HTML, CSS) wrap them in a block comment.
    static func toggleComment(in textView: STTextView, language: SyntaxLanguage) {
        let string = text(textView)
        let selection = NSIntersectionRange(textView.textSelection, NSRange(location: 0, length: string.length))
        var lines = string.lineRange(for: selection)
        // A selection ending at a line's start doesn't take that line.
        if selection.length > 0, NSMaxRange(selection) == NSMaxRange(lines), NSMaxRange(selection) > 0,
           string.character(at: NSMaxRange(selection) - 1) == 10, NSMaxRange(selection) - 1 >= lines.location {
            lines.length = NSMaxRange(selection) - lines.location
        }
        let block = string.substring(with: lines)
        let replacement: String
        if let prefix = language.lineComments?.first {
            replacement = toggleLineComments(block, prefix: prefix, all: language.lineComments ?? [prefix])
        } else if let pair = language.blockComment, pair.count == 2 {
            replacement = toggleBlockComment(block, start: pair[0], end: pair[1])
        } else {
            return
        }
        guard replacement != block else { return }
        textView.insertText(replacement, replacementRange: lines)
        let length = (replacement as NSString).length
        textView.textSelection = selection.length == 0
            ? NSRange(location: max(lines.location, min(selection.location + length - lines.length, lines.location + length)), length: 0)
            : NSRange(location: lines.location, length: length)
    }

    static func toggleLineComments(_ block: String, prefix: String, all prefixes: [String]) -> String {
        var lines = block.components(separatedBy: "\n")
        let trailingNewline = lines.last == ""
        if trailingNewline { lines.removeLast() }
        let content = lines.indices.filter { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
        guard !content.isEmpty else { return block }
        let bare = prefixes.map { $0.trimmingCharacters(in: .whitespaces) }.sorted { $0.count > $1.count }
        func indent(_ line: String) -> Int { line.prefix { $0 == " " || $0 == "\t" }.count }
        let commented = content.allSatisfy { index in
            let rest = lines[index].dropFirst(indent(lines[index]))
            return bare.contains { rest.hasPrefix($0) }
        }
        if commented {
            for index in content {
                let line = lines[index], width = indent(line)
                var rest = Substring(line.dropFirst(width))
                // The longest marker first: `///` isn't `//` plus a slash.
                if let marker = bare.first(where: { rest.hasPrefix($0) }) {
                    rest = rest.dropFirst(marker.count)
                    if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                }
                lines[index] = String(line.prefix(width)) + rest
            }
        } else {
            let column = content.map { indent(lines[$0]) }.min() ?? 0
            for index in content {
                let line = lines[index]
                lines[index] = String(line.prefix(column)) + prefix + line.dropFirst(column)
            }
        }
        return lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
    }

    static func toggleBlockComment(_ block: String, start: String, end: String) -> String {
        let trailingNewline = block.hasSuffix("\n")
        let body = trailingNewline ? String(block.dropLast()) : block
        let width = body.prefix { $0 == " " || $0 == "\t" }.count
        let indent = String(body.prefix(width))
        let inner = body.dropFirst(width)
        let open = start.trimmingCharacters(in: .whitespaces), close = end.trimmingCharacters(in: .whitespaces)
        let result: String
        if inner.hasPrefix(open), inner.hasSuffix(close), inner.count >= open.count + close.count {
            var middle = inner.dropFirst(open.count).dropLast(close.count)
            if middle.hasPrefix(" ") { middle = middle.dropFirst() }
            if middle.hasSuffix(" ") { middle = middle.dropLast() }
            result = indent + middle
        } else {
            let space = { (marker: String) in marker == marker.trimmingCharacters(in: .whitespaces) ? " " : "" }
            result = indent + start + space(start) + inner + space(end) + end
        }
        return result + (trailingNewline ? "\n" : "")
    }

    // MARK: Brackets

    /// A typed character: closes an opening bracket or quote, wraps a selection
    /// in a pair, or steps over the closing character that's already there.
    /// Returns false to let the text view insert it as usual.
    static func type(_ typed: String, in textView: STTextView, language: SyntaxLanguage) -> Bool {
        guard let brackets = language.brackets, !brackets.isEmpty else { return false }
        let string = text(textView)
        let selection = NSIntersectionRange(textView.textSelection, NSRange(location: 0, length: string.length))
        let next = selection.length == 0 && selection.location < string.length
            ? string.substring(with: string.rangeOfComposedCharacterSequence(at: selection.location)) : nil

        // Over a closing character: move past it rather than doubling it.
        if selection.length == 0, next == typed, brackets.contains(where: { $0.end == typed }),
           selection.location == 0 || string.character(at: selection.location - 1) != 92 { // not after a backslash
            textView.textSelection = NSRange(location: selection.location + (typed as NSString).length, length: 0)
            return true
        }
        // Multi-character openers (`/*`, `"""`) complete on their last character.
        let before = string.substring(to: selection.location)
        guard let bracket = brackets
            .filter({ ($0.start.hasSuffix(typed)) && (before + typed).hasSuffix($0.start) })
            .max(by: { $0.start.count < $1.start.count }) else { return false }

        if selection.length > 0 {
            guard bracket.start == typed else { return false }
            let inner = string.substring(with: selection)
            textView.insertText(bracket.start + inner + bracket.end, replacementRange: selection)
            textView.textSelection = NSRange(location: selection.location + (bracket.start as NSString).length, length: (inner as NSString).length)
            return true
        }
        // As Zed: only before whitespace, the end, or a character the language lists.
        if let next, !next.allSatisfy(\.isWhitespace), !(language.autocloseBefore ?? "").contains(next) { return false }
        // A quote right after a word is an apostrophe or a closing one.
        if bracket.start == bracket.end, let previous = before.last, previous.isLetter || previous.isNumber { return false }
        textView.insertText(typed + bracket.end, replacementRange: selection)
        textView.textSelection = NSRange(location: selection.location + (typed as NSString).length, length: 0)
        return true
    }

    /// Backspace between an empty pair (`(|)`) removes both.
    static func deleteBackward(in textView: STTextView, language: SyntaxLanguage) -> Bool {
        guard let brackets = language.brackets else { return false }
        let string = text(textView)
        let selection = textView.textSelection
        guard selection.length == 0, selection.location > 0, selection.location < string.length else { return false }
        for bracket in brackets where (bracket.start as NSString).length == 1 && (bracket.end as NSString).length == 1 {
            let pair = NSRange(location: selection.location - 1, length: 2)
            if string.substring(with: pair) == bracket.start + bracket.end {
                textView.insertText("", replacementRange: pair)
                return true
            }
        }
        return false
    }
}
