import AppKit
import STTextView

/// The keys code editors share and AppKit's text rules get wrong for code
/// (D218): words stop at punctuation and line breaks, ⌘← goes to the code
/// first, and ⌘C / ⌘X / ⇧⌘K without a selection take whole lines.
enum CaretMotion {
    static func isNewline(_ unit: unichar) -> Bool { unit == 0x0A || unit == 0x0D }
    private static func isBlank(_ unit: unichar) -> Bool { unit == 0x20 || unit == 0x09 }

    /// ⌥←: past spaces, then a word or a run of punctuation (`foo.bar` is
    /// two words and a dot); from a line's start, only over its line break.
    static func wordLeft(_ text: NSString, from offset: Int) -> Int {
        var index = min(max(0, offset), text.length)
        guard index > 0 else { return 0 }
        if isNewline(text.character(at: index - 1)) { return text.rangeOfComposedCharacterSequence(at: index - 1).location }
        while index > 0, isBlank(text.character(at: index - 1)) { index -= 1 }
        guard index > 0, !isNewline(text.character(at: index - 1)) else { return index }
        let word = LineEditing.isWordCharacter(text.character(at: index - 1))
        while index > 0 {
            let unit = text.character(at: index - 1)
            guard !isBlank(unit), !isNewline(unit), LineEditing.isWordCharacter(unit) == word else { break }
            index -= 1
        }
        return index
    }

    /// ⌥→, the mirror of `wordLeft`.
    static func wordRight(_ text: NSString, from offset: Int) -> Int {
        var index = min(max(0, offset), text.length)
        guard index < text.length else { return index }
        if isNewline(text.character(at: index)) { return NSMaxRange(text.rangeOfComposedCharacterSequence(at: index)) }
        while index < text.length, isBlank(text.character(at: index)) { index += 1 }
        guard index < text.length, !isNewline(text.character(at: index)) else { return index }
        let word = LineEditing.isWordCharacter(text.character(at: index))
        while index < text.length {
            let unit = text.character(at: index)
            guard !isBlank(unit), !isNewline(unit), LineEditing.isWordCharacter(unit) == word else { break }
            index += 1
        }
        return index
    }

    /// ⌘←: to the line's code (past its indentation); from there, to the line's start.
    static func home(_ text: NSString, from offset: Int) -> Int {
        let start = text.lineRange(for: NSRange(location: min(max(0, offset), text.length), length: 0)).location
        var code = start
        while code < text.length, isBlank(text.character(at: code)) { code += 1 }
        return offset == code ? start : code
    }

    /// The whole lines the selections touch, line breaks included, merged where they meet.
    static func lines(_ text: NSString, selections: [NSRange]) -> [NSRange] {
        let ranges = selections.map { selection -> NSRange in
            let location = min(max(0, selection.location), text.length)
            var length = min(selection.length, text.length - location)
            // A selection ending at a line's start doesn't take that line.
            if length > 0, isNewline(text.character(at: location + length - 1)) { length -= 1 }
            return text.lineRange(for: NSRange(location: location, length: length))
        }.sorted { $0.location < $1.location }
        var merged: [NSRange] = []
        for range in ranges {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// ⇧⌘K and ⌘X without a selection: the lines go, and each caret lands on
    /// the line that moves up, at its column (the last line's caret goes to the line above).
    static func deleteLines(_ text: NSString, selections: [NSRange]) -> [CaretEditing.Change] {
        lines(text, selections: selections).map { line in
            let inLine = selections.first { NSLocationInRange($0.location, line) || ($0.location == NSMaxRange(line) && $0.location == text.length) }
            let column = (inLine?.location ?? line.location) - line.location
            if NSMaxRange(line) == text.length, line.location > 0, line.length == 0 || !isNewline(text.character(at: NSMaxRange(line) - 1)) {
                let lineBreak = text.rangeOfComposedCharacterSequence(at: line.location - 1)
                let above = text.lineRange(for: NSRange(location: lineBreak.location, length: 0))
                let caret = above.location + min(column, lineBreak.location - above.location)
                let range = NSRange(location: lineBreak.location, length: NSMaxRange(line) - lineBreak.location)
                return CaretEditing.Change(range: range, text: "", selection: NSRange(location: caret - range.location, length: 0))
            }
            let below = text.lineRange(for: NSRange(location: NSMaxRange(line), length: 0))
            var content = below.length
            while content > 0, isNewline(text.character(at: below.location + content - 1)) { content -= 1 }
            return CaretEditing.Change(range: line, text: "", selection: NSRange(location: min(column, content), length: 0))
        }
    }

    /// Pasting a line copied without a selection: it goes above the caret's line, the caret staying put.
    static func pasteLine(_ line: String, in text: NSString, at selection: NSRange) -> CaretEditing.Change {
        let start = text.lineRange(for: NSRange(location: min(selection.location, text.length), length: 0)).location
        let length = (line as NSString).length
        return CaretEditing.Change(range: NSRange(location: start, length: 0), text: line,
                                   selection: NSRange(location: length + selection.location - start, length: 0))
    }
}

@MainActor
extension STTextView {
    /// Each selection as where it began and where its caret is: the start
    /// for one extended backward (TextKit marks those upstream).
    var carets: [(anchor: Int, head: Int)] {
        get {
            let content = textContentManager
            let start = content.documentRange.location
            return textLayoutManager.textSelections.flatMap { selection in
                selection.textRanges.map { range in
                    let lower = content.offset(from: start, to: range.location)
                    let upper = lower + content.offset(from: range.location, to: range.endLocation)
                    return selection.affinity == .upstream ? (anchor: upper, head: lower) : (anchor: lower, head: upper)
                }
            }
        }
        set {
            let content = textContentManager
            let start = content.documentRange.location
            let length = documentText.length
            var seen = Set<[Int]>()
            let selections = newValue.compactMap { caret -> NSTextSelection? in
                let anchor = min(max(0, caret.anchor), length), head = min(max(0, caret.head), length)
                guard seen.insert([anchor, head]).inserted,
                      let from = content.location(start, offsetBy: min(anchor, head)),
                      let to = content.location(from, offsetBy: abs(head - anchor)),
                      let range = NSTextRange(location: from, end: to) else { return nil }
                return NSTextSelection(range: range, affinity: head < anchor ? .upstream : .downstream, granularity: .character)
            }
            guard !selections.isEmpty else { return }
            textLayoutManager.textSelections = selections
            needsLayout = true
            needsDisplay = true
            updateInsertionPointStateAndRestartTimer()
        }
    }
}
