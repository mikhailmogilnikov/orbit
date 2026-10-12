import Foundation
import OrbitAPI
import SwiftTreeSitter
import Synchronization
import TreeSitterResource

/// An immutable copy of the document for the parser thread. Bridging
/// `NSTextStorage.string` already copies the mutable backing store, so this is
/// one memcpy per edit.
struct TextSnapshot: @unchecked Sendable {
    let string: NSString
    var length: Int { string.length }
}

/// `range` of the old text was replaced by `newLength` UTF-16 units.
struct TextEdit: Sendable, Equatable {
    var range: NSRange
    var newLength: Int

    var delta: Int { newLength - range.length }

    /// Where an offset of the old text lands. Offsets inside the replaced range
    /// collapse to its start; an insertion inside a span widens it, so typing
    /// inside a token keeps its color until the reparse.
    func map(_ offset: Int) -> Int {
        if offset <= range.location { return offset }
        if offset >= NSMaxRange(range) { return offset + delta }
        return range.location
    }

    /// The smallest edit turning `old` into `new`, given that `self` covers it.
    func trimmed(old: NSString, new: NSString) -> TextEdit {
        let oldEnd = NSMaxRange(range), newEnd = range.location + newLength
        guard oldEnd <= old.length, newEnd <= new.length else { return self }
        var start = range.location
        while start < oldEnd, start < newEnd, old.character(at: start) == new.character(at: start) { start += 1 }
        var oldTail = oldEnd, newTail = newEnd
        while oldTail > start, newTail > start, old.character(at: oldTail - 1) == new.character(at: newTail - 1) {
            oldTail -= 1
            newTail -= 1
        }
        return TextEdit(range: NSRange(location: start, length: oldTail - start), newLength: newTail - start)
    }

    func map(_ set: IndexSet) -> IndexSet {
        var mapped = IndexSet()
        for run in set.rangeView {
            let lower = map(run.lowerBound), upper = map(run.upperBound)
            if upper > lower { mapped.insert(integersIn: lower..<upper) }
        }
        return mapped
    }
}

/// A run of text colored by one highlight capture (`capture` is the query's
/// capture index + 1).
struct HighlightSpan: Sendable, Equatable {
    var start: Int
    var end: Int
    var capture: UInt16
}

/// Sorted, non-overlapping spans for the whole document — the highlight cache.
/// Edits shift it right away (no clearing, so nothing flickers); parser patches
/// replace whole ranges.
struct HighlightSpans {
    private(set) var spans: [HighlightSpan] = []

    /// The first span that ends after `offset`.
    func firstIndex(endingAfter offset: Int) -> Int {
        var low = 0, high = spans.count
        while low < high {
            let mid = (low + high) / 2
            if spans[mid].end <= offset { low = mid + 1 } else { high = mid }
        }
        return low
    }

    mutating func apply(_ edit: TextEdit) {
        var write = firstIndex(endingAfter: edit.range.location)
        for index in write..<spans.count {
            var span = spans[index]
            span.start = edit.map(span.start)
            span.end = edit.map(span.end)
            if span.end > span.start {
                spans[write] = span
                write += 1
            }
        }
        spans.removeSubrange(write...)
    }

    /// Replaces everything inside `range` with `new` (sorted, within `range`).
    mutating func replace(in range: NSRange, with new: [HighlightSpan]) {
        let lower = firstIndex(endingAfter: range.location)
        var upper = lower
        while upper < spans.count, spans[upper].start < NSMaxRange(range) { upper += 1 }
        var replacement: [HighlightSpan] = []
        replacement.reserveCapacity(new.count + 2)
        if lower < upper, spans[lower].start < range.location {
            var head = spans[lower]
            head.end = range.location
            replacement.append(head)
        }
        replacement += new
        if lower < upper, spans[upper - 1].end > NSMaxRange(range) {
            var tail = spans[upper - 1]
            tail.start = NSMaxRange(range)
            replacement.append(tail)
        }
        spans.replaceSubrange(lower..<upper, with: replacement)
    }

    func forEach(in range: NSRange, _ body: (HighlightSpan) -> Void) {
        var index = firstIndex(endingAfter: range.location)
        while index < spans.count, spans[index].start < NSMaxRange(range) {
            body(spans[index])
            index += 1
        }
    }
}

/// Fresh highlights for some ranges of the document as of `version`.
struct HighlightPatch: Sendable {
    var version: Int
    var ranges: [(range: NSRange, spans: [HighlightSpan])]
}

/// The main thread's highlights, kept in step with the text: edits shift them
/// at once, and worker patches made before the latest edits are shifted
/// through those edits before they land.
struct HighlightCache {
    private(set) var spans = HighlightSpans()
    private(set) var version = 0
    private var unconfirmed: [(version: Int, edit: TextEdit)] = []

    /// Returns the edit's version, to pass to the worker.
    mutating func apply(_ edit: TextEdit) -> Int {
        version += 1
        unconfirmed.append((version, edit))
        spans.apply(edit)
        return version
    }

    /// Returns the text the patches touched.
    mutating func apply(_ patches: [HighlightPatch]) -> IndexSet {
        var touched = IndexSet()
        for patch in patches {
            unconfirmed.removeAll { $0.version <= patch.version }
            for (range, new) in patch.ranges {
                var range = range, new = new
                for (_, edit) in unconfirmed {
                    let lower = edit.map(range.location)
                    range = NSRange(location: lower, length: edit.map(NSMaxRange(range)) - lower)
                    new = new.compactMap { span in
                        let mapped = HighlightSpan(start: edit.map(span.start), end: edit.map(span.end), capture: span.capture)
                        return mapped.end > mapped.start ? mapped : nil
                    }
                }
                guard range.length > 0 else { continue }
                spans.replace(in: range, with: new)
                touched.insert(integersIn: range.location..<NSMaxRange(range))
            }
        }
        return touched
    }
}

/// Tree-sitter parsing and highlight queries on a background queue, the way
/// Zed does it: the main thread hands over edits with a text snapshot and may
/// wait a couple of milliseconds for the result; anything slower arrives as a
/// patch later while the shifted old highlights stay on screen.
///
/// All mutable state is confined to `queue`; the main thread talks to it only
/// through the locked inbox and outbox.
final class HighlightWorker: @unchecked Sendable {
    let captureNames: [String]

    private struct Inbox {
        var reset: (TextSnapshot, Int)?
        var edits: [(TextEdit, TextSnapshot, Int)] = []
        var theme: ColorTheme?
        var focus = NSRange(location: 0, length: 0)
        var waiters: [DispatchSemaphore] = []
        var isScheduled = false
        var isCancelled = false
    }

    private let inbox = Mutex(Inbox())
    private let outbox = Mutex<[HighlightPatch]>([])
    private let notify: @Sendable () -> Void
    private let queue = DispatchQueue(label: "dev.orbit.highlight", qos: .userInitiated)

    // Confined to `queue`.
    private let parser = Parser()
    private let query: Query
    private let captureIDs: [String: UInt16]
    private var colored: [Bool]
    private var tree: MutableTree?
    private var text = TextSnapshot(string: "")
    private var lineStarts = [0]
    private var version = 0
    private var invalid = IndexSet()

    /// Background patches cover at most this much text, so a new edit never
    /// waits long behind them.
    private static let chunkLength = 8 * 1024

    /// `notify` is called on any thread whenever patches are ready.
    init?(language: TreeSitterLanguage, theme: ColorTheme, notify: @escaping @Sendable () -> Void) {
        guard let query = HighlightQueries.query(for: language),
              (try? parser.setLanguage(SwiftTreeSitter.Language(language: language.parser))) != nil
        else { return nil }
        self.query = query
        self.notify = notify
        let names = (0..<query.captureCount).map { query.captureName(for: $0) ?? "" }
        captureNames = names
        captureIDs = Dictionary(names.enumerated().map { ($1, UInt16($0 + 1)) }, uniquingKeysWith: { first, _ in first })
        colored = Self.colored(names, theme: theme)
    }

    // MARK: Main thread API

    func reset(_ snapshot: TextSnapshot, version: Int, waiter: DispatchSemaphore? = nil) {
        post {
            $0.reset = (snapshot, version)
            $0.edits.removeAll()
            if let waiter { $0.waiters.append(waiter) }
        }
    }

    func edit(_ edit: TextEdit, snapshot: TextSnapshot, version: Int, waiter: DispatchSemaphore? = nil) {
        post {
            $0.edits.append((edit, snapshot, version))
            if let waiter { $0.waiters.append(waiter) }
        }
    }

    func setTheme(_ theme: ColorTheme) {
        post { $0.theme = theme }
    }

    /// The text on screen; it's highlighted first.
    func setFocus(_ range: NSRange) {
        inbox.withLock { $0.focus = range }
    }

    func cancel() {
        inbox.withLock { $0.isCancelled = true }
    }

    func takePatches() -> [HighlightPatch] {
        outbox.withLock { patches in
            defer { patches.removeAll() }
            return patches
        }
    }

    /// Blocks until all queued work is done (tests).
    func waitUntilIdle() {
        repeat { queue.sync {} } while inbox.withLock { $0.isScheduled }
    }

    private func post(_ change: (inout Inbox) -> Void) {
        let schedule = inbox.withLock { inbox in
            change(&inbox)
            defer { inbox.isScheduled = true }
            return !inbox.isScheduled
        }
        if schedule { queue.async { self.step() } }
    }

    // MARK: Worker queue

    private func step() {
        let taken = inbox.withLock { inbox in
            defer {
                inbox.reset = nil
                inbox.edits.removeAll()
                inbox.theme = nil
                inbox.waiters.removeAll()
                inbox.isScheduled = false
            }
            return inbox
        }
        if taken.isCancelled { return }

        var needsParse = false
        if let (snapshot, version) = taken.reset {
            text = snapshot
            lineStarts = LineStarts.of(snapshot.string)
            tree = nil
            invalid = IndexSet(integersIn: 0..<snapshot.length)
            self.version = version
            needsParse = true
        }
        for (edit, snapshot, version) in taken.edits {
            apply(edit, snapshot: snapshot)
            self.version = version
            needsParse = true
        }
        if let theme = taken.theme {
            let colored = Self.colored(captureNames, theme: theme)
            if colored != self.colored {
                self.colored = colored
                invalid = IndexSet(integersIn: 0..<text.length)
            }
        }
        if needsParse { parse() }

        // What's on screen goes out first and in one piece; the main thread may be waiting for it.
        let focus = Self.clamp(taken.focus, to: text.length)
        let onScreen = invalid.intersection(IndexSet(integersIn: Range(focus) ?? 0..<0))
        if !onScreen.isEmpty {
            deliver(onScreen)
        }
        for waiter in taken.waiters { waiter.signal() }

        if let next = nextChunk(near: focus.location) {
            deliver(IndexSet(integersIn: next))
        }
        if !invalid.isEmpty {
            let schedule = inbox.withLock { inbox in
                defer { inbox.isScheduled = true }
                return !inbox.isScheduled
            }
            if schedule { queue.async { self.step() } }
        }
    }

    private func apply(_ edit: TextEdit, snapshot: TextSnapshot) {
        let start = edit.range.location
        let oldEnd = NSMaxRange(edit.range)
        let newEnd = start + edit.newLength
        let startPoint = point(at: start)
        let oldEndPoint = point(at: oldEnd)
        lineStarts = LineStarts.updated(lineStarts, after: edit, in: snapshot.string)
        text = snapshot
        tree?.edit(InputEdit(
            startByte: start * 2, oldEndByte: oldEnd * 2, newEndByte: newEnd * 2,
            startPoint: startPoint, oldEndPoint: oldEndPoint, newEndPoint: point(at: newEnd)
        ))
        // Whole lines around the edit: typing can turn a word into a keyword
        // without changing the tree's shape.
        invalid = edit.map(invalid)
        let lines = snapshot.string.lineRange(for: NSRange(location: start, length: edit.newLength))
        invalid.insert(integersIn: Range(lines) ?? start..<start)
    }

    private func parse() {
        let string = text.string
        let length = string.length
        let newTree = parser.parse(tree: tree, readBlock: { byte, _ in
            let start = byte / 2
            guard start < length else { return nil }
            let count = min(16 * 1024, length - start)
            var data = Data(count: count * 2)
            data.withUnsafeMutableBytes { buffer in
                string.getCharacters(buffer.baseAddress!.assumingMemoryBound(to: unichar.self), range: NSRange(location: start, length: count))
            }
            return data
        })
        if let oldTree = tree, let newTree {
            for changed in newTree.changedRanges(from: oldTree) {
                let lower = Int(changed.bytes.lowerBound) / 2, upper = min(Int(changed.bytes.upperBound) / 2, length)
                if upper > lower { invalid.insert(integersIn: lower..<upper) }
            }
        }
        tree = newTree
    }

    /// The invalid run closest after `location` (or the first one), at most a chunk long.
    private func nextChunk(near location: Int) -> Range<Int>? {
        let runs = invalid.rangeView
        guard let run = runs.first(where: { $0.upperBound > location }) ?? runs.first else { return nil }
        let lower = max(run.lowerBound, run.contains(location) ? location : run.lowerBound)
        return lower..<min(run.upperBound, lower + Self.chunkLength)
    }

    private func deliver(_ set: IndexSet) {
        invalid.subtract(set)
        let ranges = set.rangeView.map { run in
            let range = NSRange(run)
            return (range, highlights(in: range))
        }
        outbox.withLock { $0.append(HighlightPatch(version: version, ranges: ranges)) }
        notify()
    }

    private func highlights(in range: NSRange) -> [HighlightSpan] {
        guard range.length > 0, let tree, let root = tree.rootNode else { return [] }
        let string = text.string
        let cursor = query.execute(node: root, in: tree)
        cursor.setRange(range)
        let context = Predicate.Context(textProvider: { range, _ in
            NSMaxRange(range) <= string.length ? string.substring(with: range) : nil
        })

        // Later captures are more specific and win, like painting over.
        var paint = [UInt16](repeating: 0, count: range.length)
        for highlight in cursor.resolve(with: context).highlights() {
            guard let id = captureIDs[highlight.name], colored[Int(id) - 1] else { continue }
            let clipped = NSIntersectionRange(highlight.range, range)
            guard clipped.length > 0 else { continue }
            let lower = clipped.location - range.location
            paint.withUnsafeMutableBufferPointer { buffer in
                for index in lower..<(lower + clipped.length) { buffer[index] = id }
            }
        }

        var spans: [HighlightSpan] = []
        var index = 0
        while index < paint.count {
            let id = paint[index]
            var end = index + 1
            while end < paint.count, paint[end] == id { end += 1 }
            if id != 0 { spans.append(HighlightSpan(start: range.location + index, end: range.location + end, capture: id)) }
            index = end
        }
        return spans
    }

    private func point(at offset: Int) -> Point {
        let row = max(0, LineStarts.firstIndex(in: lineStarts, after: offset) - 1)
        return Point(row: row, column: (offset - lineStarts[row]) * 2)
    }

    // MARK: Helpers

    private static func colored(_ names: [String], theme: ColorTheme) -> [Bool] {
        names.map { theme.style(forCapture: $0)?.color != nil }
    }

    private static func clamp(_ range: NSRange, to length: Int) -> NSRange {
        let lower = min(max(0, range.location), length)
        return NSRange(location: lower, length: min(max(0, range.length), length - lower))
    }
}
/// Offsets where lines start, found by scanning UTF-16 buffers (several
/// times faster than repeated `range(of: "\n")`).
enum LineStarts {
    static func of(_ string: NSString) -> [Int] {
        var starts = [0]
        forEachNewline(in: string, range: NSRange(location: 0, length: string.length)) { starts.append($0 + 1) }
        return starts
    }

    /// Line starts after `edit`: only the inserted text is scanned.
    static func updated(_ starts: [Int], after edit: TextEdit, in string: NSString) -> [Int] {
        var result = Array(starts[..<firstIndex(in: starts, after: edit.range.location)])
        forEachNewline(in: string, range: NSRange(location: edit.range.location, length: edit.newLength)) { result.append($0 + 1) }
        let delta = edit.delta
        result += starts[firstIndex(in: starts, after: NSMaxRange(edit.range))...].lazy.map { $0 + delta }
        return result
    }

    /// The index of the first start after `offset`.
    static func firstIndex(in starts: [Int], after offset: Int) -> Int {
        var low = 0, high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= offset { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private static func forEachNewline(in string: NSString, range: NSRange, _ body: (Int) -> Void) {
        let chunk = 16 * 1024
        var buffer = [unichar](repeating: 0, count: min(chunk, range.length))
        var location = range.location
        while location < NSMaxRange(range) {
            let count = min(chunk, NSMaxRange(range) - location)
            buffer.withUnsafeMutableBufferPointer { pointer in
                string.getCharacters(pointer.baseAddress!, range: NSRange(location: location, length: count))
                for index in 0..<count where pointer[index] == 0x0A { body(location + index) }
            }
            location += count
        }
    }
}
