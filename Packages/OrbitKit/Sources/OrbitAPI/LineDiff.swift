import Foundation

public struct DiffLine: Hashable, Sendable, Identifiable {
    public enum Kind: Sendable { case context, added, removed }
    public var id: Int
    public var kind: Kind
    public var text: String
    /// 1-based line numbers in the old/new file.
    public var oldNumber: Int?
    public var newNumber: Int?
}

/// One contiguous change block plus surrounding context. Keep/revert act on
/// the change block (`oldRange` ↔ `newRange`), context lines are display only.
public struct DiffHunk: Hashable, Sendable, Identifiable {
    public var id: Int
    public var oldRange: Range<Int>
    public var newRange: Range<Int>
    public var lines: [DiffLine]

    public var added: Int { newRange.count }
    public var removed: Int { oldRange.count }
}

public enum LineDiff {
    public static func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    public static func hunks(old: String, new: String, context: Int = 3) -> [DiffHunk] {
        hunks(oldLines: lines(old), newLines: lines(new), context: context)
    }

    public static func hunks(oldLines: [String], newLines: [String], context: Int = 3) -> [DiffHunk] {
        let blocks = changeBlocks(oldLines: oldLines, newLines: newLines)
        var result: [DiffHunk] = []
        var lineID = 0
        var previousEnd = (old: 0, new: 0)

        for (index, block) in blocks.enumerated() {
            var lines: [DiffLine] = []
            // Leading context, never reaching back into the previous block.
            let leading = min(context, block.old.lowerBound - previousEnd.old)
            for offset in stride(from: leading, to: 0, by: -1) {
                let o = block.old.lowerBound - offset, n = block.new.lowerBound - offset
                lines.append(DiffLine(id: lineID, kind: .context, text: oldLines[o], oldNumber: o + 1, newNumber: n + 1))
                lineID += 1
            }
            for o in block.old {
                lines.append(DiffLine(id: lineID, kind: .removed, text: oldLines[o], oldNumber: o + 1, newNumber: nil))
                lineID += 1
            }
            for n in block.new {
                lines.append(DiffLine(id: lineID, kind: .added, text: newLines[n], oldNumber: nil, newNumber: n + 1))
                lineID += 1
            }
            // Trailing context, split evenly with the next block's leading context.
            let nextStart = index + 1 < blocks.count ? blocks[index + 1].old.lowerBound : oldLines.count
            let gap = nextStart - block.old.upperBound
            let trailing = index + 1 < blocks.count ? min(context, gap / 2) : min(context, gap)
            for offset in 0..<trailing {
                let o = block.old.upperBound + offset, n = block.new.upperBound + offset
                guard o < oldLines.count, n < newLines.count else { break }
                lines.append(DiffLine(id: lineID, kind: .context, text: oldLines[o], oldNumber: o + 1, newNumber: n + 1))
                lineID += 1
            }
            previousEnd = (block.old.upperBound + trailing, block.new.upperBound + trailing)
            result.append(DiffHunk(id: index, oldRange: block.old, newRange: block.new, lines: lines))
        }
        return result
    }

    /// Contiguous regions where old and new differ.
    public static func changeBlocks(oldLines: [String], newLines: [String]) -> [(old: Range<Int>, new: Range<Int>)] {
        let difference = newLines.difference(from: oldLines)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        var blocks: [(old: Range<Int>, new: Range<Int>)] = []
        var o = 0, n = 0
        var blockStart: (Int, Int)?
        func closeBlock() {
            if let (so, sn) = blockStart { blocks.append((so..<o, sn..<n)) }
            blockStart = nil
        }
        while o < oldLines.count || n < newLines.count {
            if removed.contains(o), o < oldLines.count {
                if blockStart == nil { blockStart = (o, n) }
                o += 1
            } else if inserted.contains(n), n < newLines.count {
                if blockStart == nil { blockStart = (o, n) }
                n += 1
            } else {
                closeBlock()
                o += 1
                n += 1
            }
        }
        closeBlock()
        return blocks
    }

    public static func stats(old: String, new: String) -> (added: Int, removed: Int) {
        changeBlocks(oldLines: lines(old), newLines: lines(new)).reduce(into: (0, 0)) { total, block in
            total.0 += block.new.count
            total.1 += block.old.count
        }
    }

    /// `current` with one hunk's change block restored from `baseline`.
    public static func revert(_ hunk: DiffHunk, current: String, baseline: String) -> String {
        var currentLines = lines(current)
        let baselineLines = lines(baseline)
        currentLines.replaceSubrange(hunk.newRange, with: baselineLines[hunk.oldRange])
        return currentLines.joined(separator: "\n")
    }

    /// `baseline` with one hunk's change block taken from `current` (i.e. accepted).
    public static func keep(_ hunk: DiffHunk, current: String, baseline: String) -> String {
        var baselineLines = lines(baseline)
        let currentLines = lines(current)
        baselineLines.replaceSubrange(hunk.oldRange, with: currentLines[hunk.newRange])
        return baselineLines.joined(separator: "\n")
    }
}

extension LineDiff {
    /// Three-way line merge: both sides' changes to `base` applied together.
    /// `nil` when they touch the same or adjacent lines (like git, adjacent
    /// edits count as a conflict — their order can't be told safely).
    public static func merge(base: String, mine: String, theirs: String) -> String? {
        if mine == theirs || theirs == base { return mine }
        if mine == base { return theirs }
        let baseLines = lines(base), mineLines = lines(mine), theirLines = lines(theirs)
        typealias Edit = (old: Range<Int>, new: ArraySlice<String>)
        let ours: [Edit] = changeBlocks(oldLines: baseLines, newLines: mineLines).map { ($0.old, mineLines[$0.new]) }
        var edits = ours
        for block in changeBlocks(oldLines: baseLines, newLines: theirLines) {
            let edit: Edit = (block.old, theirLines[block.new])
            let clashes = ours.filter { $0.old.lowerBound <= edit.old.upperBound && edit.old.lowerBound <= $0.old.upperBound }
            if clashes.isEmpty {
                edits.append(edit)
            } else if clashes.count > 1 || clashes[0].old != edit.old || clashes[0].new != edit.new {
                return nil
            }
        }
        edits.sort { $0.old.lowerBound < $1.old.lowerBound }
        var result: [String] = []
        var position = 0
        for edit in edits {
            result += baseLines[position..<edit.old.lowerBound]
            result += edit.new
            position = edit.old.upperBound
        }
        result += baseLines[position...]
        return result.joined(separator: "\n")
    }
}

/// Per-line change markers of a file against a baseline, for a gutter.
public struct LineMarkers: Equatable, Sendable {
    /// 0-based lines of the current text.
    public var added = IndexSet()
    public var modified = IndexSet()
    /// Lines with deleted lines right above them; the line count marks a deletion at the end.
    public var deletedAbove = IndexSet()

    public init() {}

    public init(baseline: String, current: String) {
        let newLines = LineDiff.lines(current)
        for block in LineDiff.changeBlocks(oldLines: LineDiff.lines(baseline), newLines: newLines) {
            if block.new.isEmpty {
                deletedAbove.insert(block.new.lowerBound)
            } else if block.old.isEmpty {
                added.insert(integersIn: block.new)
            } else {
                modified.insert(integersIn: block.new)
            }
        }
    }

    public var isEmpty: Bool { added.isEmpty && modified.isEmpty && deletedAbove.isEmpty }
}
