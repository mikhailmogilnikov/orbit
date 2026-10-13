import Foundation
import OrbitACP

/// A language server as data (D65): which files it serves, where its project
/// starts, where its command comes from. Orbit installs and launches it; the
/// server itself works out the project (configs, monorepos, versions).
struct LanguageServerConfig: Sendable, Hashable, Codable {
    var id: String
    var name: String
    /// Its name in nvim-lspconfig: an entry of ours replaces the imported one (D65).
    var lspconfig: String?
    /// File extension → LSP `languageId`.
    var languages: [String: String]
    /// Files known by name (`Dockerfile`) → LSP `languageId`.
    var fileNames: [String: String] = [:]
    /// Root markers in groups: the first group found on the way up from a file
    /// wins, at the nearest folder holding one of it (`*.ext` matches by
    /// extension). Workspace-wide markers (lockfiles, `go.work`) come first so a
    /// monorepo gets one server. None found, or none given: the open folder.
    var roots: [[String]] = []
    /// Where the command comes from, the first that's there wins.
    var launch: [Launch]
    /// How Orbit installs it itself (from Mason, D57).
    var install: Install?
    /// What to do when nothing launches and Orbit can't install it.
    var missingHint: String?
    /// Set for tools that run beside a file's own server (D64): they start when
    /// a package.json on the way up depends on one of these (or their `@name/` scope).
    var usedWith: [String]?
    /// For a companion's install offer: why this project wants it.
    var purpose: String?
    /// The answer to `workspace/configuration`, looked up by section. Strings
    /// `${rootUri}` and `${rootName}` become the server's root, `${typescriptSdk}`
    /// a TypeScript `lib` folder (`typeScriptSDK`). Nil answers `{}`.
    var settings: JSONValue?
    /// Sent with `initialize`, with the same substitutions.
    var initializationOptions: JSONValue?
    /// The file's server (by id) whose formatting its files get, when it isn't this one.
    var formatsWith: String?
    /// For a server that asks its client to run tsserver requests (`tsserver/request`,
    /// Vue's), the server of the same root that runs them.
    var typeScriptServer: String?

    enum Launch: Sendable, Hashable, Codable {
        /// `node_modules/.bin/<binary>` in the project, nearest to the file; with
        /// `package`, only where that npm package is (from `minimumMajor` on, when set).
        case project(package: String? = nil, binary: String, arguments: [String] = [], minimumMajor: Int? = nil)
        /// Orbit's copy from Mason (`install`).
        case installed
        /// Found on the PATH of the user's shell (mise, asdf, rbenv shims included).
        case path(binary: String, arguments: [String] = [])
        /// A developer tool from the active Xcode.
        case xcrun(tool: String, arguments: [String] = [])
        /// An executable by its full path (one set in `.orbit/settings.json`).
        case file(path: String, arguments: [String] = [])
    }

    struct Install: Sendable, Hashable, Codable {
        /// The Mason package.
        var package: String
        var binary: String
        var arguments: [String]
        /// What it needs to install and run, if anything (shown before installing).
        var needs: String?
    }

    var isCompanion: Bool { usedWith != nil }

    var missing: String { missingHint ?? "Install it in Settings → Languages." }

    func serves(_ url: URL) -> Bool {
        languages[url.pathExtension.lowercased()] != nil || fileNames[url.lastPathComponent] != nil
    }

    func languageID(for url: URL) -> String {
        if let id = languages[url.pathExtension.lowercased()] ?? fileNames[url.lastPathComponent] { return id }
        // A file the imported entry of this name claimed (`.c++` for clangd).
        if let lspconfig, let imported = ImportedServers.shared.byName[lspconfig] {
            if let id = imported.languages[url.pathExtension.lowercased()] ?? imported.fileNames[url.lastPathComponent] { return id }
        }
        return id
    }

    // MARK: Lookup

    /// Ours: only where we know more than nvim-lspconfig's data (Xcode's
    /// tools, roots it writes as Lua, hints, VS Code's settings) and the
    /// companions; every other server is the imported entry (D72).
    static let curated: [LanguageServerConfig] = [
        swift, typescript, vue, python, rust, go, clang, lua, ruby, java, csharp, eslint, tailwind, vueLanguageServer,
    ]

    /// Ours, then every server imported from nvim-lspconfig that ours don't replace (D65).
    static let all: [LanguageServerConfig] = {
        let replaced = Set(curated.compactMap(\.lspconfig))
        return curated + ImportedServers.shared.servers.filter { !replaced.contains($0.id) }
    }()

    private static let byID: [String: LanguageServerConfig] = Dictionary(all.map { ($0.id, $0) }) { first, _ in first }
    private static let curatedByLSPConfig: [String: LanguageServerConfig] = Dictionary(
        curated.compactMap { config in config.lspconfig.map { ($0, config) } }
    ) { first, _ in first }

    private static let curatedIDs = Set(curated.map(\.id))

    var isImported: Bool { !Self.curatedIDs.contains(id) }

    /// Servers that could be the file's language server, best first: ours when
    /// one serves it, else the imported ones ranked for its extension.
    static func candidates(for url: URL) -> [LanguageServerConfig] {
        if let ours = curated.first(where: { !$0.isCompanion && $0.serves(url) }) { return [ours] }
        let imported = ImportedServers.shared
        let ids = imported.choices.extensions[url.pathExtension.lowercased()] ?? imported.choices.fileNames[url.lastPathComponent] ?? []
        var seen = Set<String>()
        return ids.compactMap { id in curatedByLSPConfig[id] ?? byID[id] }.filter { seen.insert($0.id).inserted }
    }

    /// Of the servers that could take the file, the first already in the
    /// project, installed by Orbit or on the machine; else the best one, to offer.
    static func choose(for file: URL, in root: URL, environment: [String: String], installer: LanguageInstaller) -> LanguageServerConfig? {
        let candidates = candidates(for: file)
        guard candidates.count > 1 else { return candidates.first }
        return candidates.first { $0.command(file: file, root: root, environment: environment, installer: installer) != nil }
            ?? candidates.first
    }

    /// Every server that could be the file's: ours, then the imported ones ranked for it.
    static func alternatives(for url: URL) -> [LanguageServerConfig] {
        let ours = curated.filter { !$0.isCompanion && $0.serves(url) }
        let imported = ImportedServers.shared
        let ids = imported.choices.extensions[url.pathExtension.lowercased()] ?? imported.choices.fileNames[url.lastPathComponent] ?? []
        var seen = Set<String>()
        return (ours + ids.compactMap { curatedByLSPConfig[$0] ?? byID[$0] }).filter { seen.insert($0.id).inserted }
    }

    /// The file's language server, not looking at what's installed.
    static func config(for url: URL) -> LanguageServerConfig? {
        candidates(for: url).first
    }

    /// Tools for this file type that run beside its language server, whether or not the project uses them.
    static func companions(for url: URL) -> [LanguageServerConfig] {
        all.filter { $0.isCompanion && $0.serves(url) }
    }

    static func config(id: String) -> LanguageServerConfig? {
        byID[id]
    }

    // MARK: Resolving

    /// The folder this server runs in for `file`, inside the open `folder`.
    func root(for file: URL, in folder: URL) -> URL {
        // One spelling for both, as servers are keyed by it.
        func directory(_ url: URL) -> URL { URL(filePath: url.standardizedFileURL.path, directoryHint: .isDirectory) }
        for group in roots {
            if let found = ProjectFiles.nearest(from: file, root: folder, where: { ProjectFiles.contains($0, anyOf: group) }) {
                return directory(found)
            }
        }
        return directory(folder)
    }

    /// Whether the project around `file` uses this companion.
    func isUsed(by file: URL, in folder: URL) -> Bool {
        guard let packages = usedWith else { return true }
        return ProjectFiles.nearest(from: file, root: folder) { directory in
            ProjectFiles.dependsOn(in: directory) { name in
                packages.contains { name == $0 || name.hasPrefix("@\($0)/") }
            }
        } != nil
    }

    /// The command for a server started by `file`, looking in the project from
    /// it (or from `root`) up to `root`, the open folder.
    func command(file: URL?, root: URL, environment: [String: String], installer: LanguageInstaller) -> AgentCommand? {
        for source in launch {
            switch source {
            case .project(let package, let binary, let arguments, let minimumMajor):
                let start = file ?? root.appendingPathComponent("_")
                if let path = ProjectFiles.projectBinary(package: package ?? binary, binary: binary, minimumMajor: minimumMajor, from: start, root: root, requirePackage: package != nil) {
                    return AgentCommand(executable: path, arguments: arguments)
                }
            case .installed:
                if let install, let command = installer.command(
                    package: install.package, binary: install.binary, arguments: install.arguments, environment: environment
                ) {
                    return command
                }
            case .path(let binary, let arguments):
                if let path = Shell.which(binary, in: environment) { return AgentCommand(executable: path, arguments: arguments) }
            case .xcrun(let tool, let arguments):
                if let path = Shell.output("/usr/bin/xcrun", ["--find", tool]), FileManager.default.isExecutableFile(atPath: path) {
                    return AgentCommand(executable: path, arguments: arguments)
                }
            case .file(let path, let arguments):
                if FileManager.default.isExecutableFile(atPath: path) { return AgentCommand(executable: path, arguments: arguments) }
            }
        }
        return nil
    }

    /// Already on this machine (not the project's, not Orbit's copy): for Settings.
    func machineCommand(environment: [String: String]) -> AgentCommand? {
        var machine = self
        machine.launch = launch.filter {
            switch $0 {
            case .path, .xcrun, .file: true
            case .project, .installed: false
            }
        }
        return machine.command(file: nil, root: URL(fileURLWithPath: "/"), environment: environment, installer: .shared)
    }

    /// `settings` for a server running in `root`.
    func settings(for root: URL, installer: LanguageInstaller = .shared) -> JSONValue? {
        settings.map { substitute($0, root: root, installer: installer) }
    }

    /// `initializationOptions` for a server running in `root`.
    func initializationOptions(for root: URL, installer: LanguageInstaller = .shared) -> JSONValue? {
        initializationOptions.map { substitute($0, root: root, installer: installer) }
    }

    private func substitute(_ value: JSONValue, root: URL, installer: LanguageInstaller) -> JSONValue {
        switch value {
        case .string("${rootUri}"): .string(root.absoluteString)
        case .string("${rootName}"): .string(root.lastPathComponent)
        case .string("${typescriptSdk}"): .string(typeScriptSDK(for: root, installer: installer) ?? "")
        case .string("${vueTypeScriptPlugin}"): .string(vueTypeScriptPlugin(for: root, installer: installer) ?? "")
        case .array(let items): .array(items.map { substitute($0, root: root, installer: installer) })
        case .object(let object): .object(object.mapValues { substitute($0, root: root, installer: installer) })
        default: value
        }
    }

    /// Where tsserver finds `@vue/typescript-plugin`: beside Orbit's Vue server,
    /// whose protocol it has to match, else the project's.
    func vueTypeScriptPlugin(for root: URL, installer: LanguageInstaller) -> String? {
        let manager = FileManager.default
        func has(_ folder: URL) -> Bool {
            manager.fileExists(atPath: folder.appendingPathComponent("node_modules/@vue/typescript-plugin/package.json").path)
        }
        let installed = installer.directory(for: LanguageServerConfig.vueLanguageServer.install?.package ?? "")
        if has(installed) { return installed.path }
        var components = root.standardizedFileURL.pathComponents
        while !components.isEmpty {
            let folder = URL(fileURLWithPath: NSString.path(withComponents: components))
            if has(folder) { return folder.path }
            components.removeLast()
        }
        return nil
    }

    /// For servers built on tsserver (Astro, MDX): a TypeScript `lib` folder it
    /// can load — the project's, found from the root up as Node finds it, else
    /// the one installed with the server, else the one with Orbit's
    /// typescript-language-server. TypeScript 7 has no tsserver library, so
    /// a project on it falls through to a copy that does.
    func typeScriptSDK(for root: URL, installer: LanguageInstaller) -> String? {
        let manager = FileManager.default
        func usable(_ lib: URL) -> Bool {
            ["tsserverlibrary.js", "typescript.js"].contains { manager.fileExists(atPath: lib.appendingPathComponent($0).path) }
        }
        // By path components: `deletingLastPathComponent()` of `/` is `/..`, never `/`.
        var components = root.standardizedFileURL.pathComponents
        while !components.isEmpty {
            let lib = URL(fileURLWithPath: NSString.path(withComponents: components + ["node_modules", "typescript", "lib"]))
            if usable(lib) { return lib.path }
            components.removeLast()
        }
        let packages = [install?.package, LanguageServerConfig.typescript.install?.package].compactMap(\.self)
        return packages.lazy.map { installer.directory(for: $0).appendingPathComponent("node_modules/typescript/lib") }.first(where: usable)?.path
    }
}

// MARK: The table

extension LanguageServerConfig {
    /// Orbit's copy first, then one already on the machine.
    static func standard(
        id: String, name: String, lspconfig: String, languages: [String: String], fileNames: [String: String] = [:], roots: [[String]] = [],
        package: String? = nil, binary: String, arguments: [String] = [], alsoFound: [String] = [], needs: String? = nil
    ) -> LanguageServerConfig {
        LanguageServerConfig(
            id: id, name: name, lspconfig: lspconfig, languages: languages, fileNames: fileNames, roots: roots,
            launch: [.installed] + ([binary] + alsoFound).map { .path(binary: $0, arguments: arguments) },
            install: Install(package: package ?? id, binary: binary, arguments: arguments, needs: needs)
        )
    }

    /// A JS project's lockfile marks its workspace (one server per monorepo), else its manifest.
    static let javaScriptRoots = [
        ["pnpm-lock.yaml", "yarn.lock", "package-lock.json", "bun.lock", "bun.lockb"],
        ["package.json", "tsconfig.json", "jsconfig.json"],
    ]

    static let javaScriptLanguages = [
        "ts": "typescript", "mts": "typescript", "cts": "typescript", "tsx": "typescriptreact",
        "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascriptreact",
    ]

    /// SourceKit-LSP finds the packages in a folder itself.
    static let swift = LanguageServerConfig(
        id: "sourcekit-lsp", name: "Swift", lspconfig: "sourcekit", languages: ["swift": "swift"],
        launch: [.xcrun(tool: "sourcekit-lsp"), .path(binary: "sourcekit-lsp")],
        missingHint: "Install Xcode or a Swift toolchain."
    )

    /// The project's TypeScript decides, so errors match its `tsc`: 7+ (native)
    /// is its own server, older ones go through typescript-language-server,
    /// which picks the project's tsserver up itself.
    static let typescript = LanguageServerConfig(
        id: "typescript", name: "TypeScript", lspconfig: "ts_ls", languages: javaScriptLanguages, roots: javaScriptRoots,
        launch: [
            .project(package: "typescript", binary: "tsc", arguments: ["--lsp", "--stdio"], minimumMajor: 7),
            .project(package: "typescript-language-server", binary: "typescript-language-server", arguments: ["--stdio"]),
            .installed,
            .path(binary: "typescript-language-server", arguments: ["--stdio"]),
        ],
        install: Install(package: "typescript-language-server", binary: "typescript-language-server", arguments: ["--stdio"], needs: "Node.js"),
        settings: ["typescript": ["inlayHints": typeScriptHints], "javascript": ["inlayHints": typeScriptHints]],
        // typescript-language-server takes tsserver's preferences here, not from the settings.
        initializationOptions: ["preferences": [
            "includeInlayParameterNameHints": "literals",
            "includeInlayParameterNameHintsWhenArgumentMatchesName": false,
            "includeInlayFunctionLikeReturnTypeHints": true,
            "includeInlayEnumMemberValueHints": true,
            "includeInlayPropertyDeclarationTypeHints": true,
            "includeInlayVariableTypeHints": false,
            "includeInlayFunctionParameterTypeHints": false,
        ]]
    )

    /// Vue 3 splits the work (D74): tsserver with Vue's plugin answers for the
    /// TypeScript in a component (script and template expressions), and Vue's
    /// own server, beside it, for the template and styles, running its
    /// TypeScript questions through this one.
    static let vue = LanguageServerConfig(
        id: "vue", name: "Vue", lspconfig: "vue_ls", languages: ["vue": "vue"], roots: javaScriptRoots,
        launch: [
            .project(package: "typescript-language-server", binary: "typescript-language-server", arguments: ["--stdio"]),
            .installed,
            .path(binary: "typescript-language-server", arguments: ["--stdio"]),
        ],
        install: typescript.install,
        settings: typescript.settings,
        initializationOptions: [
            "plugins": [["name": "@vue/typescript-plugin", "location": "${vueTypeScriptPlugin}", "languages": ["vue"]]],
            "preferences": typescript.initializationOptions?["preferences"] ?? .null,
        ],
        formatsWith: "vue-language-server"
    )

    /// TypeScript has every inlay hint off unless asked: names for literal
    /// arguments and inferred return types, not every variable's type (noisy in TS).
    static let typeScriptHints: JSONValue = [
        "parameterNames": ["enabled": "literals", "suppressWhenArgumentMatchesName": true],
        "parameterTypes": ["enabled": false],
        "variableTypes": ["enabled": false, "suppressWhenTypeMatchesName": true],
        "propertyDeclarationTypes": ["enabled": true],
        "functionLikeReturnTypes": ["enabled": true],
        "enumMemberValues": ["enabled": true],
    ]

    /// Sees the project's interpreter through its `.venv` (the project environment, D65).
    static let python = standard(
        id: "basedpyright", name: "Python", lspconfig: "basedpyright", languages: ["py": "python", "pyi": "python"],
        roots: [
            ["uv.lock", "poetry.lock", "pyrightconfig.json"],
            ["pyproject.toml", "setup.py", "setup.cfg", "requirements.txt", "Pipfile"],
        ],
        binary: "basedpyright-langserver", arguments: ["--stdio"], alsoFound: ["pyright-langserver"], needs: "Python 3"
    )

    static let rust = standard(
        id: "rust-analyzer", name: "Rust", lspconfig: "rust_analyzer", languages: ["rs": "rust"], roots: [["Cargo.lock"], ["Cargo.toml"]], binary: "rust-analyzer"
    )

    /// gopls has every inlay hint off unless asked.
    static let go = {
        var go = standard(id: "gopls", name: "Go", lspconfig: "gopls", languages: ["go": "go"], roots: [["go.work"], ["go.mod"]], binary: "gopls", needs: "Go")
        go.settings = ["gopls": ["hints": ["parameterNames": true, "constantValues": true, "functionTypeParameters": true]]]
        return go
    }()

    /// Xcode's clangd knows the SDKs; Mason's is the fallback.
    static let clang = LanguageServerConfig(
        id: "clangd", name: "C/C++/Objective-C", lspconfig: "clangd",
        languages: [
            "c": "c", "h": "c", "cpp": "cpp", "cc": "cpp", "cxx": "cpp", "hpp": "cpp", "hh": "cpp",
            "m": "objective-c", "mm": "objective-cpp",
        ],
        launch: [.xcrun(tool: "clangd"), .installed, .path(binary: "clangd")],
        install: Install(package: "clangd", binary: "clangd", arguments: [])
    )

    static let lua = {
        var lua = standard(id: "lua-language-server", name: "Lua", lspconfig: "lua_ls", languages: ["lua": "lua"], binary: "lua-language-server")
        lua.settings = ["Lua": ["hint": ["enable": true]]]
        return lua
    }()

    /// Mason installs it with RubyGems, which Orbit doesn't drive: found on PATH only.
    static let ruby = LanguageServerConfig(
        id: "ruby-lsp", name: "Ruby", lspconfig: "ruby_lsp",
        languages: ["rb": "ruby", "rake": "ruby", "gemspec": "ruby", "ru": "ruby"], fileNames: ["Gemfile": "ruby", "Rakefile": "ruby"],
        roots: [["Gemfile"]],
        launch: [.path(binary: "ruby-lsp")],
        missingHint: "Install ruby-lsp: gem install ruby-lsp"
    )

    /// Eclipse JDT LS wants a folder of its own per project (`-data`).
    static let java = LanguageServerConfig(
        id: "jdtls", name: "Java", lspconfig: "jdtls", languages: ["java": "java"],
        roots: [["mvnw", "gradlew", "settings.gradle", "settings.gradle.kts", ".git"], ["build.xml", "pom.xml", "build.gradle", "build.gradle.kts"]],
        launch: [.installed, .path(binary: "jdtls", arguments: ["-data", "${dataDir}"])],
        install: Install(package: "jdtls", binary: "jdtls", arguments: ["-data", "${dataDir}"], needs: "Java 21 and Python 3")
    )

    /// Mason installs it with NuGet, which Orbit doesn't drive: found on PATH only.
    static let csharp = LanguageServerConfig(
        id: "csharp-ls", name: "C#", lspconfig: "csharp_ls", languages: ["cs": "csharp", "csx": "csharp"],
        roots: [["*.sln", "*.slnx"], ["*.csproj"]],
        launch: [.path(binary: "csharp-ls")],
        missingHint: "Install csharp-ls: dotnet tool install --global csharp-ls",
        initializationOptions: ["AutomaticWorkspaceInit": true]
    )

    // MARK: Companions (D64)

    /// Runs the project's own ESLint (it finds it and the config per file), so rules and plugins match.
    static let eslint = LanguageServerConfig(
        id: "eslint", name: "ESLint", lspconfig: "eslint",
        languages: javaScriptLanguages.merging(["vue": "vue", "svelte": "svelte", "astro": "astro"]) { $1 },
        roots: javaScriptRoots,
        launch: [.installed, .path(binary: "vscode-eslint-language-server", arguments: ["--stdio"])],
        install: Install(package: "eslint-lsp", binary: "vscode-eslint-language-server", arguments: ["--stdio"], needs: "Node.js"),
        usedWith: ["eslint"],
        purpose: "This project uses ESLint: see its problems and fixes in the editor.",
        // What VS Code's extension sends by default (the server has no defaults of its own).
        settings: [
            "validate": "on",
            "run": "onType",
            "format": false,
            "quiet": false,
            "onIgnoredFiles": "off",
            "useESLintClass": false,
            "rulesCustomizations": [],
            "nodePath": .null,
            // The nearest package.json / config's folder: monorepo packages lint with their own setup.
            "workingDirectory": ["mode": "auto"],
            "workspaceFolder": ["uri": "${rootUri}", "name": "${rootName}"],
            "problems": ["shortenToSingleLine": false],
            "codeAction": [
                "disableRuleComment": ["enable": true, "location": "separateLine"],
                "showDocumentation": ["enable": true],
            ],
            "codeActionOnSave": ["enable": false, "mode": "all"],
            // Read without a check, so it must be there; empty lets ESLint (8.57+) pick flat or legacy config itself.
            "experimental": [:],
        ]
    )

    /// Vue's template, styles and checks beside the Vue tsserver (D74); a component's
    /// formatting too (tsserver leaves `.vue` files as they are).
    static let vueLanguageServer = LanguageServerConfig(
        id: "vue-language-server", name: "Vue templates", languages: ["vue": "vue"], roots: javaScriptRoots,
        launch: [.installed, .path(binary: "vue-language-server", arguments: ["--stdio"])],
        install: Install(package: "vue-language-server", binary: "vue-language-server", arguments: ["--stdio"], needs: "Node.js"),
        usedWith: ["vue", "nuxt"],
        purpose: "This project uses Vue: template completion, Vue's checks and formatting.",
        typeScriptServer: "vue"
    )

    /// Class completion, hover and lint; the server finds the project's Tailwind (v3 config or v4 CSS) itself.
    static let tailwind = LanguageServerConfig(
        id: "tailwindcss", name: "Tailwind CSS", lspconfig: "tailwindcss",
        languages: javaScriptLanguages.merging([
            "html": "html", "htm": "html", "css": "css", "scss": "scss", "less": "less",
            "vue": "vue", "svelte": "svelte", "astro": "astro", "mdx": "mdx",
        ]) { $1 },
        roots: javaScriptRoots,
        launch: [.installed, .path(binary: "tailwindcss-language-server", arguments: ["--stdio"])],
        install: Install(package: "tailwindcss-language-server", binary: "tailwindcss-language-server", arguments: ["--stdio"], needs: "Node.js"),
        usedWith: ["tailwindcss"],
        purpose: "This project uses Tailwind CSS: class completion, previews and lint.",
        settings: [
            "editor": ["tabSize": 2],
            "tailwindCSS": [
                "validate": true,
                "classAttributes": ["class", "className", "class:list", "classList", "ngClass"],
                "lint": [
                    "cssConflict": "warning", "invalidApply": "error", "invalidScreen": "error",
                    "invalidVariant": "error", "invalidConfigPath": "error", "invalidTailwindDirective": "error",
                    "recommendedVariantOrder": "warning",
                ],
            ],
        ]
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

/// Looking at a project from a file towards the folder's root. Generic on
/// purpose (D65): which tool lives where is the servers' business.
enum ProjectFiles {
    /// The first folder from the file's up to `root` where `matches`.
    static func nearest(from file: URL, root: URL, where matches: (URL) -> Bool) -> URL? {
        let rootPath = root.standardizedFileURL.path
        var directory = file.standardizedFileURL.deletingLastPathComponent()
        while directory.path == rootPath || directory.path.hasPrefix(rootPath + "/") {
            if matches(directory) { return directory }
            guard directory.path != rootPath else { break }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    /// `markers` are file names, or `*.ext` for any name with that extension.
    static func contains(_ directory: URL, anyOf markers: [String]) -> Bool {
        let manager = FileManager.default
        let names = markers.filter { !$0.hasPrefix("*.") }
        if names.contains(where: { manager.fileExists(atPath: directory.appendingPathComponent($0).path) }) { return true }
        let extensions = markers.filter { $0.hasPrefix("*.") }.map { String($0.dropFirst(2)) }
        guard !extensions.isEmpty, let entries = try? manager.contentsOfDirectory(atPath: directory.path) else { return false }
        return entries.contains { entry in extensions.contains { entry.hasSuffix(".\($0)") } }
    }

    static func packageJSON(in directory: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("package.json")) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func dependsOn(in directory: URL, where matches: (String) -> Bool) -> Bool {
        guard let json = packageJSON(in: directory) else { return false }
        return ["dependencies", "devDependencies", "peerDependencies"].contains { key in
            ((json[key] as? [String: Any])?.keys).map { $0.contains(where: matches) } ?? false
        }
    }

    /// `node_modules/.bin/<binary>` of the nearest node_modules holding `package`
    /// (at `minimumMajor` or later), from the file up to `root`.
    static func projectBinary(
        package: String, binary: String, minimumMajor: Int?, from file: URL, root: URL, requirePackage: Bool = true
    ) -> String? {
        let manager = FileManager.default
        var found: String?
        _ = nearest(from: file, root: root) { directory in
            let modules = directory.appendingPathComponent("node_modules")
            guard requirePackage else {
                let path = modules.appendingPathComponent(".bin/\(binary)").path
                if manager.isExecutableFile(atPath: path) { found = path }
                return found != nil
            }
            guard let manifest = try? Data(contentsOf: modules.appendingPathComponent("\(package)/package.json")) else { return false }
            if let minimumMajor {
                let version = (try? JSONSerialization.jsonObject(with: manifest) as? [String: Any])?["version"] as? String
                guard let major = version?.split(separator: ".").first.flatMap({ Int($0) }), major >= minimumMajor else { return true }
            }
            let path = modules.appendingPathComponent(".bin/\(binary)").path
            guard manager.isExecutableFile(atPath: path) else { return false }
            found = path
            return true
        }
        return found
    }

    /// The project's own tools ahead of the user's (D65): the nearest
    /// `node_modules/.bin` and virtualenv from the file up to `root` go first on PATH.
    static func environment(for file: URL?, root: URL, base: [String: String]) -> [String: String] {
        let manager = FileManager.default
        var directories: [String] = []
        var environment = base
        var foundVirtualEnv = false
        var directory = (file ?? root.appendingPathComponent("_")).standardizedFileURL.deletingLastPathComponent()
        let rootPath = root.standardizedFileURL.path
        while directory.path == rootPath || directory.path.hasPrefix(rootPath + "/") {
            let bin = directory.appendingPathComponent("node_modules/.bin").path
            if manager.fileExists(atPath: bin) { directories.append(bin) }
            if !foundVirtualEnv, let venv = [".venv", "venv"].lazy.map(directory.appendingPathComponent).first(where: {
                manager.fileExists(atPath: $0.appendingPathComponent("pyvenv.cfg").path)
            }) {
                directories.append(venv.appendingPathComponent("bin").path)
                environment["VIRTUAL_ENV"] = venv.path
                foundVirtualEnv = true
            }
            guard directory.path != rootPath else { break }
            directory = directory.deletingLastPathComponent()
        }
        guard !directories.isEmpty else { return environment }
        environment["PATH"] = (directories + [base["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        return environment
    }
}
