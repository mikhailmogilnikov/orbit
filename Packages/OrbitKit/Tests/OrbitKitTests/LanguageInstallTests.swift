import Foundation
@testable import OrbitACP
@testable import OrbitAPI
@testable import OrbitLanguages
import Testing

/// Reading Mason's registry entries (D57).
@Suite struct LanguageInstallerTests {
    @Test func readsPackageURLs() throws {
        let npm = try #require(PackageURL("pkg:npm/%40vtsls/language-server@0.3.0"))
        #expect(npm.type == "npm")
        #expect(npm.fullName == "@vtsls/language-server")
        #expect(npm.version == "0.3.0")
        let go = try #require(PackageURL("pkg:golang/golang.org/x/tools/gopls@v0.23.0"))
        #expect(go.fullName == "golang.org/x/tools/gopls")
        #expect(go.name == "gopls")
        let github = try #require(PackageURL("pkg:github/rust-lang/rust-analyzer@2026-10-12?foo=bar"))
        #expect(github.fullName == "rust-lang/rust-analyzer")
        #expect(github.version == "2026-10-12")
        #expect(PackageURL("npm/x@1") == nil)
    }

    @Test func rendersTemplates() {
        let context: [String: JSONValue] = [
            "version": "v1.2.3",
            "source": ["asset": ["file": "tool-{{version}}.zip", "bin": ["lsp": "bin/lsp-{{ version | strip_prefix \"v\" }}"]]],
        ]
        #expect(LanguageInstaller.render("{{ version | strip_prefix \"v\" }}", context) == "1.2.3")
        #expect(LanguageInstaller.render("{{source.asset.file}}", context) == "tool-v1.2.3.zip")
        #expect(LanguageInstaller.render("{{source.asset.bin.lsp}}", context) == "bin/lsp-1.2.3")
        #expect(LanguageInstaller.render("no templates", context) == "no templates")
    }

    @Test func picksTheBuildForThisMachine() throws {
        let assets: JSONValue = [
            ["target": ["darwin_x64", "darwin_arm64"], "file": "mac.zip"],
            ["target": "linux_x64_gnu", "file": "linux.zip"],
            ["target": "unix", "file": "any.zip"],
        ]
        #expect(LanguageInstaller.pick(assets, for: ["darwin_arm64", "darwin", "unix"])?["file"]?.string == "mac.zip")
        #expect(LanguageInstaller.pick(assets, for: ["linux_arm64_gnu", "linux_arm64", "linux", "unix"])?["file"]?.string == "any.zip")
        #expect(LanguageInstaller.pick(assets, for: ["win_x64"]) == nil)
        #expect(LanguageInstaller.split("server.tar.gz:libexec/") == ("server.tar.gz", "libexec/"))
        #expect(LanguageInstaller.split("server.zip") == ("server.zip", ""))
    }

    @Test func everyInstallableServerIsInTheRegistryShape() throws {
        let ids = LanguageServerConfig.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for config in LanguageServerConfig.all {
            #expect(!config.languages.isEmpty || !config.fileNames.isEmpty)
        }
    }
}

/// Every server Orbit can install, installed from the real registry and run
/// on a file with a problem (D57). Downloads a lot the first time (cached in
/// the temp folder), so it runs when `ORBIT_INSTALL_TESTS=1`: in cloud
/// sessions before pushing, or `make test-language-installs`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ORBIT_INSTALL_TESTS"] == "1"), .timeLimit(.minutes(20)))
struct LanguageInstallIntegrationTests {
    static let installer = LanguageInstaller(root: FileManager.default.temporaryDirectory.appendingPathComponent("orbit-lsp-installs"))

    @Test(arguments: SmokeCase.all)
    func installsAndRuns(_ smoke: SmokeCase) async throws {
        let config = try #require(LanguageServerConfig.config(id: smoke.id))
        let install = try #require(config.install)
        let environment = ProcessInfo.processInfo.environment
        if let needs = smoke.needsTool, Shell.which(needs, in: environment) == nil {
            print("skipping \(smoke.id): no \(needs)")
            return
        }
        if Self.installer.receipt(for: install.package) == nil {
            let installer = Self.installer
            try await Task.detached {
                let registry = try installer.registry()
                guard let package = registry[install.package] else {
                    throw LanguageInstaller.Failure.failed("\(install.package) isn't in the registry")
                }
                try installer.install(package, environment: environment)
            }.value
        }
        #expect(Self.installer.command(package: install.package, binary: install.binary, arguments: [], environment: environment) != nil)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-smoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for (path, contents) in smoke.files {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }
        let server = LanguageServer(config: config, root: root, installer: Self.installer)
        let started = await server.start(environment: Task { environment })
        try #require(started, "\(smoke.id) didn't start: \(server.state)")
        defer { server.shutdown() }

        let main = root.appendingPathComponent(smoke.main)
        let text = try #require(smoke.files[smoke.main])
        server.sync(main, text: text)

        if let expected = smoke.problem {
            let deadline = ContinuousClock.now + .seconds(90)
            var problems: [Diagnostic] = []
            while ContinuousClock.now < deadline {
                problems = server.diagnostics[main.standardizedFileURL] ?? []
                if problems.contains(where: { $0.message.localizedCaseInsensitiveContains(expected) }) { break }
                try await Task.sleep(for: .milliseconds(200))
            }
            #expect(problems.contains { $0.message.localizedCaseInsensitiveContains(expected) }, "\(smoke.id): \(problems.map(\.message))")
        }
        if let (needle, label) = smoke.completion {
            let string = text as NSString
            let range = string.range(of: needle)
            let position = SourcePosition(offset: range.location + range.length, in: SourcePosition.lineStarts(of: string))
            var list: CompletionList?
            for _ in 0..<20 {
                list = await server.completions(at: position, in: main, trigger: .invoked)
                if list?.items.contains(where: { $0.filterText.hasPrefix(label) }) == true { break }
                try await Task.sleep(for: .milliseconds(500))
            }
            #expect(list?.items.contains { $0.filterText.hasPrefix(label) } == true, "\(smoke.id): \(list?.items.prefix(10).map(\.label) ?? [])")
        }

        // Navigation (D62): the outline, highlights of a symbol's uses, references and symbols across files.
        if !smoke.outline.isEmpty {
            let outline = try #require(await server.symbols(in: main), "\(smoke.id): no outline")
            let names = outline.map(\.name)
            #expect(smoke.outline.allSatisfy(names.contains), "\(smoke.id): \(names)")
            if let (child, parent) = smoke.nested {
                let parentIndex = try #require(outline.firstIndex { $0.name == parent }, "\(smoke.id): \(names)")
                let childSymbol = outline[(parentIndex + 1)...].first { $0.name == child }
                #expect(childSymbol?.depth == outline[parentIndex].depth + 1, "\(smoke.id): \(outline.map { "\($0.name)/\($0.depth)" })")
            }
        }
        if let word = smoke.highlight {
            let at = try #require(Self.position(of: word, in: text, inside: true))
            let highlights = await server.highlights(at: at, in: main)
            #expect(highlights.count >= 2, "\(smoke.id): \(highlights)")
        }
        if let cross = smoke.crossFile {
            let other = root.appendingPathComponent(cross.file).standardizedFileURL
            let otherText = try #require(smoke.files[cross.file])
            let declaration = try #require(Self.position(of: cross.declaration, in: otherText))
            let use = try #require(Self.position(of: cross.use, in: text, inside: true))
            // Servers load the project (Cargo, the Go module) before they can answer.
            var references: [OrbitAPI.SourceLocation] = []
            var symbols: [LanguageSymbol] = []
            let deadline = ContinuousClock.now + .seconds(120)
            while ContinuousClock.now < deadline {
                references = await server.references(at: use, in: main)
                symbols = await server.projectSymbols(matching: cross.symbol)
                if references.contains(where: { $0.url.path == other.path }), symbols.contains(where: { $0.name == cross.symbol }) { break }
                try await Task.sleep(for: .milliseconds(500))
            }
            #expect(references.contains { $0.url.path == other.path && $0.range.start.line == declaration.line }, "\(smoke.id): \(references)")
            #expect(references.contains { $0.url.path == main.standardizedFileURL.path && $0.range.start.line == use.line }, "\(smoke.id): \(references)")
            #expect(symbols.contains { $0.name == cross.symbol && $0.location.url.path == other.path }, "\(smoke.id): \(symbols.map(\.name))")
        }
    }

    static func position(of needle: String, in text: String, inside: Bool = false) -> SourcePosition? {
        let string = text as NSString
        let range = string.range(of: needle)
        guard range.location != NSNotFound else { return nil }
        return SourcePosition(offset: range.location + (inside ? 1 : 0), in: SourcePosition.lineStarts(of: string))
    }
}

extension LanguageInstallIntegrationTests {
    /// ESLint and Tailwind beside TypeScript (D64): found only where the project
    /// uses them, configured like VS Code, answering with the project's own tools.
    @Test func companionsRunWithTheProjectsTools() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard Shell.which("npm", in: environment) != nil else { return }
        let root = try LanguageInstallFormatterTests.project("companions", [
            "package.json": #"{ "type": "module", "devDependencies": { "eslint": "9", "tailwindcss": "4" } }"#,
            "eslint.config.js": #"export default [{ rules: { "prefer-const": "error" } }];"#,
            "src/app.css": "@import \"tailwindcss\";\n",
            "src/main.js": "let count = 1;\nconsole.log(count);\n",
            "src/page.html": "<link rel=\"stylesheet\" href=\"app.css\">\n<div class=\"fle\"></div>\n<p class=\"flex\"></p>\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("node_modules"),
            withDestinationURL: try LanguageCase.installedPackages(["eslint@9", "tailwindcss@4"])
        )
        let main = root.appendingPathComponent("src/main.js"), page = root.appendingPathComponent("src/page.html")
        #expect(LanguageServerConfig.eslint.isUsed(by: main, in: root))
        #expect(LanguageServerConfig.tailwind.isUsed(by: page, in: root))
        #expect(!LanguageServerConfig.eslint.isUsed(by: main, in: root.appendingPathComponent("src")))

        for config in [LanguageServerConfig.eslint, .tailwind] {
            let install = try #require(config.install)
            if Self.installer.receipt(for: install.package) == nil {
                let installer = Self.installer
                try await Task.detached {
                    let registry = try installer.registry()
                    try installer.install(try #require(registry[install.package]), environment: environment)
                }.value
            }
        }

        // ESLint: the project's rule, and its fix as a code action.
        let eslint = LanguageServer(config: .eslint, root: root, installer: Self.installer)
        try #require(await eslint.start(environment: Task { environment }), "\(eslint.state)")
        defer { eslint.shutdown() }
        let script = try String(contentsOf: main, encoding: .utf8)
        eslint.sync(main, text: script)
        var problem: Diagnostic?
        let deadline = ContinuousClock.now + .seconds(60)
        while problem == nil, ContinuousClock.now < deadline {
            problem = eslint.diagnostics[main.standardizedFileURL]?.first { $0.message.contains("prefer-const") || $0.message.contains("never reassigned") }
            if problem == nil { try await Task.sleep(for: .milliseconds(200)) }
        }
        let found = try #require(problem, "\(eslint.diagnostics)")
        #expect(found.source == "eslint")
        let actions = await eslint.codeActions(for: found.range, in: main)
        let fix = try #require(actions.first { $0.title.contains("prefer-const") && $0.title.lowercased().contains("fix") }, "\(actions.map(\.title))")
        var fixed = script
        // ESLint's fixes are commands that send the edit back (`workspace/applyEdit`).
        let apply: (WorkspaceEdit) -> Bool = { edit in
            fixed = SourceEdit.apply(edit.files[main.standardizedFileURL] ?? [], to: fixed)
            return true
        }
        eslint.onApplyEdit = { apply($0) }
        let applied = await eslint.perform(fix, apply: apply)
        #expect(applied && fixed.hasPrefix("const count"), "\(fixed)")

        // Tailwind: class completion and the CSS behind a class.
        let tailwind = LanguageServer(config: .tailwind, root: root, installer: Self.installer)
        try #require(await tailwind.start(environment: Task { environment }), "\(tailwind.state)")
        defer { tailwind.shutdown() }
        let html = try String(contentsOf: page, encoding: .utf8)
        tailwind.sync(page, text: html)
        let afterFle = try #require(LanguageServerIntegrationTests.position(of: "fle\"", in: html)).advanced(by: 3)
        var classes: [String] = []
        for _ in 0..<60 where !classes.contains("flex") {
            classes = (await tailwind.completions(at: afterFle, in: page, trigger: .invoked))?.items.map(\.label) ?? []
            if !classes.contains("flex") { try await Task.sleep(for: .milliseconds(500)) }
        }
        #expect(classes.contains("flex"), "\(classes.prefix(20))")
        let onFlex = try #require(LanguageServerIntegrationTests.position(of: "\"flex", in: html, inside: true))
        let hover = await tailwind.hover(at: onFlex, in: page)
        #expect(hover?.markdown.contains("display: flex") == true, "\(hover?.markdown ?? "no hover")")
    }
}

/// A tiny project per server, with something wrong in it.
struct SmokeCase: Sendable, CustomTestStringConvertible {
    var id: String
    var files: [String: String]
    var main: String
    /// Part of a diagnostic the server must report.
    var problem: String?
    /// Completing right after `needle` offers `label`.
    var completion: (needle: String, label: String)?
    /// A tool the server can't work without.
    var needsTool: String?
    /// Names the file's outline must list.
    var outline: [String] = []
    /// A symbol listed right under its parent in the outline.
    var nested: (child: String, parent: String)?
    /// The word's first occurrence highlights at least one more use.
    var highlight: String?
    /// Find References on `use` (in the main file) reaches `declaration` in
    /// `file`, and the project's symbols list `symbol` from there.
    var crossFile: (file: String, use: String, declaration: String, symbol: String)?

    var testDescription: String { id }

    static let all: [SmokeCase] = [
        SmokeCase(
            id: "basedpyright",
            files: [
                "main.py": "from greeter import Greeter\n\ndef greet(name: str) -> str:\n    return name\n\ncount: int = greet(\"a\")\nGreeter().hello()\ngreet(\"a\").up\n",
                "greeter.py": "class Greeter:\n    def hello(self) -> str:\n        return \"hi\"\n",
            ],
            main: "main.py", problem: "not assignable", completion: ("greet(\"a\").up", "upper"), needsTool: "python3",
            outline: ["greet", "count"], nested: ("name", "greet"), highlight: "greet(",
            crossFile: ("greeter.py", ".hello", "def hello", "Greeter")
        ),
        SmokeCase(
            id: "rust-analyzer",
            files: [
                "Cargo.toml": "[package]\nname = \"smoke\"\nversion = \"0.1.0\"\nedition = \"2021\"\n",
                "src/main.rs": "mod greeter;\n\nfn main() {\n    let count: i32 = \"a\";\n    greeter::Greeter.hello();\n    let text = String::new();\n    text.le\n}\n",
                "src/greeter.rs": "pub struct Greeter;\n\nimpl Greeter {\n    pub fn hello(&self) -> &str {\n        \"hi\"\n    }\n}\n",
            ],
            main: "src/main.rs", problem: "mismatched types", completion: ("text.le", "len"), needsTool: "cargo",
            outline: ["main"], highlight: "text",
            crossFile: ("src/greeter.rs", ".hello", "pub fn hello", "Greeter")
        ),
        SmokeCase(
            id: "gopls",
            files: [
                "go.mod": "module smoke\n\ngo 1.21\n",
                "main.go": "package main\n\nimport \"strings\"\n\nfunc main() {\n\tvar count int = \"a\"\n\t_ = count\n\tGreeter{}.Hello()\n\tstrings.Rep\n}\n",
                "greeter.go": "package main\n\ntype Greeter struct{}\n\nfunc (Greeter) Hello() string { return \"hi\" }\n",
            ],
            main: "main.go", problem: "cannot use", completion: ("strings.Rep", "Repeat"), needsTool: "go",
            outline: ["main"], highlight: "count",
            crossFile: ("greeter.go", ".Hello", "func (Greeter) Hello", "Greeter")
        ),
        SmokeCase(id: "clangd", files: ["main.c": "int main(void) {\n    int count = undefined_name;\n    return count;\n}\n"], main: "main.c", problem: "undeclared",
                  outline: ["main"], highlight: "count"),
        SmokeCase(id: "json-lsp", files: ["data.json": "{\n  \"a\": 1\n  \"b\": 2\n}\n"], main: "data.json", problem: "expected", needsTool: "npm",
                  outline: ["a", "b"]),
        SmokeCase(id: "css-lsp", files: ["style.css": ".a {\n  color: ;\n}\n.b { dis }\n"], main: "style.css", problem: "expected", completion: (".b { dis", "display"), needsTool: "npm",
                  outline: [".a", ".b"]),
        SmokeCase(id: "html-lsp", files: ["index.html": "<!DOCTYPE html>\n<html>\n<body>\n<sec\n</body>\n</html>\n"], main: "index.html", completion: ("<sec", "section"), needsTool: "npm",
                  outline: ["html", "body"], nested: ("body", "html")),
        SmokeCase(id: "yaml-language-server", files: ["config.yaml": "key: [1, 2\nother: value\n"], main: "config.yaml", problem: "Flow sequence", needsTool: "npm",
                  outline: ["key", "other"]),
        SmokeCase(id: "bash-language-server", files: ["run.sh": "#!/bin/bash\ngreet() { echo hi; }\ngre\ngreet\n"], main: "run.sh", completion: ("\ngre", "greet"), needsTool: "npm",
                  outline: ["greet"], highlight: "greet"),
        SmokeCase(id: "marksman", files: ["notes.md": "# Title\n\nSee [the docs][nowhere].\n"], main: "notes.md", problem: "non-existent",
                  outline: ["Title"]),
        SmokeCase(id: "taplo", files: ["config.toml": "[package]\nname = \n"], main: "config.toml", problem: "expected value",
                  outline: ["package"]),
        SmokeCase(id: "lua-language-server", files: ["main.lua": "local count = 1\nprint(undefined_thing)\nprint(count)\n"], main: "main.lua", problem: "undefined",
                  outline: ["count"], highlight: "count"),
        SmokeCase(id: "dockerfile-language-server", files: ["Dockerfile": "FROM\nRUN echo hi\n"], main: "Dockerfile", problem: "no arguments", needsTool: "npm",
                  outline: ["FROM", "RUN"]),
        SmokeCase(id: "intelephense", files: ["index.php": "<?php\n$count = 1;\nundefined_function();\necho $count;\n"], main: "index.php", problem: "undefined", needsTool: "npm",
                  outline: ["$count"], highlight: "$count"),
        SmokeCase(id: "zls", files: ["main.zig": "const std = @import(\"std\");\nconst x = ;\n"], main: "main.zig", problem: "expected expression",
                  outline: ["std"]),
        SmokeCase(id: "svelte-language-server", files: ["App.svelte": "<script>\n  let count = 0;\n</script>\n\n{#if count}\n"], main: "App.svelte", problem: "left open", needsTool: "npm",
                  outline: ["count"], nested: ("count", "script")),
        SmokeCase(id: "terraform-ls", files: ["main.tf": "resource \"null_resource\" \"a\" {\n"], main: "main.tf", problem: "Unclosed",
                  outline: ["resource \"null_resource\" \"a\""]),
        // One of the servers imported from nvim-lspconfig (D65).
        SmokeCase(id: "prismals", files: ["schema.prisma": "model User {\n  id   Int    @id\n  name Strin\n}\n"],
                  main: "schema.prisma", problem: "Strin", needsTool: "npm"),
        // A project without TypeScript of its own (D65: no npx): Orbit's typescript-language-server and its bundled TypeScript.
        SmokeCase(id: "typescript", files: ["main.ts": "function greet(name: string) { return name; }\nconst count: number = greet(\"a\");\nconsole.log(count);\n"],
                  main: "main.ts", problem: "not assignable", needsTool: "npm", outline: ["greet"]),
    ]
}

/// The repo's real Prettier, installed from npm, formats through Orbit (D60).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ORBIT_INSTALL_TESTS"] == "1"), .timeLimit(.minutes(5)))
struct LanguageInstallFormatterTests {
    @Test func formatsWithTheReposPrettier() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let npm = Shell.which("npm", in: environment) else {
            print("skipping: no npm")
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-prettier-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try #"{"name": "smoke", "private": true}"#.write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try #"{"tabWidth": 3, "semi": false}"#.write(to: root.appendingPathComponent(".prettierrc"), atomically: true, encoding: .utf8)
        try LanguageInstaller.run(npm, ["install", "--prefix", root.path, "--no-audit", "--no-fund", "--silent", "prettier@3"], environment: environment)

        let file = root.appendingPathComponent("src/index.ts")
        let formatter = try #require(ProjectFormatter.detected(for: file, root: root, environment: environment))
        #expect(formatter.name == "Prettier")
        let formatted = try await formatter.format("export function a(){\nreturn 1;\n}\n", file: file, environment: environment)
        #expect(formatted == "export function a() {\n   return 1\n}\n")

        await #expect(throws: (any Error).self) {
            try await formatter.format("export function (", file: file, environment: environment)
        }
    }

    /// A project folder with `files`, removed afterwards by the caller.
    static func project(_ name: String, _ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-\(name)-\(UUID().uuidString)")
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Picks the formatter for `file` as Orbit would and runs it.
    static func format(_ text: String, _ file: String, in root: URL, environment: [String: String], expecting name: String) async throws -> String {
        let url = root.appendingPathComponent(file)
        guard case .tool(let formatter) = try ProjectFormatter.choice(for: url, root: root, environment: environment, home: root) else {
            Issue.record("no formatter for \(file)")
            return ""
        }
        #expect(formatter.name == name)
        return try await formatter.format(text, file: url, environment: environment)
    }

    @Test(arguments: ["eslint@9", "oxfmt", "deno"])
    func formatsWithNodeTools(_ package: String) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let npm = Shell.which("npm", in: environment) else { return }
        let config: [String: String] = switch package {
        case "oxfmt": [".oxfmtrc.json": #"{"semi": false, "tabWidth": 4}"#]
        case "deno": ["deno.json": #"{"fmt": {"semiColons": false}}"#]
        default: ["eslint.config.mjs": #"export default [{ rules: { semi: ["error", "never"], "prefer-const": "error" } }];"#]
        }
        let root = try Self.project("node-formatter", config.merging(["package.json": #"{"name": "smoke", "private": true}"#]) { a, _ in a })
        defer { try? FileManager.default.removeItem(at: root) }
        try LanguageInstaller.run(npm, ["install", "--prefix", root.path, "--no-audit", "--no-fund", "--silent", package], environment: environment)

        switch package {
        case "oxfmt":
            let formatted = try await Self.format("function f(){return 1}\n", "src/a.ts", in: root, environment: environment, expecting: "oxfmt")
            #expect(formatted == "function f() {\n    return 1\n}\n")
        case "deno":
            let formatted = try await Self.format("const a = {b:1};\n", "src/a.ts", in: root, environment: environment, expecting: "Deno")
            #expect(formatted == "const a = { b: 1 }\n")
            let markdown = try await Self.format("# Title\n\n* one\n* two\n", "README.md", in: root, environment: environment, expecting: "Deno")
            #expect(markdown == "# Title\n\n- one\n- two\n")
        default:
            let formatted = try await Self.format("let a = 1;\nconsole.log(a);\n", "src/a.js", in: root, environment: environment, expecting: "ESLint")
            #expect(formatted == "const a = 1\nconsole.log(a)\n")
            await #expect(throws: (any Error).self) {
                try await Self.format("let a = ;\n", "src/a.js", in: root, environment: environment, expecting: "ESLint")
            }
        }
    }

    @Test func formatsShellWithShfmt() async throws {
        var environment = ProcessInfo.processInfo.environment
        guard let go = Shell.which("go", in: environment) else { return }
        let root = try Self.project("shfmt", [".editorconfig": "[*.sh]\nindent_style = space\nindent_size = 2\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent(".tools")
        var install = environment
        install["GOBIN"] = bin.path
        try LanguageInstaller.run(go, ["install", "mvdan.cc/sh/v3/cmd/shfmt@latest"], environment: install)
        environment["PATH"] = bin.path + ":" + (environment["PATH"] ?? "")
        let formatted = try await Self.format("if true;then\necho hi\nfi\n", "run.sh", in: root, environment: environment, expecting: "shfmt")
        #expect(formatted == "if true; then\n  echo hi\nfi\n")
    }

    @Test(arguments: ["rubocop", "standard"])
    func formatsRuby(_ gem: String) async throws {
        var environment = ProcessInfo.processInfo.environment
        guard let gemTool = Shell.which("gem", in: environment) else { return }
        let config = gem == "standard" ? [".standard.yml": "parallel: false\n"] : [".rubocop.yml": "AllCops:\n  NewCops: enable\n  SuggestExtensions: false\n"]
        let root = try Self.project("ruby", config)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent(".gems")
        environment["GEM_HOME"] = home.path
        environment["GEM_PATH"] = home.path
        try LanguageInstaller.run(gemTool, ["install", "--no-document", "--install-dir", home.path, gem], environment: environment)
        environment["PATH"] = home.appendingPathComponent("bin").path + ":" + (environment["PATH"] ?? "")

        let name = gem == "standard" ? "Standard Ruby" : "RuboCop"
        let formatted = try await Self.format("x = {:a=>1}\nputs   x\n", "lib/a.rb", in: root, environment: environment, expecting: name)
        #expect(formatted == (gem == "standard" ? "x = {a: 1}\nputs x\n" : "x = { a: 1 }\nputs x\n"))
        await #expect(throws: (any Error).self) {
            try await Self.format("x = (\n", "lib/a.rb", in: root, environment: environment, expecting: name)
        }
    }

    @Test(arguments: ["laravel/pint", "friendsofphp/php-cs-fixer"])
    func formatsPHP(_ package: String) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let composer = Shell.which("composer", in: environment) else { return }
        var files = ["composer.json": #"{"name": "smoke/smoke"}"#]
        if package.hasSuffix("php-cs-fixer") {
            files[".php-cs-fixer.dist.php"] = "<?php\nreturn (new PhpCsFixer\\Config())->setRules(['@PSR12' => true]);\n"
        }
        let root = try Self.project("php", files)
        defer { try? FileManager.default.removeItem(at: root) }
        try LanguageInstaller.run(composer, ["require", "--dev", "--quiet", "--no-interaction", "--working-dir", root.path, package], environment: environment)

        let name = package == "laravel/pint" ? "Pint" : "PHP CS Fixer"
        let formatted = try await Self.format("<?php\nif($a){echo 1;}\n", "src/a.php", in: root, environment: environment, expecting: name)
        #expect(formatted == "<?php\n\nif ($a) {\n    echo 1;\n}\n")
    }

    @Test func formatsWithTheReposRuff() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let python = Shell.which("python3", in: environment) else {
            print("skipping: no python3")
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-ruff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "[project]\nname = \"smoke\"\n\n[tool.ruff.format]\nquote-style = \"single\"\n".write(to: root.appendingPathComponent("pyproject.toml"), atomically: true, encoding: .utf8)
        try LanguageInstaller.run(python, ["-m", "venv", root.appendingPathComponent(".venv").path], environment: environment)
        try LanguageInstaller.run(root.appendingPathComponent(".venv/bin/pip").path, ["install", "--quiet", "ruff"], environment: environment)

        let file = root.appendingPathComponent("main.py")
        guard case .tool(let formatter) = try ProjectFormatter.choice(for: file, root: root, environment: environment) else {
            Issue.record("Ruff wasn't picked")
            return
        }
        #expect(formatter.name == "Ruff")
        let formatted = try await formatter.format("x = {  \"a\":1 }\n", file: file, environment: environment)
        #expect(formatted == "x = {'a': 1}\n")
    }
}
