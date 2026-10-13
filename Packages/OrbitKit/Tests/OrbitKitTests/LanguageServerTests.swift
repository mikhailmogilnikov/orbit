import Foundation
@testable import OrbitACP
@testable import OrbitAPI
@testable import OrbitLanguages
import Testing

@Suite struct LanguageServerTests {
    @Test func incrementalChangeCoversOnlyTheEdit() throws {
        let change = try #require(TextChange(from: "let a = 1\nlet b = 2\n", to: "let a = 1\nlet bc = 2\n"))
        #expect(change.range == SourceRange(start: SourcePosition(line: 1, character: 5), end: SourcePosition(line: 1, character: 5)))
        #expect(change.text == "c")

        let deletion = try #require(TextChange(from: "one\ntwo\nthree", to: "one\nthree"))
        // "one\nt|wo\nt|hree": the shared "t" and "hree" stay.
        #expect(deletion.range.start == SourcePosition(line: 1, character: 1))
        #expect(deletion.range.end == SourcePosition(line: 2, character: 1))
        #expect(deletion.text == "")

        #expect(TextChange(from: "same", to: "same") == nil)
    }

    @Test func changeNeverSplitsSurrogatePairs() throws {
        // 😀 and 😃 share their lead surrogate.
        let change = try #require(TextChange(from: "a😀b", to: "a😃b"))
        #expect(change.range.start.character == 1)
        #expect(change.range.end.character == 3)
        #expect(change.text == "😃")
    }

    @Test func positionsRoundTripThroughOffsets() {
        let text = "ab\ncd\n\nef" as NSString
        let starts = SourcePosition.lineStarts(of: text)
        #expect(starts == [0, 3, 6, 7])
        let position = SourcePosition(offset: 4, in: starts)
        #expect(position == SourcePosition(line: 1, character: 1))
        #expect(position.offset(in: starts, length: text.length) == 4)
        // Past the end of a line clamps to it.
        #expect(SourcePosition(line: 0, character: 99).offset(in: starts, length: text.length) == 3)
    }

    @Test func readsServerPayloads() throws {
        let diagnostic = try #require(LanguageServer.diagnostic([
            "range": ["start": ["line": 2, "character": 4], "end": ["line": 2, "character": 9]],
            "severity": 2, "message": "Unused variable", "source": "ts",
        ]))
        #expect(diagnostic.severity == .warning)
        #expect(diagnostic.range.end.character == 9)

        #expect(LanguageServer.markdown(["kind": "markdown", "value": "**x**"]) == "**x**")
        #expect(LanguageServer.markdown([["language": "swift", "value": "let x: Int"], "doc"]) == "```swift\nlet x: Int\n```\n\ndoc")
        #expect(LanguageServer.fileURL("file:///tmp/a%20b.ts")?.path == "/tmp/a b.ts")
        #expect(LanguageServer.fileURL("sourcekit-lsp://x") == nil)
    }

    @Test func serversArePickedByExtension() {
        #expect(LanguageServerConfig.config(for: URL(fileURLWithPath: "/p/App.swift"))?.id == "sourcekit-lsp")
        #expect(LanguageServerConfig.config(for: URL(fileURLWithPath: "/p/a.tsx"))?.languageID(for: URL(fileURLWithPath: "/p/a.tsx")) == "typescriptreact")
        #expect(LanguageServerConfig.config(for: URL(fileURLWithPath: "/p/notes.txt")) == nil)
        #expect(LanguageServerConfig.config(for: URL(fileURLWithPath: "/p/Dockerfile"))?.id == "dockerfile-language-server")
    }
}

/// Formatting follows the repo: its Prettier/Biome, its `.editorconfig`, its indentation (D60).
@Suite struct LanguageServerFormattingTests {
    @Test func guessesIndentationFromSteps() {
        let jsdoc = """
        /**
         * Greets.
         * @param name who
         */
        export function greet(name: string) {
          if (name) {
            return `hi ${name}`;
          }
          return "";
        }
        """
        #expect(Indentation.guess(jsdoc) == Indentation(size: 2, spaces: true))
        #expect(Indentation.guess("func a() {\n    if b {\n        c()\n    }\n}\n") == Indentation(size: 4, spaces: true))
        #expect(Indentation.guess("func a() {\n\tb()\n\tif c {\n\t\td()\n\t}\n}\n").spaces == false)
        #expect(Indentation.guess("one\ntwo\n") == Indentation(size: 4, spaces: true))
    }

    @Test func matchesEditorConfigGlobs() {
        #expect(EditorConfig.glob("*", matches: "src/a.ts"))
        #expect(EditorConfig.glob("*.{ts,tsx}", matches: "src/app/a.tsx"))
        #expect(!EditorConfig.glob("*.{ts,tsx}", matches: "src/a.js"))
        #expect(EditorConfig.glob("src/**.ts", matches: "src/deep/a.ts"))
        #expect(!EditorConfig.glob("/lib/*.ts", matches: "src/lib/a.ts"))
        #expect(EditorConfig.glob("Makefile", matches: "tools/Makefile"))
        #expect(EditorConfig.glob("*.[ch]", matches: "a.h"))
    }

    @Test func readsEditorConfigNearestFirst() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-editorconfig-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("packages/web/src")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "root = true\n\n[*]\nindent_style = tab\nindent_size = 8\n\n[*.ts]\nindent_style = space\nindent_size = 4\n"
            .write(to: root.appendingPathComponent(".editorconfig"), atomically: true, encoding: .utf8)
        try "[src/*.ts]\nindent_size = 2\n".write(to: root.appendingPathComponent("packages/web/.editorconfig"), atomically: true, encoding: .utf8)

        let file = nested.appendingPathComponent("app.ts")
        #expect(Indentation.of(file, text: "a\n\tb\n", root: root) == Indentation(size: 2, spaces: true))
        let script = root.appendingPathComponent("run.sh")
        #expect(Indentation.of(script, text: "", root: root) == Indentation(size: 8, spaces: false))
        // No config: the file decides.
        #expect(Indentation.of(URL(fileURLWithPath: "/nowhere/a.ts"), text: "a {\n  b\n}\n", root: nil) == Indentation(size: 2, spaces: true))
    }

    @Test func findsTheRepoFormatter() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-formatter-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("apps/web")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("src"), withIntermediateDirectories: true)
        let bin = root.appendingPathComponent("node_modules/.bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["prettier", "biome"] {
            let tool = bin.appendingPathComponent(name)
            try "#!/bin/sh\n".write(to: tool, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        }
        let file = app.appendingPathComponent("src/index.ts")
        // Installed but not configured: the server formats.
        #expect(ProjectFormatter.find(for: file, root: root) == nil)

        try #"{"name": "web", "prettier": {"semi": false}}"#.write(to: app.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        let prettier = try #require(ProjectFormatter.find(for: file, root: root))
        #expect(prettier.tool == .prettier)
        #expect(prettier.directory.path == app.standardizedFileURL.path)
        #expect(ProjectFormatter.find(for: app.appendingPathComponent("src/main.swift"), root: root) == nil)

        try "{}".write(to: app.appendingPathComponent("biome.json"), atomically: true, encoding: .utf8)
        #expect(ProjectFormatter.find(for: file, root: root)?.tool == .biome)
        // Biome doesn't do Markdown; Prettier still does.
        #expect(ProjectFormatter.find(for: app.appendingPathComponent("README.md"), root: root)?.tool == .prettier)
    }
}
