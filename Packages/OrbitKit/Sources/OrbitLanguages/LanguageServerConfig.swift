import Foundation
import OrbitACP

/// A language server Orbit knows how to find and run (D54). Our own table:
/// which files it serves and how to launch it; servers that aren't on the
/// machine are installed from the Mason registry (D57).
struct LanguageServerConfig: Sendable {
    var id: String
    var name: String
    /// File extension → LSP `languageId`.
    var languages: [String: String]
    /// Files known by name (`Dockerfile`) → LSP `languageId`.
    var fileNames: [String: String] = [:]
    /// The command already on this machine for a project at `root`; nil when
    /// the server isn't there (`missing` says what to do).
    var resolve: @Sendable (_ root: URL, _ environment: [String: String]) -> AgentCommand?
    var missing: String
    /// How Orbit installs it itself.
    var install: Install?

    struct Install: Sendable, Hashable {
        /// The Mason package.
        var package: String
        var binary: String
        var arguments: [String]
        /// What it needs to install and run, if anything (shown before installing).
        var needs: String?
    }

    static let all: [LanguageServerConfig] = [
        swift, typescript, python, rust, go, clang, json, css, html, yaml, bash, markdown, toml, lua, docker, php, zig,
        svelte, terraform, ruby,
    ]

    static func config(for url: URL) -> LanguageServerConfig? {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent
        return all.first { $0.languages[ext] != nil || $0.fileNames[name] != nil }
    }

    static func config(id: String) -> LanguageServerConfig? {
        all.first { $0.id == id }
    }

    func languageID(for url: URL) -> String {
        languages[url.pathExtension.lowercased()] ?? fileNames[url.lastPathComponent] ?? id
    }

    /// What Orbit installed wins over what was already on the machine.
    func command(root: URL, environment: [String: String], installer: LanguageInstaller) -> AgentCommand? {
        if let install, let command = installer.command(
            package: install.package, binary: install.binary, arguments: install.arguments, environment: environment
        ) {
            return command
        }
        return resolve(root, environment)
    }

    /// A server found on PATH by one of `names`, installable from Mason.
    static func standard(
        id: String, name: String, languages: [String: String], fileNames: [String: String] = [:],
        package: String? = nil, binary: String, arguments: [String] = [], alsoFound: [String] = [], needs: String? = nil
    ) -> LanguageServerConfig {
        LanguageServerConfig(
            id: id, name: name, languages: languages, fileNames: fileNames,
            resolve: { _, environment in
                for candidate in [binary] + alsoFound {
                    if let path = Shell.which(candidate, in: environment) { return AgentCommand(executable: path, arguments: arguments) }
                }
                return nil
            },
            missing: "Install it in Settings → Languages.",
            install: Install(package: package ?? id, binary: binary, arguments: arguments, needs: needs)
        )
    }

    /// SourceKit-LSP ships with Xcode (and Swift toolchains).
    static let swift = LanguageServerConfig(
        id: "sourcekit-lsp",
        name: "Swift",
        languages: ["swift": "swift"],
        resolve: { _, environment in
            if let path = Shell.output("/usr/bin/xcrun", ["--find", "sourcekit-lsp"]), FileManager.default.isExecutableFile(atPath: path) {
                return AgentCommand(executable: path)
            }
            return Shell.which("sourcekit-lsp", in: environment).map { AgentCommand(executable: $0) }
        },
        missing: "Install Xcode or a Swift toolchain."
    )

    /// TypeScript 7 (the native compiler) is its own language server; older
    /// versions go through typescript-language-server over their tsserver.
    /// The project's TypeScript decides, so errors match its `tsc`.
    static let python = standard(
        id: "basedpyright", name: "Python", languages: ["py": "python", "pyi": "python"],
        binary: "basedpyright-langserver", arguments: ["--stdio"], alsoFound: ["pyright-langserver"], needs: "Python 3"
    )

    static let rust = standard(id: "rust-analyzer", name: "Rust", languages: ["rs": "rust"], binary: "rust-analyzer")

    static let go = standard(id: "gopls", name: "Go", languages: ["go": "go"], binary: "gopls", needs: "Go")

    /// Xcode's clangd knows the SDKs; Mason's is the fallback.
    static let clang: LanguageServerConfig = {
        var config = standard(
            id: "clangd", name: "C/C++/Objective-C",
            languages: [
                "c": "c", "h": "c", "cpp": "cpp", "cc": "cpp", "cxx": "cpp", "hpp": "cpp", "hh": "cpp",
                "m": "objective-c", "mm": "objective-cpp",
            ],
            binary: "clangd"
        )
        let onPath = config.resolve
        config.resolve = { root, environment in
            if let path = Shell.output("/usr/bin/xcrun", ["--find", "clangd"]), FileManager.default.isExecutableFile(atPath: path) {
                return AgentCommand(executable: path)
            }
            return onPath(root, environment)
        }
        return config
    }()

    static let json = standard(
        id: "json-lsp", name: "JSON", languages: ["json": "json", "jsonc": "jsonc"],
        binary: "vscode-json-language-server", arguments: ["--stdio"], needs: "Node.js"
    )

    static let css = standard(
        id: "css-lsp", name: "CSS", languages: ["css": "css", "scss": "scss", "less": "less"],
        binary: "vscode-css-language-server", arguments: ["--stdio"], needs: "Node.js"
    )

    static let html = standard(
        id: "html-lsp", name: "HTML", languages: ["html": "html", "htm": "html"],
        binary: "vscode-html-language-server", arguments: ["--stdio"], needs: "Node.js"
    )

    static let yaml = standard(
        id: "yaml-language-server", name: "YAML", languages: ["yml": "yaml", "yaml": "yaml"],
        binary: "yaml-language-server", arguments: ["--stdio"], needs: "Node.js"
    )

    static let bash = standard(
        id: "bash-language-server", name: "Shell", languages: ["sh": "shellscript", "bash": "shellscript", "zsh": "shellscript"],
        binary: "bash-language-server", arguments: ["start"], needs: "Node.js"
    )

    static let markdown = standard(
        id: "marksman", name: "Markdown", languages: ["md": "markdown", "markdown": "markdown"],
        binary: "marksman", arguments: ["server"]
    )

    static let toml = standard(id: "taplo", name: "TOML", languages: ["toml": "toml"], binary: "taplo", arguments: ["lsp", "stdio"])

    static let lua = standard(id: "lua-language-server", name: "Lua", languages: ["lua": "lua"], binary: "lua-language-server")

    static let docker = standard(
        id: "dockerfile-language-server", name: "Dockerfile", languages: ["dockerfile": "dockerfile"],
        fileNames: ["Dockerfile": "dockerfile", "Containerfile": "dockerfile"],
        binary: "docker-langserver", arguments: ["--stdio"], needs: "Node.js"
    )

    static let php = standard(
        id: "intelephense", name: "PHP", languages: ["php": "php"], binary: "intelephense", arguments: ["--stdio"], needs: "Node.js"
    )

    static let zig = standard(id: "zls", name: "Zig", languages: ["zig": "zig"], binary: "zls")

    static let svelte = standard(
        id: "svelte-language-server", name: "Svelte", languages: ["svelte": "svelte"],
        binary: "svelteserver", arguments: ["--stdio"], needs: "Node.js"
    )

    static let terraform = standard(
        id: "terraform-ls", name: "Terraform", languages: ["tf": "terraform", "tfvars": "terraform-vars"],
        binary: "terraform-ls", arguments: ["serve"]
    )

    /// Mason installs it with RubyGems, which Orbit doesn't drive: found on PATH only.
    static let ruby: LanguageServerConfig = {
        var config = standard(id: "ruby-lsp", name: "Ruby", languages: ["rb": "ruby"], binary: "ruby-lsp")
        config.install = nil
        config.missing = "Install ruby-lsp: gem install ruby-lsp"
        return config
    }()

    static let typescript = LanguageServerConfig(
        id: "typescript",
        name: "TypeScript",
        languages: [
            "ts": "typescript", "mts": "typescript", "cts": "typescript", "tsx": "typescriptreact",
            "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascriptreact",
        ],
        resolve: { root, environment in
            let manager = FileManager.default
            let modules = root.appendingPathComponent("node_modules")
            let projectTypeScript = modules.appendingPathComponent("typescript")
            let hasTSServer = manager.fileExists(atPath: projectTypeScript.appendingPathComponent("lib/tsserver.js").path)
            let localTSC = modules.appendingPathComponent(".bin/tsc").path
            if manager.fileExists(atPath: projectTypeScript.path), !hasTSServer, manager.isExecutableFile(atPath: localTSC) {
                return AgentCommand(executable: localTSC, arguments: ["--lsp", "--stdio"])
            }
            let localServer = modules.appendingPathComponent(".bin/typescript-language-server").path
            if hasTSServer, manager.isExecutableFile(atPath: localServer) {
                return AgentCommand(executable: localServer, arguments: ["--stdio"])
            }
            if hasTSServer, let global = Shell.which("typescript-language-server", in: environment) {
                return AgentCommand(executable: global, arguments: ["--stdio"])
            }
            guard let npx = Shell.which("npx", in: environment) else { return nil }
            if hasTSServer {
                // Picks the project's TypeScript (5/6) up from the workspace.
                return AgentCommand(executable: npx, arguments: ["-y", "typescript-language-server", "--stdio"])
            }
            // No TypeScript in the project: the current one, native and fast.
            return AgentCommand(executable: npx, arguments: ["-y", "-p", "typescript", "tsc", "--lsp", "--stdio"])
        },
        missing: "Install Node.js, or typescript-language-server in the project."
    )
}

enum Shell {
    static func which(_ name: String, in environment: [String: String]) -> String? {
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
        for directory in path.split(separator: ":") {
            let candidate = "\(directory)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// First line of a short command's output; nil when it fails.
    static func output(_ tool: String, _ arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let line = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).first.map(String.init)
        return line?.isEmpty == false ? line : nil
    }
}
