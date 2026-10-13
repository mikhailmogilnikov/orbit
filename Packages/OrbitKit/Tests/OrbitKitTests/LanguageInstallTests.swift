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

    var testDescription: String { id }

    static let all: [SmokeCase] = [
        SmokeCase(
            id: "basedpyright", files: ["main.py": "def greet(name: str) -> str:\n    return name\n\ncount: int = greet(\"a\")\ngreet(\"a\").up\n"],
            main: "main.py", problem: "not assignable", completion: ("greet(\"a\").up", "upper"), needsTool: "python3"
        ),
        SmokeCase(
            id: "rust-analyzer",
            files: [
                "Cargo.toml": "[package]\nname = \"smoke\"\nversion = \"0.1.0\"\nedition = \"2021\"\n",
                "src/main.rs": "fn main() {\n    let count: i32 = \"a\";\n    let text = String::new();\n    text.le\n}\n",
            ],
            main: "src/main.rs", problem: "mismatched types", completion: ("text.le", "len"), needsTool: "cargo"
        ),
        SmokeCase(
            id: "gopls",
            files: ["go.mod": "module smoke\n\ngo 1.21\n", "main.go": "package main\n\nimport \"strings\"\n\nfunc main() {\n\tvar count int = \"a\"\n\t_ = count\n\tstrings.Rep\n}\n"],
            main: "main.go", problem: "cannot use", completion: ("strings.Rep", "Repeat"), needsTool: "go"
        ),
        SmokeCase(id: "clangd", files: ["main.c": "int main(void) {\n    int count = undefined_name;\n    return count;\n}\n"], main: "main.c", problem: "undeclared"),
        SmokeCase(id: "json-lsp", files: ["data.json": "{\n  \"a\": 1\n  \"b\": 2\n}\n"], main: "data.json", problem: "expected", needsTool: "npm"),
        SmokeCase(id: "css-lsp", files: ["style.css": ".a {\n  color: ;\n}\n.b { dis }\n"], main: "style.css", problem: "expected", completion: (".b { dis", "display"), needsTool: "npm"),
        SmokeCase(id: "html-lsp", files: ["index.html": "<!DOCTYPE html>\n<html>\n<body>\n<sec\n</body>\n</html>\n"], main: "index.html", completion: ("<sec", "section"), needsTool: "npm"),
        SmokeCase(id: "yaml-language-server", files: ["config.yaml": "key: [1, 2\nother: value\n"], main: "config.yaml", problem: "Flow sequence", needsTool: "npm"),
        SmokeCase(id: "bash-language-server", files: ["run.sh": "#!/bin/bash\ngreet() { echo hi; }\ngre\n"], main: "run.sh", completion: ("\ngre", "greet"), needsTool: "npm"),
        SmokeCase(id: "marksman", files: ["notes.md": "# Title\n\nSee [the docs][nowhere].\n"], main: "notes.md", problem: "non-existent"),
        SmokeCase(id: "taplo", files: ["config.toml": "[package]\nname = \n"], main: "config.toml", problem: "expected value"),
        SmokeCase(id: "lua-language-server", files: ["main.lua": "local count = 1\nprint(undefined_thing)\n"], main: "main.lua", problem: "undefined"),
        SmokeCase(id: "dockerfile-language-server", files: ["Dockerfile": "FROM\nRUN echo hi\n"], main: "Dockerfile", problem: "no arguments", needsTool: "npm"),
        SmokeCase(id: "intelephense", files: ["index.php": "<?php\n$count = 1;\nundefined_function();\n"], main: "index.php", problem: "undefined", needsTool: "npm"),
        SmokeCase(id: "zls", files: ["main.zig": "const std = @import(\"std\");\nconst x = ;\n"], main: "main.zig", problem: "expected expression"),
        SmokeCase(id: "svelte-language-server", files: ["App.svelte": "<script>\n  let count = 0;\n</script>\n\n{#if count}\n"], main: "App.svelte", problem: "left open", needsTool: "npm"),
        SmokeCase(id: "terraform-ls", files: ["main.tf": "resource \"null_resource\" \"a\" {\n"], main: "main.tf", problem: "Unclosed"),
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
