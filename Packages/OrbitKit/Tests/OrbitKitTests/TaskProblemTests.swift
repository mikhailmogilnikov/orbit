import Foundation
@testable import OrbitAPI
@testable import OrbitEditor
@testable import OrbitLanguages
@testable import OrbitPreview
@testable import OrbitTerminal
import Testing

@Suite struct TaskProblemTests {
    private func project(_ files: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tasks-\(UUID().uuidString)")
        for file in files {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "{}".write(to: url, atomically: true, encoding: .utf8)
        }
        return root.standardizedFileURL
    }

    private func parse(_ output: String, in root: URL) -> [URL: [Diagnostic]] {
        var parser = TaskOutputParser(directories: [root])
        parser.feed(Array(output.utf8))
        return parser.problems
    }

    @Test func readsCompilerOutputForFilesThatExist() throws {
        let root = try project(["src/a.ts", "Sources/App/main.swift", "main.go", "src/main.rs"])
        let output = """
        src/a.ts(12,5): error TS2322: Type 'string' is not assignable to type 'number'.
        \u{1B}[96msrc/a.ts\u{1B}[0m:\u{1B}[93m3\u{1B}[0m:\u{1B}[93m7\u{1B}[0m - \u{1B}[91merror\u{1B}[0m TS2304: Cannot find name 'x'.
        /nope/missing.swift:1:1: error: not ours
        \(root.path)/Sources/App/main.swift:4:9: warning: variable 'y' was never used
        \(root.path)/Sources/App/main.swift:4:9: note: consider replacing it with '_'
        ./main.go:8:2: undefined: fmt.Printn
        Compiling at 12:30:45 – watching
        error[E0425]: cannot find value `z` in this scope
          --> src/main.rs:2:5

        """
        let problems = parse(output, in: root)
        let ts = try #require(problems[root.appendingPathComponent("src/a.ts")])
        #expect(ts.map(\.range.start.line) == [11, 2])
        #expect(ts.map(\.source) == ["TS2322", nil])
        #expect(ts[1].message == "Cannot find name 'x'.")
        let swift = try #require(problems[root.appendingPathComponent("Sources/App/main.swift")])
        #expect(swift.count == 1)
        #expect(swift[0].severity == .warning)
        #expect(swift[0].range.start == SourcePosition(line: 3, character: 8))
        #expect(problems[root.appendingPathComponent("main.go")]?.first?.message == "undefined: fmt.Printn")
        let rust = try #require(problems[root.appendingPathComponent("src/main.rs")]?.first)
        #expect(rust.message == "cannot find value `z` in this scope")
        #expect(rust.source == "E0425")
        #expect(problems.count == 4)
    }

    @Test func readsESLintBlocksAndForgetsOnAClearedScreen() throws {
        let root = try project(["web/app.js"])
        let file = root.appendingPathComponent("web/app.js")
        var parser = TaskOutputParser(directories: [root])
        parser.feed(Array("""

        \(file.path)
          3:10  error    'x' is defined but never used  no-unused-vars
          7:1   warning  Unexpected console statement   no-console

        ✖ 2 problems (1 error, 1 warning)

        """.utf8))
        let rows = try #require(parser.problems[file])
        #expect(rows.map(\.severity) == [.error, .warning])
        #expect(rows.map(\.source) == ["no-unused-vars", "no-console"])
        #expect(rows[0].message == "'x' is defined but never used")
        // Printed again by a watch mode: no duplicates; a cleared screen starts over.
        parser.feed(Array("\(file.path)\n  3:10  error    'x' is defined but never used  no-unused-vars\n".utf8))
        #expect(parser.problems[file]?.count == 2)
        parser.feed(Array("\u{1B}[2J\u{1B}[H\n".utf8))
        #expect(parser.problems.isEmpty)
    }

    @Test func devServerAddressIsRemembered() {
        var parser = TaskOutputParser(directories: [])
        parser.feed(Array("\n  \u{1B}[32m➜\u{1B}[39m  \u{1B}[1mLocal\u{1B}[22m:   \u{1B}[36mhttp://localhost:\u{1B}[1m5173\u{1B}[22m/\u{1B}[39m\n  ➜  Network: http://192.168.1.2:5173/\n".utf8))
        #expect(parser.localURL == URL(string: "http://localhost:5173/"))
        var next = TaskOutputParser(directories: [])
        next.feed(Array("Listening on http://0.0.0.0:8000\n".utf8))
        #expect(next.localURL == URL(string: "http://localhost:8000"))
    }

    @Test @MainActor func browserAddressesBecomeURLs() {
        #expect(BrowserPage.address("localhost:3000") == URL(string: "http://localhost:3000"))
        #expect(BrowserPage.address("127.0.0.1:8080/x") == URL(string: "http://127.0.0.1:8080/x"))
        #expect(BrowserPage.address("example.com") == URL(string: "https://example.com"))
        #expect(BrowserPage.address("http://0.0.0.0:4321/") == URL(string: "http://localhost:4321/"))
        #expect(BrowserPage.address("two words") == nil)
        #expect(BrowserPage.isLocal(URL(string: "http://app.localhost:3000")!))
    }

    @Test func progressRedrawsDontJoinLines() throws {
        let root = try project(["a.c"])
        let problems = parse("[1/3] building\r[2/3] building\ra.c:1:2: error: expected ';'\r\n", in: root)
        #expect(problems[root.appendingPathComponent("a.c")]?.first?.message == "expected ';'")
    }

    @Test func monorepoPackagesGetTheirOwnScripts() throws {
        let root = try project(["apps/web/package.json", "apps/docs/package.json", "packages/ui/package.json", "packages/legacy/package.json", "tools/x/package.json"])
        try #"{"scripts": {"dev": "turbo dev"}, "workspaces": ["apps/*", "packages/**", "!packages/legacy"]}"#
            .write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try #"{"scripts": {"dev": "vite", "build": "vite build"}}"#
            .write(to: root.appendingPathComponent("apps/web/package.json"), atomically: true, encoding: .utf8)
        try "".write(to: root.appendingPathComponent("pnpm-lock.yaml"), atomically: true, encoding: .utf8)
        #expect(ProjectTasks.packageDirectories(["apps/*", "packages/**", "!packages/legacy"], in: root) == ["apps/docs", "apps/web", "packages/ui"])
        let tasks = ProjectTasks.find(in: root)
        #expect(tasks.map(\.id) == ["package.json:dev", "apps/web/package.json:dev", "apps/web/package.json:build"])
        #expect(tasks[1].directory == "apps/web")
        #expect(tasks[1].command == "pnpm run dev")
    }

    @Test func pnpmWorkspaceFileListsPatterns() {
        let yaml = """
        packages:
          - 'apps/*'
          - "packages/*"
        catalog:
          react: ^19
        """
        #expect(ProjectTasks.workspacePatterns(packageJSON: nil, pnpmWorkspace: yaml) == ["apps/*", "packages/*"])
        #expect(ProjectTasks.workspacePatterns(packageJSON: #"{"workspaces": {"packages": ["libs/*"]}}"#, pnpmWorkspace: nil) == ["libs/*"])
    }

    @Test @MainActor func taskErrorsAThatServerAlsoReportsShowOnce() {
        let at = SourceRange(start: SourcePosition(line: 2, character: 0), end: SourcePosition(line: 2, character: 3))
        let server = Diagnostic(range: at, severity: .error, message: "Cannot find name 'x'.", source: "ts")
        let same = Diagnostic(range: SourceRange(start: at.start, end: at.start), severity: .error, message: "Cannot find name 'x'.", source: "TS2304")
        let other = Diagnostic(range: SourceRange(start: at.start, end: at.start), severity: .error, message: "Another", source: "TS1")
        #expect(LanguageManager.adding([same, other], to: [server]) == [server, other])
    }
}

@Suite struct SelectionFormattingTests {
    @Test func onlyChangesTouchingTheLinesAreKept() {
        let old = "a = 1\nb=2\nc=3\nd=4"
        let new = "a = 1\nb = 2\nc = 3\nd = 4"
        #expect(LineDiff.changes(from: old, to: new, within: 1...1) == "a = 1\nb = 2\nc=3\nd=4")
        #expect(LineDiff.changes(from: old, to: new, within: 0...3) == new)
        // A line the formatter added right below the selection counts; one far away doesn't.
        #expect(LineDiff.changes(from: "x\ny\nz", to: "x\ny\n\nz", within: 1...1) == "x\ny\n\nz")
        #expect(LineDiff.changes(from: "x\ny\nz", to: "x\ny\nz\n", within: 0...0) == "x\ny\nz")
    }

    @Test func theEditCoversOnlyWhatDiffers() {
        for (old, new) in [("abc\ndef\nghi", "abc\nDEF\nghi"), ("one", "one\ntwo"), ("a\nb\n", "a\n"), ("😀 x", "😀 y"), ("x 😀", "x 😃"), ("", "new")] {
            let edit = LanguageManager.replacement(of: old, with: new)
            #expect(SourceEdit.apply([edit], to: old) == new)
        }
        let edit = LanguageManager.replacement(of: "abc\ndef\nghi", with: "abc\nDEF\nghi")
        #expect(edit.range.start.line == 1 && edit.range.end.line == 1)
    }

    @Test @MainActor func selectionLinesSpanEverySelection() {
        let text = "one\ntwo\nthree\nfour" as NSString
        #expect(CodeEditor.Coordinator.lines(of: [], in: text) == nil)
        #expect(CodeEditor.Coordinator.lines(of: [NSRange(location: 5, length: 2), NSRange(location: 15, length: 1)], in: text) == 1...3)
        // Selected through the newline: the next line isn't part of it.
        #expect(CodeEditor.Coordinator.lines(of: [NSRange(location: 0, length: 8)], in: text) == 0...1)
    }

    @Test func largeFilesAreRecognized() {
        #expect(LargeFile.check("let x = 1\n") == nil)
        #expect(LargeFile.check(String(repeating: "x", count: 30_000)) == .longLine(30_000))
        #expect(LargeFile.check(String(repeating: "\n", count: 60_000)) == .lines(60_001))
        #expect(LargeFile.check(String(repeating: "abcdefgh\n", count: 300_000)) == .size(2_700_000))
        #expect(LargeFile.longLine(30_000).wantsWrapping)
    }
}
