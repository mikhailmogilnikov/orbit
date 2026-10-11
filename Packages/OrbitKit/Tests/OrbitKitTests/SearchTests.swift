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

    @Test func quickOpenNudgesRecentFiles() {
        let entries = ["a/Model.swift", "b/deeper/Model.swift"].map(IndexedPath.init)
        #expect(QuickOpen.rank("model", entries: entries).first?.path == "a/Model.swift")
        #expect(QuickOpen.rank("model", entries: entries, recentBonus: ["b/deeper/Model.swift": 15]).first?.path == "b/deeper/Model.swift")
    }
}

@Suite struct PathFilterTests {
    @Test func includeGlobs() {
        func included(_ path: String, _ include: String) -> Bool { PathFilter(include: include).allows(path) }
        #expect(included("a/b/c.swift", "*.swift"))
        #expect(!included("a/c.swiftx", "*.swift"))
        // A folder name covers everything inside it, at any depth unless anchored with "/".
        #expect(included("Sources/OrbitSearch/X.swift", "Sources"))
        #expect(included("Packages/Kit/Sources/X.swift", "Sources"))
        #expect(!included("Packages/Kit/Sources/X.swift", "/Sources"))
        #expect(included("docs/a.md", "docs/*.md"))
        #expect(!included("docs/x/a.md", "docs/*.md"))
        #expect(included("docs/x/a.md", "docs/**/*.md"))
        #expect(included("docs/a.md", "docs/**/*.md"))
        #expect(included("a.m", "*.{h,m}, *.c"))
        #expect(included("a.c", "*.{h,m}, *.c"))
        #expect(!included("a.cpp", "*.{h,m}"))
        #expect(included("a1.txt", "a[0-9].txt"))
        #expect(!included("a1.txt", "a[!0-9].txt"))
        #expect(included("a(1).txt", "a(1).txt"))
        #expect(included("README.md", "readme.md"))
    }

    @Test func excludeGlobs() {
        let filter = PathFilter(include: "*.swift", exclude: "Tests, build/")
        #expect(filter.allows("Sources/A.swift"))
        #expect(!filter.allows("Tests/ATests.swift"))
        #expect(!filter.allows("x/build/Gen.swift"))
        #expect(!filter.allows("Sources/a.md"))
        #expect(PathFilter(include: " , ").isEmpty)
    }
}

@Suite struct ReplaceTests {
    @Test func literalReplacementIgnoresTemplateSyntax() throws {
        let options = SearchOptions()
        let regex = try TextSearch.makeRegex("a.b", options: options)
        let result = TextSearch.replace(in: "a.b axb a.b", regex: regex, template: TextSearch.template(for: "$1\\x", options: options))
        #expect(result.text == "$1\\x axb $1\\x")
        #expect(result.count == 2)
    }

    @Test func regexReplacementUsesGroups() throws {
        let options = SearchOptions(wholeWord: true, regex: true)
        let regex = try TextSearch.makeRegex("(\\w+)Old", options: options)
        let result = TextSearch.replace(in: "fooOld barOld bazOldish", regex: regex, template: TextSearch.template(for: "$1New", options: options))
        #expect(result.text == "fooNew barNew bazOldish")
        #expect(result.count == 2)
    }

    @Test func skipsEmptyMatchesAndKeepsTextWithoutMatches() throws {
        let options = SearchOptions(regex: true)
        let regex = try TextSearch.makeRegex("x*", options: options)
        let replaced = TextSearch.replace(in: "axxb", regex: regex, template: "-")
        #expect(replaced.text == "a-b" && replaced.count == 1)
        let untouched = TextSearch.replace(in: "ab", regex: regex, template: "-")
        #expect(untouched.text == "ab" && untouched.count == 0)
    }

    @Test func searchPreviewsReplacements() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-replace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "let oldName = oldName + 1\n".write(to: root.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)

        let result = try await TextSearch.run("old(\\w+)", options: SearchOptions(regex: true), root: root, paths: ["a.swift"], replacement: "new$1")
        let match = try #require(result.files.first?.matches.first)
        #expect(match.replacements == ["newName", "newName"])
        #expect(match.ranges.count == 2)

        let plain = try await TextSearch.run("oldName", options: SearchOptions(), root: root, paths: ["a.swift"])
        #expect(plain.files.first?.matches.first?.replacements == nil)
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
