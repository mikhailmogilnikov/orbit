import AppKit
import OrbitAPI
import STTextView

/// Line moves and copies, multiple carets, Go to Line. The text work is pure
/// (`Edit`) so it's testable; `apply` puts it in the view as one undo step.
enum LineEditing {
    /// One replacement and the selections after it.
    struct Edit: Equatable {
        var range: NSRange
        var replacement: String
        var selections: [NSRange]
    }

    /// Lines touched by the selections (first...last, 0-based), merged when they touch.
    static func blocks(_ selections: [NSRange], starts: [Int]) -> [ClosedRange<Int>] {
        func line(at offset: Int) -> Int { max(0, LineStarts.firstIndex(in: starts, after: offset) - 1) }
        let lines = selections.sorted { $0.location < $1.location }.map { selection -> ClosedRange<Int> in
            let first = line(at: selection.location)
            // A selection ending at a line's start doesn't take that line.
            let last = selection.length > 0 ? max(first, line(at: NSMaxRange(selection) - 1)) : first
            return first...last
        }
        var merged: [ClosedRange<Int>] = []
        for block in lines {
            if let previous = merged.last, block.lowerBound <= previous.upperBound + 1 {
                merged[merged.count - 1] = previous.lowerBound...max(previous.upperBound, block.upperBound)
            } else {
                merged.append(block)
            }
        }
        return merged
    }

    private static func lineText(_ index: Int, _ text: NSString, _ starts: [Int]) -> String {
        let end = index + 1 < starts.count ? starts[index + 1] - 1 : text.length
        return text.substring(with: NSRange(location: starts[index], length: end - starts[index]))
    }

    /// Lines first...last as one replaceable range, its text joined by newlines.
    private static func region(_ lines: ClosedRange<Int>, _ text: NSString, _ starts: [Int]) -> (NSRange, [String], trailing: Bool) {
        let end = lines.upperBound + 1 < starts.count ? starts[lines.upperBound + 1] : text.length
        let trailing = lines.upperBound + 1 < starts.count
        return (NSRange(location: starts[lines.lowerBound], length: end - starts[lines.lowerBound]),
                lines.map { lineText($0, text, starts) }, trailing)
    }

    /// Moves the selections starting on the block's lines.
    private static func shift(_ selections: [NSRange], in block: ClosedRange<Int>, starts: [Int], by delta: Int) -> [NSRange] {
        selections.map { selection in
            let line = max(0, LineStarts.firstIndex(in: starts, after: selection.location) - 1)
            guard block.contains(line) else { return selection }
            return NSRange(location: selection.location + delta, length: selection.length)
        }
    }

    /// ⌥↑ / ⌥↓: the selected lines swap with the line above or below; nil at the edge.
    static func moveLines(_ text: NSString, selections: [NSRange], up: Bool) -> Edit? {
        let starts = LineStarts.of(text)
        let blocks = blocks(selections, starts: starts)
        guard let firstBlock = blocks.first, let lastBlock = blocks.last else { return nil }
        if up ? firstBlock.lowerBound == 0 : lastBlock.upperBound + 1 >= starts.count { return nil }
        let span = up ? (firstBlock.lowerBound - 1)...lastBlock.upperBound : firstBlock.lowerBound...(lastBlock.upperBound + 1)
        let (range, original, trailing) = region(span, text, starts)
        var lines = original
        var moved = selections
        for block in up ? blocks : blocks.reversed() {
            let other = up ? block.lowerBound - 1 : block.upperBound + 1
            let otherLength = (lineText(other, text, starts) as NSString).length + 1
            let line = lines.remove(at: other - span.lowerBound)
            lines.insert(line, at: (up ? block.upperBound : block.lowerBound) - span.lowerBound)
            moved = shift(moved, in: block, starts: starts, by: up ? -otherLength : otherLength)
        }
        var replacement = lines.joined(separator: "\n")
        if trailing { replacement += "\n" }
        return Edit(range: range, replacement: replacement, selections: moved)
    }

    /// ⇧⌥↓ / ⇧⌥↑: the selected lines copied below (the selection goes with the copy) or above.
    static func copyLines(_ text: NSString, selections: [NSRange], down: Bool) -> Edit? {
        let starts = LineStarts.of(text)
        let blocks = blocks(selections, starts: starts)
        guard let firstBlock = blocks.first, let lastBlock = blocks.last else { return nil }
        let span = firstBlock.lowerBound...lastBlock.upperBound
        let (range, original, trailing) = region(span, text, starts)
        var lines: [String] = []
        var moved = selections
        var inserted = 0
        var cursor = span.lowerBound
        for block in blocks {
            while cursor < block.lowerBound {
                lines.append(original[cursor - span.lowerBound])
                cursor += 1
            }
            let copy = block.map { original[$0 - span.lowerBound] }
            lines += copy + copy
            cursor = block.upperBound + 1
            let length = copy.reduce(0) { $0 + ($1 as NSString).length + 1 }
            moved = shift(moved, in: block, starts: starts, by: inserted + (down ? length : 0))
            inserted += length
        }
        var replacement = lines.joined(separator: "\n")
        if trailing { replacement += "\n" }
        return Edit(range: range, replacement: replacement, selections: moved)
    }

    // MARK: Occurrences

    static func isWordCharacter(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return scalar == "_" || CharacterSet.alphanumerics.contains(scalar)
    }

    /// The word around (or right before) an offset.
    static func word(at offset: Int, in text: NSString) -> NSRange? {
        var start = min(offset, text.length), end = start
        while start > 0, isWordCharacter(text.character(at: start - 1)) { start -= 1 }
        while end < text.length, isWordCharacter(text.character(at: end)) { end += 1 }
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    /// ⌘D: a caret selects its word; a selection adds the next match of its text (wrapping).
    static func addNextOccurrence(_ text: NSString, selections: [NSRange]) -> [NSRange]? {
        guard let last = selections.last else { return nil }
        if last.length == 0 {
            guard let word = word(at: last.location, in: text) else { return nil }
            return selections.dropLast() + [word]
        }
        let needle = text.substring(with: last)
        let after = NSRange(location: NSMaxRange(last), length: text.length - NSMaxRange(last))
        var found = text.range(of: needle, options: .literal, range: after)
        if found.location == NSNotFound {
            found = text.range(of: needle, options: .literal, range: NSRange(location: 0, length: last.location))
        }
        guard found.location != NSNotFound, !selections.contains(found) else { return nil }
        return selections + [found]
    }

    /// ⇧⌘L: every match of the selection, or of the caret's word.
    static func allOccurrences(_ text: NSString, selections: [NSRange]) -> [NSRange]? {
        guard let last = selections.last else { return nil }
        guard let target = last.length > 0 ? last : word(at: last.location, in: text) else { return nil }
        let needle = text.substring(with: target)
        var found: [NSRange] = []
        var searched = NSRange(location: 0, length: text.length)
        while true {
            let match = text.range(of: needle, options: .literal, range: searched)
            guard match.location != NSNotFound else { break }
            found.append(match)
            let next = NSMaxRange(match)
            searched = NSRange(location: next, length: text.length - next)
        }
        // The one the caret was on stays the primary (last) selection.
        if let primary = found.firstIndex(of: target) { found.append(found.remove(at: primary)) }
        return found.count > 1 || last.length == 0 ? found : nil
    }

    /// Overlapping selections become one and the same caret twice one caret, as
    /// in VS Code; the primary stays last. Expand Selection grew thousands of
    /// carets to the same range, and STTextView drew every copy: the editor froze (D243).
    nonisolated static func merged(_ selections: [NSRange]) -> [NSRange] {
        guard selections.count > 1, let primary = selections.last else { return selections }
        var merged: [NSRange] = []
        for range in selections.sorted(by: { ($0.location, $0.length) < ($1.location, $1.length) }) {
            if let last = merged.last, range == last || range.location < NSMaxRange(last) {
                merged[merged.count - 1].length = max(NSMaxRange(last), NSMaxRange(range)) - last.location
            } else {
                merged.append(range)
            }
        }
        if let index = merged.firstIndex(where: { $0.location <= primary.location && NSMaxRange(primary) <= NSMaxRange($0) }) {
            merged.append(merged.remove(at: index))
        }
        return merged
    }

    /// ⌃⇧↑ / ⌃⇧↓: a caret at the same column one line above the first caret or below the last.
    static func addCaret(_ text: NSString, selections: [NSRange], up: Bool) -> [NSRange]? {
        let sorted = selections.sorted { $0.location < $1.location }
        guard let edge = up ? sorted.first : sorted.last else { return nil }
        let starts = LineStarts.of(text)
        let line = max(0, LineStarts.firstIndex(in: starts, after: up ? edge.location : NSMaxRange(edge)) - 1)
        let column = (up ? edge.location : NSMaxRange(edge)) - starts[line]
        let target = up ? line - 1 : line + 1
        guard target >= 0, target < starts.count else { return nil }
        let length = (lineText(target, text, starts) as NSString).length
        let caret = NSRange(location: starts[target] + min(column, length), length: 0)
        guard !selections.contains(caret) else { return nil }
        return selections + [caret]
    }

    /// "42" or "42:7" (1-based, as typed) as a 0-based line and column; nil when it isn't one.
    static func lineAndColumn(_ input: String) -> (line: Int, column: Int?)? {
        let parts = input.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard let line = parts.first.flatMap({ Int($0) }), line > 0, parts.count <= 2 else { return nil }
        let column = parts.count == 2 ? Int(parts[1]).map { max(0, $0 - 1) } : nil
        return (line - 1, column)
    }
}

// MARK: The view

@MainActor
extension STTextView {
    var documentText: NSString {
        ((textContentManager as? NSTextContentStorage)?.textStorage?.string ?? text ?? "") as NSString
    }

    /// Every selection and caret as offsets; the primary (last placed) one last.
    var selectionRanges: [NSRange] {
        get {
            let content = textContentManager
            let start = content.documentRange.location
            return textLayoutManager.textSelections.flatMap(\.textRanges).map { range in
                let location = content.offset(from: start, to: range.location)
                return NSRange(location: location, length: content.offset(from: range.location, to: range.endLocation))
            }
        }
        set {
            let content = textContentManager
            let start = content.documentRange.location
            let length = documentText.length
            let selections = LineEditing.merged(newValue).compactMap { range -> NSTextSelection? in
                let location = min(max(0, range.location), length)
                guard let from = content.location(start, offsetBy: location),
                      let to = content.location(from, offsetBy: min(range.length, length - location)),
                      let textRange = NSTextRange(location: from, end: to) else { return nil }
                return NSTextSelection(range: textRange, affinity: .downstream, granularity: .character)
            }
            guard !selections.isEmpty else { return }
            textLayoutManager.textSelections = selections
            needsLayout = true
            needsDisplay = true
            updateInsertionPointStateAndRestartTimer()
        }
    }

    var hasMultipleSelections: Bool { textLayoutManager.textSelections.flatMap(\.textRanges).count > 1 }

    func apply(_ edit: LineEditing.Edit) {
        breakUndoCoalescing()
        insertText(edit.replacement, replacementRange: edit.range)
        breakUndoCoalescing()
        selectionRanges = edit.selections
        scrollToPrimarySelection()
    }

    func scrollToPrimarySelection() {
        if let primary = selectionRanges.last { scrollRangeToVisible(NSRange(location: NSMaxRange(primary), length: 0)) }
    }
}
