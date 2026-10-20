import AppKit
import OrbitAPI

/// Typing rules for every caret at once (D202): Return's indentation, Tab,
/// Backspace to the indent stop, bracket pairs. Each rule says what it does
/// at one caret against the text before any change; `combine` makes one
/// replacement of them all, so ⌘Z takes back every caret's change together.
enum CaretEditing {
    /// One caret's change: `range` (in the text before any change) becomes
    /// `text`; `selection` is where the caret ends, from `range.location`.
    struct Change: Equatable {
        var range: NSRange
        var text: String
        var selection: NSRange
    }

    /// Typing at a caret as the text view would: its selection is replaced.
    static func plain(_ text: String, at selection: NSRange) -> Change {
        Change(range: selection, text: text, selection: NSRange(location: (text as NSString).length, length: 0))
    }

    /// Backspace as the text view would: the selection, else the character before.
    static func plainDelete(_ string: NSString, at selection: NSRange) -> Change {
        if selection.length > 0 || selection.location == 0 {
            return Change(range: selection, text: "", selection: NSRange(location: 0, length: 0))
        }
        let previous = string.rangeOfComposedCharacterSequence(at: selection.location - 1)
        return Change(range: previous, text: "", selection: NSRange(location: 0, length: 0))
    }

    /// Every caret's change as one replacement; selections keep their order
    /// (the primary last). A change overlapping an earlier one (two carets
    /// in one pair) is dropped with its caret.
    static func combine(_ changes: [Change], in string: NSString) -> LineEditing.Edit? {
        let order = changes.indices.sorted { changes[$0].range.location < changes[$1].range.location }
        var kept: [Int] = []
        var end = 0
        for index in order {
            let range = changes[index].range
            guard NSMaxRange(range) <= string.length else { continue }
            if kept.isEmpty || range.location >= end {
                kept.append(index)
                end = max(end, NSMaxRange(range))
            }
        }
        guard let first = kept.first else { return nil }
        let start = changes[first].range.location
        var replacement = ""
        var cursor = start
        var delta = 0
        var selections: [Int: NSRange] = [:]
        for index in kept {
            let change = changes[index]
            replacement += string.substring(with: NSRange(location: cursor, length: change.range.location - cursor))
            selections[index] = NSRange(location: change.range.location + delta + change.selection.location, length: change.selection.length)
            replacement += change.text
            delta += (change.text as NSString).length - change.range.length
            cursor = NSMaxRange(change.range)
        }
        return LineEditing.Edit(
            range: NSRange(location: start, length: end - start),
            replacement: replacement,
            selections: changes.indices.compactMap { selections[$0] }
        )
    }

    // MARK: Indentation

    /// Columns from the line's start to `offset`, tabs expanded.
    private static func column(of offset: Int, lineStart: Int, in string: NSString, size: Int) -> Int {
        var column = 0
        for index in lineStart..<offset {
            column = string.character(at: index) == 0x09 ? column + size - column % size : column + 1
        }
        return column
    }

    /// Return keeps the line's indentation, one level deeper after an opening
    /// bracket; between a pair (`{|}`) the closing one goes on its own line.
    static func newline(_ string: NSString, at selection: NSRange, indentation: Indentation) -> Change {
        let line = string.lineRange(for: NSRange(location: selection.location, length: 0))
        var leadingEnd = line.location
        while leadingEnd < NSMaxRange(line), [0x20, 0x09].contains(string.character(at: leadingEnd)) { leadingEnd += 1 }
        let indent = string.substring(with: NSRange(location: line.location, length: min(leadingEnd, selection.location) - line.location))
        let before = string.substring(with: NSRange(location: line.location, length: selection.location - line.location))
            .trimmingCharacters(in: .whitespaces)
        let after = NSMaxRange(selection) < string.length ? string.substring(with: NSRange(location: NSMaxRange(selection), length: 1)) : ""
        let pairs: [Character: String] = ["{": "}", "[": "]", "(": ")"]
        var inserted = "\n" + indent
        var caret: Int?
        if let opener = before.last, let closer = pairs[opener] {
            inserted += indentation.unit
            if after == closer {
                caret = (inserted as NSString).length
                inserted += "\n" + indent
            }
        }
        return Change(range: selection, text: inserted, selection: NSRange(location: caret ?? (inserted as NSString).length, length: 0))
    }

    /// Tab within a line: up to the next indent stop.
    static func tab(_ string: NSString, at selection: NSRange, indentation: Indentation) -> Change {
        let lineStart = string.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let unit = indentation.spaces
            ? String(repeating: " ", count: indentation.size - column(of: selection.location, lineStart: lineStart, in: string, size: indentation.size) % indentation.size)
            : "\t"
        return plain(unit, at: selection)
    }

    /// Backspace in a line's leading spaces: back to the previous indent stop; nil elsewhere.
    static func indentBackspace(_ string: NSString, at selection: NSRange, indentation: Indentation) -> Change? {
        guard indentation.spaces, indentation.size > 1, selection.length == 0, selection.location > 0 else { return nil }
        let lineStart = string.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let before = NSRange(location: lineStart, length: selection.location - lineStart)
        guard before.length > 0, string.substring(with: before).allSatisfy({ $0 == " " }) else { return nil }
        let count = (before.length - 1) % indentation.size + 1
        return Change(range: NSRange(location: selection.location - count, length: count), text: "", selection: NSRange(location: 0, length: 0))
    }

    /// Tab over lines / ⇧Tab: every line any selection touches, once, a level
    /// in or out. A caret moves with its line's text; a selection covers its
    /// whole lines after.
    static func shiftLines(_ string: NSString, selections: [NSRange], indentation: Indentation, outward: Bool) -> LineEditing.Edit? {
        let starts = LineStarts.of(string)
        let blocks = LineEditing.blocks(selections, starts: starts)
        guard let first = blocks.first, let last = blocks.last else { return nil }
        let lines = blocks.flatMap { Array($0) }
        let lineSet = Set(lines)
        func lineEnd(_ line: Int) -> Int { line + 1 < starts.count ? starts[line + 1] - 1 : string.length }
        // Each touched line's new text and change in length.
        var deltas: [Int: Int] = [:]
        var texts: [Int: String] = [:]
        for line in lines {
            let text = string.substring(with: NSRange(location: starts[line], length: lineEnd(line) - starts[line]))
            var changed = text
            if outward {
                if text.hasPrefix("\t") {
                    changed.removeFirst()
                } else {
                    changed.removeFirst(min(indentation.size, text.prefix { $0 == " " }.count))
                }
            } else if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                changed = indentation.unit + text
            }
            texts[line] = changed
            deltas[line] = (changed as NSString).length - (text as NSString).length
        }
        guard deltas.values.contains(where: { $0 != 0 }) else { return nil }
        let span = NSRange(location: starts[first.lowerBound], length: lineEnd(last.upperBound) - starts[first.lowerBound])
        var replacement = ""
        for line in first.lowerBound...last.upperBound {
            if line > first.lowerBound { replacement += "\n" }
            replacement += texts[line] ?? string.substring(with: NSRange(location: starts[line], length: lineEnd(line) - starts[line]))
        }
        /// Where an old offset lands: shifted by the lines above, and by its own line's change past the indentation.
        func map(_ offset: Int) -> Int {
            let line = max(0, LineStarts.firstIndex(in: starts, after: offset) - 1)
            var shifted = offset
            for (other, delta) in deltas where other < line { shifted += delta }
            if lineSet.contains(line), let delta = deltas[line] {
                shifted = max(starts[line] + (shifted - offset), shifted + delta)
            }
            return shifted
        }
        func newLineStart(_ line: Int) -> Int {
            starts[line] + deltas.filter { $0.key < line }.values.reduce(0, +)
        }
        let moved = selections.map { selection -> NSRange in
            guard selection.length > 0 else { return NSRange(location: map(selection.location), length: 0) }
            let firstLine = max(0, LineStarts.firstIndex(in: starts, after: selection.location) - 1)
            // Its last character's line: one ending at a line's start doesn't take that line.
            let lastLine = max(firstLine, LineStarts.firstIndex(in: starts, after: NSMaxRange(selection) - 1) - 1)
            let start = newLineStart(firstLine)
            let end = newLineStart(lastLine) + ((texts[lastLine] ?? "") as NSString).length
            return NSRange(location: start, length: max(0, end - start))
        }
        return LineEditing.Edit(range: span, replacement: replacement, selections: moved)
    }

    // MARK: Brackets

    /// A typed character at one caret: closes an opening bracket or quote,
    /// wraps a selection in a pair, or steps over the closing character
    /// already there. Nil to type it as usual.
    static func typed(_ typed: String, in string: NSString, at selection: NSRange,
                      brackets: [SyntaxLanguage.Bracket], autocloseBefore: String?) -> Change? {
        guard !brackets.isEmpty else { return nil }
        let selection = NSIntersectionRange(selection, NSRange(location: 0, length: string.length))
        let next = selection.length == 0 && selection.location < string.length
            ? string.substring(with: string.rangeOfComposedCharacterSequence(at: selection.location)) : nil
        let typedLength = (typed as NSString).length

        // Over a closing character: move past it rather than doubling it.
        if selection.length == 0, next == typed, brackets.contains(where: { $0.end == typed }),
           selection.location == 0 || string.character(at: selection.location - 1) != 92 { // not after a backslash
            return Change(range: selection, text: "", selection: NSRange(location: typedLength, length: 0))
        }
        // Multi-character openers (`/*`, `"""`) complete on their last character.
        let before = string.substring(to: selection.location)
        guard let bracket = brackets
            .filter({ $0.start.hasSuffix(typed) && (before + typed).hasSuffix($0.start) })
            .max(by: { $0.start.count < $1.start.count }) else { return nil }

        if selection.length > 0 {
            guard bracket.start == typed else { return nil }
            let inner = string.substring(with: selection)
            return Change(range: selection, text: bracket.start + inner + bracket.end,
                          selection: NSRange(location: (bracket.start as NSString).length, length: (inner as NSString).length))
        }
        // As Zed: only before whitespace, the end, or a character the language lists.
        if let next, !next.allSatisfy(\.isWhitespace), !(autocloseBefore ?? "").contains(next) { return nil }
        // A quote right after a word is an apostrophe or a closing one.
        if bracket.start == bracket.end, let previous = before.last, previous.isLetter || previous.isNumber { return nil }
        return Change(range: selection, text: typed + bracket.end, selection: NSRange(location: typedLength, length: 0))
    }

    /// Backspace between an empty pair (`(|)`) removes both; nil elsewhere.
    static func deletePair(_ string: NSString, at selection: NSRange, brackets: [SyntaxLanguage.Bracket]) -> Change? {
        guard selection.length == 0, selection.location > 0, selection.location < string.length else { return nil }
        for bracket in brackets where (bracket.start as NSString).length == 1 && (bracket.end as NSString).length == 1 {
            let pair = NSRange(location: selection.location - 1, length: 2)
            if string.substring(with: pair) == bracket.start + bracket.end {
                return Change(range: pair, text: "", selection: NSRange(location: 0, length: 0))
            }
        }
        return nil
    }
}
