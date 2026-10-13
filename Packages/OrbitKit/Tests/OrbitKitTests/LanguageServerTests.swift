import Foundation
@testable import OrbitACP
@testable import OrbitAPI
@testable import OrbitLanguages
import Testing

@Suite struct LanguageServerTests {
    /// D65: one TypeScript server per monorepo (its lockfile), the project's own
    /// TypeScript nearest to the file, companions by dependency, its tools first on PATH.
    @Test func launchesFromTheProject() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("orbit-ts-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        func write(_ path: String, _ text: String, executable: Bool = false) throws {
            let url = root.appendingPathComponent(path)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            if executable { try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }
        // pnpm keeps TypeScript in the package, not the root.
        try write("pnpm-lock.yaml", "")
        try write("package.json", #"{"devEngines": {"packageManager": {"name": "pnpm"}}}"#)
        try write("apps/booking/package.json", #"{"devDependencies": {"@tailwindcss/vite": "4", "typescript": "7"}}"#)
        try write("apps/booking/node_modules/typescript/package.json", #"{"version": "7.0.2"}"#)
        try write("apps/booking/node_modules/.bin/tsc", "#!/bin/sh\n", executable: true)
        try write("apps/legacy/package.json", "{}")
        try write("apps/legacy/node_modules/typescript/package.json", #"{"version": "5.9.3"}"#)
        try write("apps/legacy/node_modules/.bin/tsc", "#!/bin/sh\n", executable: true)

        let page = root.appendingPathComponent("apps/booking/src/app.tsx")
        let config = LanguageServerConfig.typescript
        #expect(config.root(for: page, in: root).path == root.standardizedFileURL.path)
        let empty = LanguageInstaller(root: root.appendingPathComponent("none"))
        let command = try #require(config.command(file: page, root: root, environment: ["PATH": "/nonexistent"], installer: empty))
        #expect(command.executable == root.appendingPathComponent("apps/booking/node_modules/.bin/tsc").path)
        #expect(command.arguments == ["--lsp", "--stdio"])
        // TypeScript 5 isn't its own server: nothing else is there to run it.
        let legacy = root.appendingPathComponent("apps/legacy/index.ts")
        #expect(config.command(file: legacy, root: root, environment: ["PATH": "/nonexistent"], installer: empty) == nil)

        #expect(LanguageServerConfig.tailwind.isUsed(by: page, in: root))
        #expect(!LanguageServerConfig.eslint.isUsed(by: page, in: root))
        #expect(!LanguageServerConfig.tailwind.isUsed(by: legacy, in: root))

        let environment = ProjectFiles.environment(for: page, root: root, base: ["PATH": "/usr/bin"])
        #expect(environment["PATH"] == root.appendingPathComponent("apps/booking/node_modules/.bin").standardizedFileURL.path + ":/usr/bin")
    }

    /// Workspace markers win over a package's own manifest; without any, the folder.
    @Test func rootsFollowMarkers() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("orbit-roots-\(UUID().uuidString)").standardizedFileURL
        defer { try? manager.removeItem(at: root) }
        for path in ["rust/Cargo.lock", "rust/Cargo.toml", "rust/crates/core/Cargo.toml", "tool/Cargo.toml", "py/.venv/pyvenv.cfg", "py/pyproject.toml"] {
            let url = root.appendingPathComponent(path)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "".write(to: url, atomically: true, encoding: .utf8)
        }
        let rust = LanguageServerConfig.rust
        #expect(rust.root(for: root.appendingPathComponent("rust/crates/core/src/lib.rs"), in: root).path == root.appendingPathComponent("rust").path)
        #expect(rust.root(for: root.appendingPathComponent("tool/src/main.rs"), in: root).path == root.appendingPathComponent("tool").path)
        #expect(rust.root(for: root.appendingPathComponent("loose.rs"), in: root).path == root.path)
        #expect(LanguageServerConfig.swift.root(for: root.appendingPathComponent("rust/a.swift"), in: root).path == root.path)

        let script = root.appendingPathComponent("py/app/main.py")
        #expect(LanguageServerConfig.python.root(for: script, in: root).path == root.appendingPathComponent("py").path)
        let environment = ProjectFiles.environment(for: script, root: root, base: ["PATH": "/usr/bin"])
        #expect(environment["VIRTUAL_ENV"] == root.appendingPathComponent("py/.venv").path)
        #expect(environment["PATH"] == root.appendingPathComponent("py/.venv/bin").path + ":/usr/bin")
    }

    /// D65: nvim-lspconfig's servers, ours replacing theirs, one ranked list per extension.
    @Test func importedServersFillInTheRest() throws {
        let imported = ImportedServers.shared
        #expect(imported.servers.count > 300)
        let ids = Set(LanguageServerConfig.all.map(\.id))
        #expect(ids.count == LanguageServerConfig.all.count)
        for (name, servers) in imported.choices.extensions.merging(imported.choices.fileNames, uniquingKeysWith: { $1 }) {
            for server in servers { #expect(imported.byName[server] != nil, "\(name): \(server)") }
        }
        func first(_ path: String) -> String? { LanguageServerConfig.config(for: URL(fileURLWithPath: path))?.id }
        // Ours win, also for files only the imported entry of the same server knew.
        #expect(first("/p/main.py") == "basedpyright")
        #expect(first("/p/Gemfile") == "ruby-lsp")
        #expect(first("/p/x.c++") == "clangd")
        #expect(LanguageServerConfig.clang.languageID(for: URL(fileURLWithPath: "/p/x.c++")) == "cpp")
        #expect(first("/p/go.mod") == "gopls")
        #expect(LanguageServerConfig.go.languageID(for: URL(fileURLWithPath: "/p/go.mod")) == "gomod")
        #expect(!ids.contains("ts_ls") && !ids.contains("rust_analyzer"))
        // The rest come ranked; tools (spell checkers, linters) never are a file's server.
        #expect(first("/p/App.kt") == "kotlin_lsp")
        #expect(first("/p/lib.ex") == "expert")
        #expect(first("/p/schema.prisma") == "prismals")
        #expect(LanguageServerConfig.config(id: "prismals")?.name == "Prisma")
        #expect(first("/p/notes.txt") == nil)
        #expect(!LanguageServerConfig.candidates(for: URL(fileURLWithPath: "/p/a.vue")).contains { $0.id == "biome" })
    }

    /// Of a language's servers, one already on the machine wins over the usual choice.
    @Test func installedServerIsChosen() throws {
        let manager = FileManager.default
        let bin = manager.temporaryDirectory.appendingPathComponent("orbit-bin-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: bin) }
        try manager.createDirectory(at: bin, withIntermediateDirectories: true)
        let file = URL(fileURLWithPath: "/p/App.kt"), root = URL(fileURLWithPath: "/p")
        let none = LanguageInstaller(root: bin.appendingPathComponent("none"))
        #expect(LanguageServerConfig.choose(for: file, in: root, environment: ["PATH": bin.path], installer: none)?.id == "kotlin_lsp")
        let other = bin.appendingPathComponent("kotlin-language-server")
        try "#!/bin/sh\n".write(to: other, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: other.path)
        #expect(LanguageServerConfig.choose(for: file, in: root, environment: ["PATH": bin.path], installer: none)?.id == "kotlin_language_server")
    }

    /// `"languageServers"` in .orbit/settings.json: another server, none, a command, settings merged over the server's.
    @Test func settingsChooseServers() throws {
        let json = #"""
        { "formatters": { "py": "ruff" },
          "languageServers": {
            "kt": "kotlin_language_server",
            "vue, .astro": "off",
            "nix": { "command": "/opt/nixd", "arguments": ["--log=error"] },
            "py": { "server": "pyright", "settings": { "python": { "analysis": { "typeCheckingMode": "strict" } } } },
            "zig": "zls_typo"
          } }
        """#
        let layer = try LanguageServerSettings.parse(Data(json.utf8), displayPath: ".orbit/settings.json")
        func resolve(_ path: String) -> LanguageServerConfig? {
            let file = URL(fileURLWithPath: path)
            return LanguageServerSettings.resolve(for: file, layers: [layer], default: LanguageServerConfig.config(for: file))
        }
        #expect(resolve("/p/App.kt")?.id == "kotlin_language_server")
        #expect(resolve("/p/App.vue") == nil && resolve("/p/Page.astro") == nil)
        #expect(resolve("/p/main.go")?.id == "gopls")
        let nix = try #require(resolve("/p/flake.nix"))
        #expect(nix.launch == [.file(path: "/opt/nixd", arguments: ["--log=error"])])
        #expect(nix.languageID(for: URL(fileURLWithPath: "/p/flake.nix")) == "nix")
        let python = try #require(resolve("/p/main.py"))
        #expect(python.id == "pyright")
        #expect(python.settings?["python"]?["analysis"]?["typeCheckingMode"]?.string == "strict")
        // A rule that can't be followed says so instead of quietly using the default.
        let typo = try #require(resolve("/p/main.zig"))
        #expect(typo.launch.isEmpty && typo.missing.contains("zls_typo"))

        #expect(throws: (any Error).self) { try LanguageServerSettings.parse(Data(#"{"languageServers": {"kt": 3}}"#.utf8), displayPath: "x") }
    }

    /// Choosing from the status bar writes the user's file and keeps the rest of it.
    @Test func choosingAServerKeepsTheSettingsFile() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".orbit"), withIntermediateDirectories: true)
        try #"{"formatters": {"md": "off"}}"#.write(to: FormatterSettings.userFile(home: home), atomically: true, encoding: .utf8)
        try LanguageServerSettings.choose("kotlin_language_server", forType: "kt", home: home)
        var layers = try LanguageServerSettings.layers(root: nil, home: home)
        #expect(layers.first?.rules["kt"] == .server("kotlin_language_server", .init()))
        #expect(try FormatterSettings.layers(root: nil, home: home).first?.rule(for: "md") == .off)
        try LanguageServerSettings.choose(nil, forType: "kt", home: home)
        layers = try LanguageServerSettings.layers(root: nil, home: home)
        #expect(layers.first?.rules.isEmpty == true)
    }

    @Test func settingsMergeObjects() {
        let base: JSONValue = ["a": ["b": 1, "c": 2], "d": [1]]
        #expect(base.merging(["a": ["c": 3], "d": [2]]) == ["a": ["b": 1, "c": 3], "d": [2]])
    }

    @Test func settingsNameTheServersRoot() {
        let root = URL(fileURLWithPath: "/work/web")
        let settings = LanguageServerConfig.eslint.settings(for: root)
        #expect(settings?["workspaceFolder"]?["uri"]?.string == "file:///work/web")
        #expect(settings?["workspaceFolder"]?["name"]?.string == "web")
    }

    /// Servers without hierarchical symbols send a flat list; nesting comes from which range holds which.
    @Test func flatSymbolsNestByRange() throws {
        func symbol(_ name: String, _ kind: Int, _ lines: ClosedRange<Int>) -> JSONValue {
            ["name": .string(name), "kind": .number(Double(kind)), "location": [
                "uri": "file:///a.ts",
                "range": ["start": ["line": .number(Double(lines.lowerBound)), "character": 0],
                          "end": ["line": .number(Double(lines.upperBound)), "character": 1]],
            ]]
        }
        let url = URL(fileURLWithPath: "/a.ts")
        let outline = LanguageServer.outline([
            symbol("helper", 12, 10...12), symbol("Greeter", 5, 0...8), symbol("greet", 6, 2...4), symbol("name", 7, 1...1),
        ], in: url)
        #expect(outline.map(\.name) == ["Greeter", "name", "greet", "helper"])
        #expect(outline.map(\.depth) == [0, 1, 1, 0])
        #expect(outline[2].kind == .method)
    }

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

    @Test func fallbacksOnlyWithoutAFormatter() throws {
        let root = try Self.scratch("fallback")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.tool(root.appendingPathComponent("node_modules/.bin/eslint"))
        try Self.tool(root.appendingPathComponent("node_modules/.bin/prettier"))
        let app = root.appendingPathComponent("apps/web")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try "export default []\n".write(to: app.appendingPathComponent("eslint.config.js"), atomically: true, encoding: .utf8)
        let file = app.appendingPathComponent("index.ts")
        let none: [String: String] = ["PATH": "/nonexistent"]
        #expect(ProjectFormatter.detected(for: file, root: root, environment: none)?.name == "ESLint")
        // Prettier further up still wins over the nearer ESLint config.
        try "{}".write(to: root.appendingPathComponent(".prettierrc"), atomically: true, encoding: .utf8)
        #expect(ProjectFormatter.detected(for: file, root: root, environment: none)?.name == "Prettier")

        // shfmt needs no config, only to be installed.
        let bin = root.appendingPathComponent("tools")
        try Self.tool(bin.appendingPathComponent("shfmt"))
        let shell = ProjectFormatter.detected(for: root.appendingPathComponent("run.sh"), root: root, environment: ["PATH": bin.path])
        #expect(shell?.name == "shfmt")
        #expect(ProjectFormatter.detected(for: root.appendingPathComponent("run.sh"), root: root, environment: none) == nil)
    }

    @Test func findsRubyAndPHPTools() throws {
        let root = try Self.scratch("ruby")
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("tools")
        try Self.tool(bin.appendingPathComponent("bundle"))
        let environment = ["PATH": bin.path]
        let file = root.appendingPathComponent("app/models/user.rb")
        try "AllCops:\n  NewCops: enable\n".write(to: root.appendingPathComponent(".rubocop.yml"), atomically: true, encoding: .utf8)
        try "GEM\n  specs:\n    rubocop (1.80.0)\n".write(to: root.appendingPathComponent("Gemfile.lock"), atomically: true, encoding: .utf8)
        let rubocop = try #require(ProjectFormatter.detected(for: file, root: root, environment: environment))
        #expect(rubocop.name == "RuboCop")
        #expect(rubocop.executable == bin.appendingPathComponent("bundle").path)
        #expect(Array(rubocop.arguments.prefix(3)) == ["exec", "rubocop", "--stdin"])
        // A binstub beats Bundler.
        try Self.tool(root.appendingPathComponent("bin/rubocop"))
        #expect(ProjectFormatter.detected(for: file, root: root, environment: environment)?.executable.hasSuffix("bin/rubocop") == true)
        // Standard's own config picks Standard.
        try Self.tool(root.appendingPathComponent("bin/standardrb"))
        try "".write(to: root.appendingPathComponent(".standard.yml"), atomically: true, encoding: .utf8)
        #expect(ProjectFormatter.detected(for: file, root: root, environment: environment)?.name == "Standard Ruby")

        try Self.tool(root.appendingPathComponent("vendor/bin/pint"))
        try #"{"require-dev": {"laravel/pint": "^1.0"}}"#.write(to: root.appendingPathComponent("composer.json"), atomically: true, encoding: .utf8)
        let pint = try #require(ProjectFormatter.detected(for: root.appendingPathComponent("src/A.php"), root: root, environment: environment))
        #expect(pint.name == "Pint")
        #expect(pint.mode == .temporaryFile)
    }

    @Test func readsESLintReports() throws {
        let fixed = #"[{"messages":[],"output":"const a = 1\n"}]"#
        #expect(try ProjectFormatter.eslintOutput(Data(fixed.utf8), original: "let a = 1;\n") == "const a = 1\n")
        let clean = #"[{"messages":[{"fatal":false,"message":"unused"}]}]"#
        #expect(try ProjectFormatter.eslintOutput(Data(clean.utf8), original: "a\n") == "a\n")
        let broken = #"[{"messages":[{"fatal":true,"line":3,"message":"Parsing error: Unexpected token ;"}]}]"#
        #expect(throws: (any Error).self) { try ProjectFormatter.eslintOutput(Data(broken.utf8), original: "") }
    }

    @Test func fixesACopyForInPlaceTools() async throws {
        let root = try Self.scratch("inplace")
        defer { try? FileManager.default.removeItem(at: root) }
        // An in-place "fixer": uppercases the file it's given.
        let fixer = root.appendingPathComponent("fix")
        try "#!/bin/sh\ntr a-z A-Z < \"$1\" > \"$1.tmp\" && mv \"$1.tmp\" \"$1\"\n".write(to: fixer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixer.path)
        let file = root.appendingPathComponent("a.php")
        try "untouched".write(to: file, atomically: true, encoding: .utf8)
        let formatter = ProjectFormatter(name: "fix", executable: fixer.path, arguments: ["{file}"], directory: root, source: "", mode: .temporaryFile)
        #expect(try await formatter.format("<?php echo 1;\n", file: file, environment: [:]) == "<?PHP ECHO 1;\n")
        #expect(try String(contentsOf: file, encoding: .utf8) == "untouched")
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
