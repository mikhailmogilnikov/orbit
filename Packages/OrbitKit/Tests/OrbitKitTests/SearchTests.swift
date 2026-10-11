import Foundation
@testable import OrbitAPI
@testable import OrbitSearch
import Testing

@Suite struct FuzzyMatchTests {
    @Test func matchesSubsequence() throws {
        let match = try #require(FuzzyMatch.match("inldif", in: "InlineDiff.swift"))
        #expect(match.positions == [0, 1, 2, 6, 7, 8])
        #expect(FuzzyMatch.match("xyz", in: "InlineDiff.swift") == nil)
    }

    @Test func prefersWordStarts() throws {
        let camel = try #require(FuzzyMatch.match("id", in: "InlineDiff"))
        let plain = try #require(FuzzyMatch.match("id", in: "Ideal"))
        #expect(camel.score > 0 && plain.score > 0)
        #expect(FuzzyMatch.match("ID", in: "inlinediff") != nil)
    }

    @Test func quickOpenRanksFileNamesFirst() {
        let paths = ["Sources/Diff/Other.swift", "App/MainWindow.swift", "Sources/OrbitEditor/InlineDiff.swift", "Docs/inline-diff-notes.md"]
        let ranked = QuickOpen.rank("inldiff", entries: paths.map(IndexedPath.init)).map(\.path)
        #expect(ranked.first == "Sources/OrbitEditor/InlineDiff.swift")
        #expect(!ranked.contains("App/MainWindow.swift"))
        // Path-only matches are still found.
        #expect(QuickOpen.rank("orbiteditor", entries: paths.map(IndexedPath.init)).map(\.path) == ["Sources/OrbitEditor/InlineDiff.swift"])
        // Non-ASCII paths take the general matcher and agree with it.
        let unicode = QuickOpen.rank("заметки", entries: [IndexedPath("docs/Заметки.md")])
        #expect(unicode.first?.namePositions == Array(0..<7))
    }
}

@Suite struct TextSearchTests {
    private func makeProject(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-search-\(UUID().uuidString)")
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test func findsMatchesWithLinesAndRanges() async throws {
        let root = try makeProject([
            "a.swift": "let foo = 1\n    foo += foo\nbar\n",
            "dir/b.txt": "nothing here\nFOO\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = FileLister.list(root: root)
        #expect(paths == ["a.swift", "dir/b.txt"])

        let result = try await TextSearch.run("foo", options: SearchOptions(), root: root, paths: paths)
        #expect(result.files.map(\.path) == ["a.swift", "dir/b.txt"])
        let a = result.files[0].matches
        #expect(a.map(\.line) == [0, 1])
        // Indentation trimmed, both matches on the line highlighted.
        #expect(a[1].preview == "foo += foo")
        #expect(a[1].ranges == [NSRange(location: 0, length: 3), NSRange(location: 7, length: 3)])

        let sensitive = try await TextSearch.run("foo", options: SearchOptions(caseSensitive: true), root: root, paths: paths)
        #expect(sensitive.files.map(\.path) == ["a.swift"])
    }

    @Test func wholeWordRegexAndOverrides() async throws {
        let root = try makeProject(["a.txt": "food foo\nx12 y3\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        let word = try await TextSearch.run("foo", options: SearchOptions(wholeWord: true), root: root, paths: ["a.txt"])
        #expect(word.files[0].matches[0].ranges == [NSRange(location: 5, length: 3)])

        let regex = try await TextSearch.run("[a-z]\\d+", options: SearchOptions(regex: true), root: root, paths: ["a.txt"])
        #expect(regex.matchCount == 1)
        #expect(regex.files[0].matches[0].ranges.count == 2)

        await #expect(throws: TextSearch.Failure.self) {
            try await TextSearch.run("(", options: SearchOptions(regex: true), root: root, paths: ["a.txt"])
        }

        // Unsaved buffer contents win over the disk.
        let unsaved = try await TextSearch.run("unsaved", options: SearchOptions(), root: root, paths: ["a.txt"], overrides: ["a.txt": "unsaved edit"])
        #expect(unsaved.matchCount == 1)
    }

    @Test func clipsLongLinesAroundTheMatch() throws {
        let line = String(repeating: "x", count: 300) + "needle" + String(repeating: "y", count: 300)
        let regex = try TextSearch.makeRegex("needle", options: SearchOptions())
        let match = try #require(TextSearch.search(line, regex: regex, path: "f").first)
        #expect(match.preview.hasPrefix("…"))
        let range = try #require(match.ranges.first)
        #expect((match.preview as NSString).substring(with: range) == "needle")
    }

    @Test func skipsBinaryFiles() throws {
        let root = try makeProject([:])
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0x66, 0x6F, 0x6F, 0x00, 0x01]).write(to: url)
        #expect(TextSearch.readText(url) == nil)
    }
}
