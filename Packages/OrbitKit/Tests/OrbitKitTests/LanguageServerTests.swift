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
        let root = try Self.scratch("formatter")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("apps/web")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Self.tool(root.appendingPathComponent("node_modules/.bin/prettier"))
        try Self.tool(root.appendingPathComponent("node_modules/.bin/biome"))
        let file = app.appendingPathComponent("src/index.ts")
        let none: [String: String] = ["PATH": "/nonexistent"]
        // Installed but not configured: the server formats.
        #expect(try ProjectFormatter.choice(for: file, root: root, environment: none, home: root) == .server)

        try #"{"name": "web", "prettier": {"semi": false}}"#.write(to: app.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        let prettier = try #require(ProjectFormatter.detected(for: file, root: root, environment: none))
        #expect(prettier.name == "Prettier")
        #expect(prettier.source == "apps/web/package.json")
        #expect(prettier.directory.path == app.standardizedFileURL.path)
        #expect(ProjectFormatter.detected(for: app.appendingPathComponent("src/main.swift"), root: root, environment: none) == nil)

        try "{}".write(to: app.appendingPathComponent("biome.json"), atomically: true, encoding: .utf8)
        #expect(ProjectFormatter.detected(for: file, root: root, environment: none)?.name == "Biome")
        // Biome doesn't do Markdown; Prettier still does.
        #expect(ProjectFormatter.detected(for: app.appendingPathComponent("README.md"), root: root, environment: none)?.name == "Prettier")
    }

    @Test func findsPythonFormattersInTheVirtualEnvironment() throws {
        let root = try Self.scratch("python")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.tool(root.appendingPathComponent(".venv/bin/ruff"))
        try Self.tool(root.appendingPathComponent(".venv/bin/black"))
        let file = root.appendingPathComponent("pkg/main.py")
        let none: [String: String] = ["PATH": "/nonexistent"]
        try "[project]\nname = \"x\"\n\n[tool.black]\nline-length = 100\n".write(to: root.appendingPathComponent("pyproject.toml"), atomically: true, encoding: .utf8)
        #expect(ProjectFormatter.detected(for: file, root: root, environment: none)?.name == "Black")
        try "[project]\nname = \"x\"\n\n[tool.ruff.format]\nquote-style = \"single\"\n".write(to: root.appendingPathComponent("pyproject.toml"), atomically: true, encoding: .utf8)
        let ruff = try #require(ProjectFormatter.detected(for: file, root: root, environment: none))
        #expect(ruff.name == "Ruff")
        #expect(ruff.executable.hasSuffix(".venv/bin/ruff"))
        #expect(ruff.source == "pyproject.toml")
    }

    @Test func settingsOverrideDetection() throws {
        let root = try Self.scratch("settings")
        let home = try Self.scratch("home")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: home)
        }
        try Self.tool(root.appendingPathComponent("node_modules/.bin/prettier"))
        try Self.tool(root.appendingPathComponent("tools/fmt"))
        try "{}".write(to: root.appendingPathComponent(".prettierrc"), atomically: true, encoding: .utf8)
        let none: [String: String] = ["PATH": "/nonexistent"]
        let ts = root.appendingPathComponent("a.ts"), md = root.appendingPathComponent("b.md"), sh = root.appendingPathComponent("c.sh")

        try FileManager.default.createDirectory(at: home.appendingPathComponent(".orbit"), withIntermediateDirectories: true)
        try #"{"formatters": {"md": "off", "sh": {"command": "tools/fmt", "arguments": ["{file}"]}}}"#
            .write(to: FormatterSettings.userFile(home: home), atomically: true, encoding: .utf8)
        #expect(try ProjectFormatter.choice(for: md, root: root, environment: none, home: home) == .off(source: "~/.orbit/settings.json"))
        guard case .tool(let custom) = try ProjectFormatter.choice(for: sh, root: root, environment: none, home: home) else {
            Issue.record("no custom formatter")
            return
        }
        #expect(custom.executable == root.appendingPathComponent("tools/fmt").standardizedFileURL.path)
        #expect(custom.source == "~/.orbit/settings.json")

        // The project's settings win over the user's.
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".orbit"), withIntermediateDirectories: true)
        try #"{"formatters": {".ts, md": "server"}}"#.write(to: FormatterSettings.projectFile(root: root), atomically: true, encoding: .utf8)
        #expect(try ProjectFormatter.choice(for: ts, root: root, environment: none, home: home) == .server)
        #expect(try ProjectFormatter.choice(for: md, root: root, environment: none, home: home) == .server)

        try #"{"formatters": {"ts": "ruff"}}"#.write(to: FormatterSettings.projectFile(root: root), atomically: true, encoding: .utf8)
        #expect(throws: FormatterSettings.Failure.self) { try ProjectFormatter.choice(for: ts, root: root, environment: none, home: home) }
        try #"{"formatters": "#.write(to: FormatterSettings.projectFile(root: root), atomically: true, encoding: .utf8)
        #expect(throws: FormatterSettings.Failure.self) { try ProjectFormatter.choice(for: ts, root: root, environment: none, home: home) }
    }

    static func scratch(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func tool(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\ncat\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

@Suite struct LanguageServerFormattingOverviewTests {
    @Test func listsWhatFormatsWhatAndWhatsMissing() throws {
        let root = try LanguageServerFormattingTests.scratch("overview")
        defer { try? FileManager.default.removeItem(at: root) }
        let web = root.appendingPathComponent("apps/web")
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try "{}".write(to: web.appendingPathComponent(".prettierrc"), atomically: true, encoding: .utf8)
        try "[tool.ruff]\n".write(to: root.appendingPathComponent("pyproject.toml"), atomically: true, encoding: .utf8)
        try LanguageServerFormattingTests.tool(root.appendingPathComponent(".venv/bin/ruff"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".orbit"), withIntermediateDirectories: true)
        try #"{"formatters": {"md": "off", "sh, bash": {"command": "shfmt", "arguments": ["-i", "2"]}}}"#
            .write(to: FormatterSettings.projectFile(root: root), atomically: true, encoding: .utf8)

        let overview = FormattingOverview(root: root, environment: ["PATH": "/nonexistent"], home: root.appendingPathComponent("nohome"))
        #expect(overview.problems.isEmpty)
        let byFormatter = Dictionary(overview.rows.map { ($0.formatter, $0) }, uniquingKeysWith: { first, _ in first })
        #expect(byFormatter["Off"]?.fileTypes == ".md")
        #expect(byFormatter["shfmt -i 2"]?.fileTypes == ".bash .sh")
        #expect(byFormatter["Ruff"]?.source == "pyproject.toml")
        #expect(byFormatter["Ruff"]?.warning == nil)
        #expect(byFormatter["Prettier"]?.source == "apps/web/.prettierrc")
        #expect(byFormatter["Prettier"]?.warning?.contains("isn't installed") == true)
    }
}
