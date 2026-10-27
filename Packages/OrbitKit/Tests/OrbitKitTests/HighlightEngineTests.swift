import Foundation
import SwiftTreeSitter
import Testing
@testable import OrbitAPI
@testable import OrbitEditor

@Suite struct HighlightEngineTests {
    @Test func editMapsOffsets() {
        let edit = TextEdit(range: NSRange(location: 5, length: 3), newLength: 1)
        #expect(edit.map(2) == 2)
        #expect(edit.map(5) == 5)
        #expect(edit.map(6) == 5)
        #expect(edit.map(8) == 6)
        #expect(edit.map(20) == 18)
    }

    @Test func trimmedKeepsCommonHeadAndTail() {
        let old = "let a = 1\nlet b = 2\n" as NSString
        let new = "let a = 1\nlet bb = 2\n" as NSString
        let whole = TextEdit(range: NSRange(location: 0, length: old.length), newLength: new.length)
        let trimmed = whole.trimmed(old: old, new: new)
        #expect(trimmed == TextEdit(range: NSRange(location: 15, length: 0), newLength: 1))
    }

    @Test func spansShiftAndReplace() {
        var spans = HighlightSpans()
        spans.replace(in: NSRange(location: 0, length: 20), with: [
            HighlightSpan(start: 0, end: 4, capture: 1),
            HighlightSpan(start: 10, end: 14, capture: 2),
        ])
        // Typing inside a token widens it; spans after the edit move.
        spans.apply(TextEdit(range: NSRange(location: 2, length: 0), newLength: 2))
        #expect(spans.spans == [HighlightSpan(start: 0, end: 6, capture: 1), HighlightSpan(start: 12, end: 16, capture: 2)])
        // A replacement keeps what lies outside its range.
        spans.replace(in: NSRange(location: 3, length: 10), with: [HighlightSpan(start: 4, end: 5, capture: 3)])
        #expect(spans.spans == [
            HighlightSpan(start: 0, end: 3, capture: 1),
            HighlightSpan(start: 4, end: 5, capture: 3),
            HighlightSpan(start: 13, end: 16, capture: 2),
        ])
    }

    @Test func lineStartsFollowEdits() {
        var generator = SeededGenerator(seed: 7)
        var text = "a\nbc\n\ndef\n"
        var starts = LineStarts.of(text as NSString)
        for _ in 0..<200 {
            let (edit, new) = Self.randomEdit(of: text, using: &generator)
            text = new
            starts = LineStarts.updated(starts, after: edit, in: text as NSString)
            #expect(starts == LineStarts.of(text as NSString))
        }
    }

    /// The incremental pipeline (shifted cache, background reparses, patches
    /// that arrive after later edits) must end up where a fresh highlight does.
    @MainActor
    @Test func incrementalHighlightsMatchFreshOnes() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/OrbitEditor/HighlightEngine.swift")
        var text = String(try String(contentsOf: source, encoding: .utf8).prefix(6000))
        let theme = Extensions.shared.colorTheme(dark: false)
        let swift = try TestGrammars.grammar("Swift")

        let worker = try #require(Self.worker(swift, theme))
        var cache = HighlightCache()
        worker.reset(TextSnapshot(string: text as NSString), version: cache.version)
        worker.waitUntilIdle()
        _ = cache.apply(worker.takePatches())

        var generator = SeededGenerator(seed: 42)
        for step in 0..<300 {
            let (edit, new) = Self.randomEdit(of: text, using: &generator)
            text = new
            let version = cache.apply(edit)
            worker.setFocus(NSRange(location: max(0, edit.range.location - 500), length: 1000))
            worker.edit(edit, snapshot: TextSnapshot(string: text as NSString), version: version)
            if step % 5 == 0 { worker.waitUntilIdle() }
            _ = cache.apply(worker.takePatches())
        }
        worker.waitUntilIdle()
        _ = cache.apply(worker.takePatches())

        let fresh = try #require(Self.worker(swift, theme))
        var freshCache = HighlightCache()
        fresh.reset(TextSnapshot(string: text as NSString), version: 0)
        fresh.waitUntilIdle()
        _ = freshCache.apply(fresh.takePatches())

        #expect(!freshCache.spans.spans.isEmpty)
        #expect(Self.merged(cache.spans.spans) == Self.merged(freshCache.spans.spans))
    }

    /// A long file's first screen comes from a parse of its start (D250), here
    /// with a comment opened on it and closed past it; the whole parse after
    /// ends where a highlight without that step does.
    @MainActor
    @Test func firstScreenEndsAsTheWholeParse() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/OrbitEditor/HighlightEngine.swift")
        let code = try String(contentsOf: source, encoding: .utf8)
        let text = String(code.prefix(15_000)) + "\n/* opened on the first screen\n" + code + "\n*/\n" + code + code
        #expect((text as NSString).length > 64 * 1024)
        let theme = Extensions.shared.colorTheme(dark: false)
        let swift = try TestGrammars.grammar("Swift")

        let worker = try #require(Self.worker(swift, theme))
        var cache = HighlightCache()
        let waiter = DispatchSemaphore(value: 0)
        worker.setFocus(NSRange(location: 0, length: 16 * 1024))
        worker.reset(TextSnapshot(string: text as NSString), version: cache.version, waiter: waiter)
        waiter.wait()
        let firstScreen = worker.takePatches()
        #expect(!firstScreen.isEmpty)
        _ = cache.apply(firstScreen)
        worker.waitUntilIdle()
        _ = cache.apply(worker.takePatches())

        let whole = try #require(Self.worker(swift, theme))
        var wholeCache = HighlightCache()
        whole.reset(TextSnapshot(string: text as NSString), version: 0)
        whole.waitUntilIdle()
        _ = wholeCache.apply(whole.takePatches())

        #expect(Self.merged(cache.spans.spans) == Self.merged(wholeCache.spans.spans))
    }

    /// `</div>` typed at the top of a long Swift file makes the rest one
    /// expression: each chunk's query followed it to the file's end, minutes
    /// in all (D250). Queried from below it, the file is colored in seconds
    /// and a chunk colors as a query from the root does.
    @MainActor
    @Test func aNodeRunningPastTheChunkDoesNotSlowItsQuery() throws {
        let body = (0..<6000).map { "func f\($0)(_ x: Int) -> Int { x * \($0) } // \(String(repeating: "·", count: $0 % 90))\n" }.joined()
        let text = String(body.prefix(34)) + "func f() {\n    return 1\n}\n()</div>" + String(body.dropFirst(34))
        let swift = try TestGrammars.grammar("Swift")
        let queries = try #require(HighlightQueries.queries(for: swift))
        let parser = Parser()
        try parser.setLanguage(queries.language)
        let tree = try #require(parser.parse(text))
        let root = try #require(tree.rootNode)
        func captures(from starts: [Node], in range: NSRange) -> [String] {
            starts.flatMap { start in
                let cursor = queries.highlights.execute(node: start, in: tree)
                cursor.setRange(range)
                return cursor.flatMap(\.captures).map { "\($0.range) \($0.name ?? "")" }
            }.sorted()
        }
        // Near the end, where a query from the root is still quick.
        let late = NSRange(location: 467_173, length: 8 * 1024)
        #expect(HighlightWorker.queryRoots(root, for: late) != [root])
        #expect(captures(from: HighlightWorker.queryRoots(root, for: late), in: late) == captures(from: [root], in: late))

        let worker = try #require(Self.worker(swift, Extensions.shared.colorTheme(dark: false)))
        let started = Date()
        worker.reset(TextSnapshot(string: text as NSString), version: 0)
        worker.waitUntilIdle()
        #expect(Date().timeIntervalSince(started) < 20)
        // A file like any other is queried from its root.
        let plain = try #require(parser.parse(body)?.rootNode)
        #expect(HighlightWorker.queryRoots(plain, for: late) == [plain])
    }

    /// Embedded languages (D69): a fence's code is colored by its language, and
    /// edits that open, close or retag fences end where a fresh highlight does.
    @MainActor
    @Test func embeddedLanguagesFollowEdits() throws {
        let theme = Extensions.shared.colorTheme(dark: false)
        let markdown = try TestGrammars.grammar("Markdown", "Markdown-Inline", "JavaScript", "CSS", "HTML")
        func make() throws -> HighlightWorker {
            // Outside #require: its expansion can't take the non-Sendable closure literal.
            let worker = HighlightWorker(grammar: markdown, theme: theme, notify: {})
            return try #require(worker)
        }
        func fresh(_ text: String) throws -> HighlightCache {
            let worker = try make()
            var cache = HighlightCache()
            worker.reset(TextSnapshot(string: text as NSString), version: 0)
            worker.waitUntilIdle()
            _ = cache.apply(worker.takePatches())
            return cache
        }

        var text = "# Title\n\nSome *text*.\n\n```js\nconst answer = 42\n```\n\n<style>\na { color: red; }\n</style>\n"
        let names = { CaptureTable.names(from: 0) }
        let first = try fresh(text)
        let probe = try make()
        probe.reset(TextSnapshot(string: text as NSString), version: 0)
        probe.waitUntilIdle()
        let layers = probe.layerDescriptions()
        let fence = (text as NSString).range(of: "const answer = 42")
        let colored = first.spans.spans.filter { $0.end > fence.location && $0.start < NSMaxRange(fence) }.map {
            "\((text as NSString).substring(with: NSRange(location: $0.start, length: $0.end - $0.start))) \(names()[Int($0.capture)])"
        }
        #expect(colored.contains { $0.hasPrefix("const keyword") }, """
            \(colored); markdown injections: \(HighlightQueries.queries(for: markdown)?.injections != nil), \
            js: \(Grammar.named("js")?.key ?? "nil"), keyword styled: \(theme.style(forCapture: "keyword")?.color != nil), \
            layers: \(layers)
            """)

        let worker = try make()
        var cache = HighlightCache()
        worker.reset(TextSnapshot(string: text as NSString), version: cache.version)
        worker.waitUntilIdle()
        _ = cache.apply(worker.takePatches())
        var generator = SeededGenerator(seed: 11)
        let pieces = ["```", "js\n", "```css\n", "*", "`", "\n", "<style>", "a { color: red }", "</style>", "const x = 1", "", "\n\n", "# "]
        for step in 0..<300 {
            let string = text as NSString
            let location = Int.random(in: 0...string.length, using: &generator)
            let length = Int.random(in: 0...min(8, string.length - location), using: &generator)
            let insert = pieces.randomElement(using: &generator)! as NSString
            text = string.replacingCharacters(in: NSRange(location: location, length: length), with: insert as String)
            let version = cache.apply(TextEdit(range: NSRange(location: location, length: length), newLength: insert.length))
            worker.setFocus(NSRange(location: max(0, location - 300), length: 600))
            worker.edit(TextEdit(range: NSRange(location: location, length: length), newLength: insert.length),
                        snapshot: TextSnapshot(string: text as NSString), version: version)
            if step % 4 == 0 { worker.waitUntilIdle() }
            _ = cache.apply(worker.takePatches())
        }
        worker.waitUntilIdle()
        _ = cache.apply(worker.takePatches())
        #expect(Self.merged(cache.spans.spans) == Self.merged(try fresh(text).spans.spans))
    }

    /// Neighbors with the same capture look the same; edits and patch edges may leave them split.
    static func merged(_ spans: [HighlightSpan]) -> [HighlightSpan] {
        var result: [HighlightSpan] = []
        for span in spans {
            if let last = result.last, last.end == span.start, last.capture == span.capture {
                result[result.count - 1].end = span.end
            } else {
                result.append(span)
            }
        }
        return result
    }

    static func worker(_ grammar: Grammar, _ theme: ColorTheme) -> HighlightWorker? {
        HighlightWorker(grammar: grammar, theme: theme, notify: {})
    }

    static func randomEdit(of text: String, using generator: inout SeededGenerator) -> (TextEdit, String) {
        let pieces = ["\"", "func ", "}", "{", "\n", "// ", "x", "let a = 1", "/*", "*/", "", "\n\n", "case .a:"]
        let string = text as NSString
        let location = Int.random(in: 0...string.length, using: &generator)
        let length = Int.random(in: 0...min(8, string.length - location), using: &generator)
        let insert = pieces.randomElement(using: &generator)! as NSString
        let new = string.replacingCharacters(in: NSRange(location: location, length: length), with: insert as String)
        return (TextEdit(range: NSRange(location: location, length: length), newLength: insert.length), new)
    }
}

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
