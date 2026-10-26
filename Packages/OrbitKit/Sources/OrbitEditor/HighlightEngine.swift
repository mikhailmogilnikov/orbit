import Foundation
import OrbitAPI
import SwiftTreeSitter
import Synchronization

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

/// A run of text colored by one highlight capture (its id in `CaptureTable`).
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

/// Capture names of every language in one numbering, so spans of embedded
/// languages share the highlight cache with the file's own. 0 is "none".
enum CaptureTable {
    private static let table = Mutex<(names: [String], ids: [String: UInt16])>(([""], ["": 0]))

    static func id(_ name: String) -> UInt16 {
        table.withLock { table in
            if let id = table.ids[name] { return id }
            let id = UInt16(clamping: table.names.count)
            table.names.append(name)
            table.ids[name] = id
            return id
        }
    }

    static var count: Int { table.withLock { $0.names.count } }

    /// Names from an id on, for whoever caches something per id.
    static func names(from id: Int) -> [String] {
        table.withLock { Array($0.names[min(id, $0.names.count)...]) }
    }

    /// Captured as `@none`: explicitly no color (Markdown's code block contents).
    static let none = id("none")
}

/// A grammar's compiled queries, with its captures' ids in `CaptureTable`.
final class LanguageQueries: @unchecked Sendable {
    let grammar: Grammar
    let language: SwiftTreeSitter.Language
    let highlights: Query
    /// Where it embeds other languages (D69); nil when it doesn't.
    let injections: Query?
    let ids: [String: UInt16]

    init(grammar: Grammar, language: SwiftTreeSitter.Language, highlights: Query, injections: Query?) {
        self.grammar = grammar
        self.language = language
        self.highlights = highlights
        self.injections = injections
        ids = Dictionary((0..<highlights.captureCount).compactMap { index in
            highlights.captureName(for: index).map { ($0, CaptureTable.id($0)) }
        }, uniquingKeysWith: { first, _ in first })
    }
}

/// Tree-sitter parsing and highlight queries on a background queue, the way
/// Zed does it: the main thread hands over edits with a text snapshot and may
/// wait a couple of milliseconds for the result; anything slower arrives as a
/// patch later while the shifted old highlights stay on screen.
///
/// Languages embedded in the file (CSS and JS in HTML, code blocks in
/// Markdown) are layers: each its own tree over its piece of the text,
/// parsed again only where an edit lands, painted over the file's colors (D69).
///
/// All mutable state is confined to `queue`; the main thread talks to it only
/// through the locked inbox and outbox.
final class HighlightWorker: @unchecked Sendable {
    private struct Inbox {
        var reset: (TextSnapshot, Int)?
        var edits: [(TextEdit, TextSnapshot, Int)] = []
        var theme: ColorTheme?
        var reloadsLayers = false
        var focus = NSRange(location: 0, length: 0)
        var waiters: [DispatchSemaphore] = []
        var isScheduled = false
        var isCancelled = false
    }

    /// An embedded language's piece of the document, parsed on its own.
    private struct Layer {
        let queries: LanguageQueries
        /// Where its text is in the document.
        var range: NSRange
        /// The whole injection match (a fence with its language line): an edit
        /// there may end the layer without touching its text.
        var anchor: NSRange
        /// 1 for what the file embeds, 2 for what that embeds…
        let depth: Int
        var tree: MutableTree?
        /// Its text as of the last parse (the tree's coordinates are offsets in it).
        var text: NSString
        var lineStarts: [Int]
        /// An edit landed inside: the tree took it, the parse is still due.
        var isEdited = false

        var key: String { "\(queries.grammar.key)@\(range.location)" }
        /// What an edit must touch to look for it again.
        var extent: Range<Int> {
            let whole = NSUnionRange(range, anchor)
            return whole.location..<max(whole.location + 1, NSMaxRange(whole))
        }
    }

    /// Where a tree embeds a language, in document offsets.
    private struct Injection {
        var name: String
        var range: NSRange
        var anchor: NSRange
    }

    private let inbox = Mutex(Inbox())
    private let outbox = Mutex<[HighlightPatch]>([])
    /// Languages files embed that aren't installed yet; the editor installs them.
    private let missing = Mutex<Set<String>>([])
    private let notify: @Sendable () -> Void
    private let queue = DispatchQueue(label: "dev.orbit.highlight", qos: .userInitiated)

    // Confined to `queue`.
    private let parser = Parser()
    private let host: LanguageQueries
    private var theme: ColorTheme
    /// Indexed by capture id: whether the theme colors it.
    private var colored: [Bool] = []
    private var tree: MutableTree?
    private var text = TextSnapshot(string: "")
    private var lineStarts = [0]
    private var version = 0
    private var invalid = IndexSet()
    private var layers: [Layer] = []
    /// Text whose embedded languages may have changed since they were last looked for.
    private var injectionsDirty = IndexSet()
    private var parsers: [String: Parser] = [:]

    /// Background patches cover at most this much text, so a new edit never
    /// waits long behind them.
    private static let chunkLength = 8 * 1024
    /// Embedded in embedded in embedded, at most (HTML in Markdown's text in a doc comment…).
    private static let maxDepth = 3
    private static let maxLayers = 5000
    /// Layers up to this long are parsed from scratch after an edit.
    private static let freshParseLength = 16 * 1024

    /// `notify` is called on any thread whenever patches are ready.
    init?(grammar: Grammar, theme: ColorTheme, notify: @escaping @Sendable () -> Void) {
        guard let host = HighlightQueries.queries(for: grammar), (try? parser.setLanguage(host.language)) != nil else { return nil }
        self.host = host
        self.theme = theme
        self.notify = notify
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

    /// A grammar got installed: embedded languages that had none get one now.
    func reloadLayers() {
        post { $0.reloadsLayers = true }
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

    /// Embedded languages that need installing (`SyntaxLanguage` names).
    func takeMissingGrammars() -> Set<String> {
        missing.withLock { names in
            defer { names.removeAll() }
            return names
        }
    }

    /// The embedded-language layers, described (tests).
    func layerDescriptions() -> [String] {
        queue.sync { layers.map { "\($0.depth) \($0.queries.grammar.key) \($0.range) tree: \($0.tree != nil)" } }
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
                inbox.reloadsLayers = false
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
            layers.removeAll()
            invalid = IndexSet(integersIn: 0..<snapshot.length)
            injectionsDirty = invalid
            self.version = version
            needsParse = true
        }
        for (edit, snapshot, version) in taken.edits {
            apply(edit, snapshot: snapshot)
            self.version = version
            needsParse = true
        }
        if let theme = taken.theme {
            self.theme = theme
            let old = colored
            colored.removeAll()
            if old != (0..<old.count).map({ isColored(UInt16($0)) }) {
                invalid = IndexSet(integersIn: 0..<text.length)
            }
        }
        if taken.reloadsLayers {
            for layer in layers { invalid.insert(integersIn: Range(layer.range) ?? 0..<0) }
            layers.removeAll()
            injectionsDirty = IndexSet(integersIn: 0..<text.length)
        }
        let focus = Self.clamp(taken.focus, to: text.length)
        var answered = false
        if taken.reset != nil, !taken.waiters.isEmpty, text.length > Self.firstScreenLength, colorFirstScreen(focus) {
            for waiter in taken.waiters { waiter.signal() }
            answered = true
        }
        if needsParse { parse() }
        if needsParse || taken.reloadsLayers { updateLayers() }

        // What's on screen goes out first and in one piece; the main thread may be waiting for it.
        let onScreen = invalid.intersection(IndexSet(integersIn: Range(focus) ?? 0..<0))
        if !onScreen.isEmpty {
            deliver(onScreen)
        }
        if !answered {
            for waiter in taken.waiters { waiter.signal() }
        }

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
        injectionsDirty = edit.map(injectionsDirty)
        injectionsDirty.insert(integersIn: Range(lines) ?? start..<start)
        for index in layers.indices { apply(edit, to: &layers[index], snapshot: snapshot) }
    }

    /// Layers after the edit move; one it lands inside takes it into its tree.
    private func apply(_ edit: TextEdit, to layer: inout Layer, snapshot: TextSnapshot) {
        let anchorLower = edit.map(layer.anchor.location)
        layer.anchor = NSRange(location: anchorLower, length: max(0, edit.map(NSMaxRange(layer.anchor)) - anchorLower))
        let lower = layer.range.location, upper = NSMaxRange(layer.range)
        let editEnd = NSMaxRange(edit.range)
        if editEnd < lower {
            layer.range.location += edit.delta
            return
        }
        guard edit.range.location <= upper else { return }
        layer.isEdited = true
        guard edit.range.location >= lower, editEnd <= upper, layer.tree != nil else {
            // Across its edge: it's looked for again and parsed afresh.
            layer.tree = nil
            let mappedLower = edit.map(lower)
            layer.range = NSRange(location: mappedLower, length: max(0, edit.map(upper) - mappedLower))
            return
        }
        let start = edit.range.location - lower
        let oldEnd = start + edit.range.length, newEnd = start + edit.newLength
        let startPoint = Self.point(at: start, in: layer.lineStarts)
        let oldEndPoint = Self.point(at: oldEnd, in: layer.lineStarts)
        layer.range.length += edit.delta
        guard NSMaxRange(layer.range) <= snapshot.length else {
            layer.tree = nil
            return
        }
        layer.text = snapshot.string.substring(with: layer.range) as NSString
        layer.lineStarts = LineStarts.of(layer.text)
        layer.tree?.edit(InputEdit(
            startByte: start * 2, oldEndByte: oldEnd * 2, newEndByte: newEnd * 2,
            startPoint: startPoint, oldEndPoint: oldEndPoint, newEndPoint: Self.point(at: newEnd, in: layer.lineStarts)
        ))
    }

    /// Longer texts color their first screen before the whole parse (D250).
    private static let firstScreenLength = 64 * 1024

    /// A long file's first screen, colored before the whole of it is parsed:
    /// a 6 000-line file never parsed within the 40 ms an open waits, so the
    /// wait was spent and the screen came up gray. Its start is parsed alone,
    /// then the rest is given to that tree as text added at the end: the whole
    /// parse reuses it, and only what it changed goes out again.
    private func colorFirstScreen(_ focus: NSRange) -> Bool {
        let string = text.string
        let cut = NSMaxRange(string.lineRange(for: NSRange(location: min(string.length, NSMaxRange(focus)), length: 0)))
        guard cut < string.length, let start = Self.parse(string.substring(to: cut) as NSString, with: parser, old: nil) else { return false }
        tree = start
        deliver(invalid.intersection(IndexSet(integersIn: (Range(focus) ?? 0..<0).clamped(to: 0..<cut))))
        start.edit(InputEdit(
            startByte: cut * 2, oldEndByte: cut * 2, newEndByte: string.length * 2,
            startPoint: point(at: cut), oldEndPoint: point(at: cut), newEndPoint: point(at: string.length)
        ))
        return true
    }

    private func parse() {
        let newTree = Self.parse(text.string, with: parser, old: tree)
        if let oldTree = tree, let newTree {
            let length = text.length
            // SwiftTreeSitter passes the receiver as tree-sitter's *old* tree;
            // called on the new one, structural changes (a fence closed) went unseen.
            for changed in oldTree.changedRanges(from: newTree) {
                let lower = Int(changed.bytes.lowerBound) / 2, upper = min(Int(changed.bytes.upperBound) / 2, length)
                if upper > lower {
                    invalid.insert(integersIn: lower..<upper)
                    injectionsDirty.insert(integersIn: lower..<upper)
                }
            }
        }
        tree = newTree
    }

    private static func parse(_ string: NSString, with parser: Parser, old: MutableTree?) -> MutableTree? {
        let length = string.length
        return parser.parse(tree: old, readBlock: { byte, _ in
            let start = byte / 2
            guard start < length else { return nil }
            let count = min(16 * 1024, length - start)
            var data = Data(count: count * 2)
            data.withUnsafeMutableBytes { buffer in
                string.getCharacters(buffer.baseAddress!.assumingMemoryBound(to: unichar.self), range: NSRange(location: start, length: count))
            }
            return data
        })
    }

    // MARK: Embedded languages

    /// Looks for embedded languages again where the text changed: layers
    /// elsewhere stay as they are, ones found again keep their trees.
    private func updateLayers() {
        defer { injectionsDirty = IndexSet() }
        guard host.injections != nil || !layers.isEmpty, !injectionsDirty.isEmpty, let tree else { return }

        // A layer the change touches is looked for whole, with what it embeds.
        var dirty = injectionsDirty
        for layer in layers where layer.depth == 1 && (layer.isEdited || dirty.intersects(integersIn: layer.extent)) {
            dirty.insert(integersIn: layer.extent)
        }
        var kept: [Layer] = []
        var reusable: [String: Layer] = [:]
        for layer in layers {
            if layer.isEdited || dirty.intersects(integersIn: layer.extent) {
                reusable[layer.key] = layer
            } else {
                kept.append(layer)
            }
        }

        var added: [Layer] = []
        /// Everything looked for again, found with a grammar or not.
        var refound: [(depth: Int, range: NSRange)] = []
        var found = Self.injections(in: tree, queries: host, text: text.string, base: 0, within: dirty)
        var depth = 1
        while !found.isEmpty, depth <= Self.maxDepth {
            var deeper: [Injection] = []
            var seen = Set<String>()
            for injection in found where kept.count + added.count < Self.maxLayers {
                let range = injection.range
                refound.append((depth, range))
                if let language = Grammar.languageToInstall(named: injection.name) {
                    _ = missing.withLock { $0.insert(language.name) }
                }
                guard let grammar = Grammar.named(injection.name) else { continue }
                let key = "\(grammar.key)@\(range.location)"
                guard let queries = HighlightQueries.queries(for: grammar), seen.insert(key).inserted,
                      var layer = layer(for: queries, injection: injection, depth: depth, reusing: reusable.removeValue(forKey: key))
                else { continue }
                layer.isEdited = false
                added.append(layer)
                if let tree = layer.tree, depth < Self.maxDepth {
                    deeper += Self.injections(in: tree, queries: queries, text: layer.text, base: layer.range.location, within: nil)
                }
            }
            found = deeper
            depth += 1
        }
        // An injection found again replaces what was there: changed ranges miss
        // some merges (two paragraphs becoming one), and a fence's language
        // can change while its code doesn't.
        kept.removeAll { old in
            let covered = refound.contains { $0.depth <= old.depth && NSIntersectionRange($0.range, old.range).length > 0 }
            if covered { reusable[old.key + "#covered"] = old }
            return covered
        }
        for layer in reusable.values { invalid.insert(integersIn: Range(layer.range) ?? 0..<0) }
        layers = (kept + added).sorted { ($0.depth, $0.range.location) < ($1.depth, $1.range.location) }
    }

    /// A parsed layer, from the old one when it's the same language at the same place.
    private func layer(for queries: LanguageQueries, injection: Injection, depth: Int, reusing old: Layer?) -> Layer? {
        let range = injection.range
        guard NSMaxRange(range) <= text.length else { return nil }
        if var old, old.range == range, !old.isEdited, old.tree != nil {
            old.anchor = injection.anchor
            return old
        }
        let parser = parsers[queries.grammar.key] ?? {
            let parser = Parser()
            try? parser.setLanguage(queries.language)
            parsers[queries.grammar.key] = parser
            return parser
        }()
        let string = text.string.substring(with: range) as NSString
        // Small layers are parsed afresh: Markdown's inline grammar, parsed
        // incrementally, ends up with a different tree than a fresh parse in
        // about half of random edit runs, and a paragraph takes no time to parse.
        let oldTree = old?.range.length == range.length && range.length > Self.freshParseLength ? old?.tree : nil
        guard let tree = Self.parse(string, with: parser, old: oldTree) else { return nil }
        if let oldTree {
            for changed in oldTree.changedRanges(from: tree) {
                let lower = Int(changed.bytes.lowerBound) / 2, upper = min(Int(changed.bytes.upperBound) / 2, range.length)
                if upper > lower { invalid.insert(integersIn: (range.location + lower)..<(range.location + upper)) }
            }
        } else {
            invalid.insert(integersIn: Range(range) ?? 0..<0)
        }
        return Layer(queries: queries, range: range, anchor: injection.anchor, depth: depth, tree: tree, text: string, lineStarts: LineStarts.of(string))
    }

    /// What a tree embeds. Zed's queries
    /// (`@content`, `@language`, `#set! language`) and nvim's (`@injection.*`)
    /// both work; `#offset!` trims the content (a template's backticks).
    private static func injections(in tree: MutableTree, queries: LanguageQueries, text: NSString, base: Int, within: IndexSet?) -> [Injection] {
        guard let query = queries.injections, let root = tree.rootNode else { return [] }
        let provider: SwiftTreeSitter.Predicate.TextProvider = { range, _ in
            NSMaxRange(range) <= text.length ? text.substring(with: range) : nil
        }
        let runs: [NSRange?] = within.map { $0.rangeView.map { NSRange(location: $0.lowerBound - base, length: $0.count) } } ?? [nil]
        var result: [Injection] = []
        var seen = Set<NSRange>()
        for run in runs {
            let cursor = query.execute(node: root, in: tree)
            if let run { cursor.setRange(run) }
            for match in cursor.resolve(with: Predicate.Context(textProvider: provider)) {
                guard let content = match.captures.first(where: { $0.name == "injection.content" || $0.name == "content" }) else { continue }
                var name = match.metadata["injection.language"] ?? match.metadata["language"]
                    ?? content.metadata["injection.language"] ?? content.metadata["language"]
                if let node = match.captures.first(where: { $0.name == "injection.language" || $0.name == "language" })?.node {
                    name = provider(node.range, node.pointRange) ?? name
                }
                guard let name else { continue }
                var range = content.node.range
                for case let .generic("offset!", strings, captureNames) in match.predicates
                where captureNames.contains(content.name ?? "") && strings.count == 4 {
                    let start = Int(strings[1]) ?? 0, end = Int(strings[3]) ?? 0
                    range = NSRange(location: range.location + start, length: max(0, range.length - start + end))
                }
                guard range.length > 0, seen.insert(range).inserted else { continue }
                let anchor = match.range.map { NSUnionRange($0, range) } ?? range
                result.append(Injection(
                    name: name,
                    range: NSRange(location: range.location + base, length: range.length),
                    anchor: NSRange(location: anchor.location + base, length: anchor.length)
                ))
            }
        }
        return result
    }

    // MARK: Highlights

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
        guard range.length > 0, let tree else { return [] }
        // Later captures are more specific and win, like painting over; layers paint over the file.
        var paint = [UInt16](repeating: 0, count: range.length)
        self.paint(&paint, range: range, tree: tree, queries: host, text: text.string, base: 0)
        for layer in layers where NSIntersectionRange(layer.range, range).length > 0 {
            guard let layerTree = layer.tree else { continue }
            self.paint(&paint, range: range, tree: layerTree, queries: layer.queries, text: layer.text, base: layer.range.location)
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

    /// Paints one tree's captures in `range` (document offsets); the tree's own
    /// offsets start at `base`.
    private func paint(_ paint: inout [UInt16], range: NSRange, tree: MutableTree, queries: LanguageQueries, text: NSString, base: Int) {
        guard let root = tree.rootNode else { return }
        // Clamped by hand: on macOS NSIntersectionRange takes unsigned values, so
        // a range starting before the layer (negative here) came out empty.
        let lower = max(0, range.location - base), upper = min(text.length, NSMaxRange(range) - base)
        guard upper > lower else { return }
        let local = NSRange(location: lower, length: upper - lower)
        let cursor = queries.highlights.execute(node: root, in: tree)
        cursor.setRange(local)
        let context = Predicate.Context(textProvider: { range, _ in
            NSMaxRange(range) <= text.length ? text.substring(with: range) : nil
        })
        for highlight in cursor.resolve(with: context).highlights() {
            guard let id = queries.ids[highlight.name] else { continue }
            let isNone = id == CaptureTable.none
            guard isNone || isColored(id) else { continue }
            let clipped = NSIntersectionRange(NSRange(location: highlight.range.location + base, length: highlight.range.length), range)
            guard clipped.length > 0 else { continue }
            let lower = clipped.location - range.location
            let value = isNone ? 0 : id
            paint.withUnsafeMutableBufferPointer { buffer in
                for index in lower..<(lower + clipped.length) { buffer[index] = value }
            }
        }
    }

    private func isColored(_ id: UInt16) -> Bool {
        let index = Int(id)
        if index >= colored.count {
            colored += CaptureTable.names(from: colored.count).map { theme.style(forCapture: $0)?.color != nil }
        }
        return index < colored.count && colored[index]
    }

    private func point(at offset: Int) -> Point {
        Self.point(at: offset, in: lineStarts)
    }

    private static func point(at offset: Int, in lineStarts: [Int]) -> Point {
        let row = max(0, LineStarts.firstIndex(in: lineStarts, after: offset) - 1)
        return Point(row: row, column: (offset - lineStarts[row]) * 2)
    }

    // MARK: Helpers

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
