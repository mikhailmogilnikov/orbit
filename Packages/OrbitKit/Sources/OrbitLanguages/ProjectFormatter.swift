import Foundation
import OrbitAPI

/// A formatter Orbit recognizes in a repository by its config (D60, D61).
/// Language servers format by their built-in rules; these are the tools repos
/// use instead of them. Plain data: adding one is a new entry.
struct FormatterPreset: Sendable {
    enum Location: Sendable, Equatable {
        /// `node_modules/.bin` above the file.
        case nodeModules
        /// `.venv/bin` or `venv/bin` above the file.
        case virtualEnvironment
        /// Composer's `vendor/bin` above the file.
        case composer
        /// A Ruby binstub in `bin/` above the file.
        case binstub
        /// `bundle exec <binary>`, when the `Gemfile.lock` above the file has the gem.
        case bundler
        case path
    }

    /// How the text goes in and the result comes out.
    enum Mode: Sendable, Equatable {
        /// Text on stdin, the result on stdout.
        case stdin
        /// ESLint's `--fix-dry-run --format json`: the result is `output` in its report.
        case eslintReport
        /// For tools that only fix files in place: a temporary copy with the same name.
        case temporaryFile
    }

    /// Whether it needs a config of its own to be picked.
    enum Trigger: Sendable, Equatable {
        case configured
        /// Picked only when nothing else formats the file, like ESLint, whose
        /// fixes come after Prettier's formatting when a repo has both.
        case configuredFallback
        /// A formatter with nothing to configure but `.editorconfig` (shfmt): installed is enough.
        case installedFallback
    }

    var id: String
    var name: String
    var fileTypes: Set<String>
    var configFiles: [String] = []
    /// Other files that turn it on when they contain the text: a `[tool.ruff`
    /// table in `pyproject.toml`, the gem in `Gemfile.lock`.
    var mentions: [(file: String, text: String)] = []
    var binary: String
    /// Where its executable may be, in order. Node tools only from the repo:
    /// a global one may be another major version, which formats differently.
    var locations: [Location]
    /// `{file}` is the file's path (the copy's, in `.temporaryFile` mode), `{ext}` its extension.
    var arguments: [String]
    var mode: Mode = .stdin
    var trigger: Trigger = .configured
    /// Exit codes that still mean formatted: linters exit 1 when problems remain.
    var successCodes: Set<Int32> = [0]
    /// Text in its errors that means the file didn't parse, though it exited "successfully".
    var syntaxError: String?

    private static let scripts: Set<String> = ["js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts"]
    private static let web = scripts.union(["json", "jsonc", "css"])

    /// Nearer configs win; in one folder, the first match.
    static let all: [FormatterPreset] = [
        FormatterPreset(
            id: "biome", name: "Biome", fileTypes: web.union(["graphql", "gql"]), configFiles: ["biome.json", "biome.jsonc"],
            binary: "biome", locations: [.nodeModules], arguments: ["format", "--stdin-file-path={file}"]
        ),
        FormatterPreset(
            id: "oxfmt", name: "oxfmt",
            fileTypes: web.union(["json5", "scss", "less", "html", "vue", "yaml", "yml", "md", "graphql"]),
            configFiles: [".oxfmtrc.json", ".oxfmtrc.jsonc", "oxfmt.config.ts", "oxfmt.config.mts"],
            binary: "oxfmt", locations: [.nodeModules], arguments: ["--stdin-filepath={file}"]
        ),
        FormatterPreset(
            id: "dprint", name: "dprint", fileTypes: web.union(["json5", "md", "toml", "yaml", "yml", "scss", "less", "html", "graphql"]),
            configFiles: ["dprint.json", ".dprint.json", "dprint.jsonc", ".dprint.jsonc"],
            binary: "dprint", locations: [.nodeModules, .path], arguments: ["fmt", "--stdin", "{file}"]
        ),
        FormatterPreset(
            id: "deno", name: "Deno", fileTypes: web.union(["md", "markdown", "scss", "less", "html", "yaml", "yml"]),
            configFiles: ["deno.json", "deno.jsonc"],
            binary: "deno", locations: [.nodeModules, .path], arguments: ["fmt", "--ext={ext}", "-"]
        ),
        FormatterPreset(
            id: "prettier", name: "Prettier",
            fileTypes: web.union(["json5", "scss", "less", "html", "vue", "yaml", "yml", "md", "mdx", "graphql", "gql", "hbs", "handlebars"]),
            configFiles: [
                ".prettierrc", ".prettierrc.json", ".prettierrc.json5", ".prettierrc.yaml", ".prettierrc.yml", ".prettierrc.toml",
                ".prettierrc.js", ".prettierrc.cjs", ".prettierrc.mjs", ".prettierrc.ts",
                "prettier.config.js", "prettier.config.cjs", "prettier.config.mjs", "prettier.config.ts",
            ],
            // A `prettier` key, or Prettier among the dependencies: its defaults are the repo's style.
            mentions: [("package.json", "\"prettier\"")],
            binary: "prettier", locations: [.nodeModules], arguments: ["--stdin-filepath", "{file}"]
        ),
        FormatterPreset(
            id: "ruff", name: "Ruff", fileTypes: ["py", "pyi"], configFiles: ["ruff.toml", ".ruff.toml"], mentions: [("pyproject.toml", "[tool.ruff")],
            binary: "ruff", locations: [.virtualEnvironment, .path], arguments: ["format", "--stdin-filename", "{file}", "-"]
        ),
        FormatterPreset(
            id: "black", name: "Black", fileTypes: ["py", "pyi"], mentions: [("pyproject.toml", "[tool.black]")],
            binary: "black", locations: [.virtualEnvironment, .path], arguments: ["--quiet", "--stdin-filename", "{file}", "-"]
        ),
        FormatterPreset(
            id: "stylua", name: "StyLua", fileTypes: ["lua"], configFiles: ["stylua.toml", ".stylua.toml"],
            binary: "stylua", locations: [.path], arguments: ["--stdin-filepath", "{file}", "-"]
        ),
        FormatterPreset(
            id: "standard", name: "Standard Ruby", fileTypes: ["rb", "rake", "gemspec", "ru"],
            configFiles: [".standard.yml"], mentions: [("Gemfile.lock", " standard (")],
            binary: "standardrb", locations: [.binstub, .bundler, .path],
            arguments: ["--stdin", "{file}", "--fix", "--stderr", "--format", "quiet"], successCodes: [0, 1], syntaxError: "Lint/Syntax"
        ),
        FormatterPreset(
            id: "rubocop", name: "RuboCop", fileTypes: ["rb", "rake", "gemspec", "ru"], configFiles: [".rubocop.yml"],
            binary: "rubocop", locations: [.binstub, .bundler, .path],
            arguments: ["--stdin", "{file}", "--autocorrect", "--stderr", "--format", "quiet"], successCodes: [0, 1], syntaxError: "Lint/Syntax"
        ),
        FormatterPreset(
            id: "pint", name: "Pint", fileTypes: ["php"], configFiles: ["pint.json"], mentions: [("composer.json", "\"laravel/pint\"")],
            binary: "pint", locations: [.composer], arguments: ["--quiet", "{file}"], mode: .temporaryFile
        ),
        FormatterPreset(
            id: "php-cs-fixer", name: "PHP CS Fixer", fileTypes: ["php"], configFiles: [".php-cs-fixer.php", ".php-cs-fixer.dist.php"],
            binary: "php-cs-fixer", locations: [.composer, .path],
            arguments: ["fix", "--quiet", "--no-interaction", "--using-cache=no", "{file}"], mode: .temporaryFile
        ),
        FormatterPreset(
            id: "eslint", name: "ESLint", fileTypes: scripts,
            configFiles: [
                "eslint.config.js", "eslint.config.mjs", "eslint.config.cjs", "eslint.config.ts", "eslint.config.mts", "eslint.config.cts",
                ".eslintrc", ".eslintrc.js", ".eslintrc.cjs", ".eslintrc.json", ".eslintrc.yaml", ".eslintrc.yml",
            ],
            mentions: [("package.json", "\"eslintConfig\"")],
            binary: "eslint", locations: [.nodeModules],
            arguments: ["--stdin", "--stdin-filename", "{file}", "--fix-dry-run", "--format", "json"],
            mode: .eslintReport, trigger: .configuredFallback, successCodes: [0, 1]
        ),
        FormatterPreset(
            id: "shfmt", name: "shfmt", fileTypes: ["sh", "bash"],
            binary: "shfmt", locations: [.path], arguments: ["--filename", "{file}"], trigger: .installedFallback
        ),
    ]

    static func preset(id: String) -> FormatterPreset? { all.first { $0.id == id } }

    /// The config in `directory` that turns it on, if any.
    func config(in directory: URL) -> String? {
        let manager = FileManager.default
        if let file = configFiles.first(where: { manager.fileExists(atPath: directory.appendingPathComponent($0).path) }) { return file }
        for (file, text) in mentions {
            if let contents = try? String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8), contents.contains(text) { return file }
        }
        return nil
    }

    func command(from directory: URL, root: URL?, environment: [String: String]) -> (executable: String, prefix: [String])? {
        ProjectFormatter.command(binary, locations: locations, from: directory, root: root, environment: environment)
    }

    func formatter(_ command: (executable: String, prefix: [String]), directory: URL, source: String) -> ProjectFormatter {
        ProjectFormatter(
            name: name, executable: command.executable, arguments: command.prefix + arguments, directory: directory, source: source,
            mode: mode, successCodes: successCodes, syntaxError: syntaxError
        )
    }
}

/// What formats a file, and why.
indirect enum FormatterChoice: Sendable, Equatable {
    case tool(ProjectFormatter)
    /// The language server, indented per `.editorconfig`.
    case server
    /// Turned off in settings.
    case off(source: String)
    /// Several in a row, each on the one before's result (D203): `.tool`s, the server only first.
    case chain([FormatterChoice])
}

/// A command a file's text is run through.
struct ProjectFormatter: Sendable, Equatable {
    var name: String
    var executable: String
    /// With `{file}` and `{ext}` still in them.
    var arguments: [String]
    /// It runs here: the folder with its config, or the project root.
    var directory: URL
    /// What turned it on, shown in Settings: `apps/web/.prettierrc`, `.orbit/settings.json`.
    var source: String
    var mode: FormatterPreset.Mode = .stdin
    var successCodes: Set<Int32> = [0]
    var syntaxError: String?

    /// Settings first (the project's, then the user's), then a config found
    /// above the file, else the language server.
    static func choice(for file: URL, root: URL?, environment: [String: String], home: URL = FormatterSettings.home) throws -> FormatterChoice {
        let type = file.pathExtension.lowercased()
        let folder = file.deletingLastPathComponent()
        for settings in try FormatterSettings.layers(root: root, home: home) {
            guard let rule = settings.rule(for: type) else { continue }
            return try resolve(rule, settings: settings, folder: folder, root: root, environment: environment)
        }
        return detected(for: file, root: root, environment: environment).map(FormatterChoice.tool) ?? .server
    }

    private static func resolve(_ rule: FormatterSettings.Rule, settings: FormatterSettings, folder: URL, root: URL?, environment: [String: String]) throws -> FormatterChoice {
        let directory = root ?? folder
        switch rule {
        case .chain(let rules):
            return .chain(try rules.map { try resolve($0, settings: settings, folder: folder, root: root, environment: environment) })
        case .server: return .server
        case .off: return .off(source: settings.displayPath)
        case .preset(let id):
            guard let preset = FormatterPreset.preset(id: id) else {
                throw FormatterSettings.Failure.invalid("\(settings.displayPath): no formatter called “\(id)”. Known: \(FormatterPreset.all.map(\.id).joined(separator: ", ")), server, off.")
            }
            guard let command = preset.command(from: folder, root: root, environment: environment) else {
                throw FormatterSettings.Failure.invalid("\(settings.displayPath) asks for \(preset.name), but “\(preset.binary)” isn't installed here.")
            }
            return .tool(preset.formatter(command, directory: directory, source: settings.displayPath))
        case .command(let command, let arguments):
            let expanded = (command as NSString).expandingTildeInPath
            let executable: String? = expanded.hasPrefix("/") ? expanded
                : command.contains("/") ? directory.appendingPathComponent(command).standardizedFileURL.path
                : Self.command(command, locations: [.nodeModules, .virtualEnvironment, .composer, .binstub, .path], from: folder, root: root, environment: environment)?.executable
            guard let executable, FileManager.default.isExecutableFile(atPath: executable) else {
                throw FormatterSettings.Failure.invalid("\(settings.displayPath): “\(command)” isn't installed here.")
            }
            return .tool(ProjectFormatter(name: (command as NSString).lastPathComponent, executable: executable, arguments: arguments, directory: directory, source: settings.displayPath))
        }
    }

    /// The nearest configured preset above `file`, not looking past `root`;
    /// fallbacks only when no other one is configured.
    static func detected(for file: URL, root: URL?, environment: [String: String]) -> ProjectFormatter? {
        let type = file.pathExtension.lowercased()
        let presets = FormatterPreset.all.filter { $0.fileTypes.contains(type) }
        guard !presets.isEmpty else { return nil }
        let directories = ancestors(of: file.deletingLastPathComponent(), root: root)
        for triggers in [[FormatterPreset.Trigger.configured], [.configuredFallback]] {
            for directory in directories {
                for preset in presets where triggers.contains(preset.trigger) {
                    guard let config = preset.config(in: directory),
                          let command = preset.command(from: directory, root: root, environment: environment) else { continue }
                    return preset.formatter(command, directory: directory, source: relative(directory.appendingPathComponent(config), to: root))
                }
            }
        }
        for preset in presets where preset.trigger == .installedFallback {
            guard let command = preset.command(from: file.deletingLastPathComponent(), root: root, environment: environment) else { continue }
            return preset.formatter(command, directory: root ?? file.deletingLastPathComponent(), source: "installed: \(command.executable)")
        }
        return nil
    }

    /// Longer than any formatter takes on a source file; past it, it's stuck.
    static let timeout: DispatchTimeInterval = .seconds(15)

    /// The file's whole new text.
    func format(_ text: String, file: URL, environment: [String: String]) async throws -> String {
        // The tool runs in the folder's real path (a process's working directory
        // is resolved); a file named through a symlink (/var → /private/var) is
        // then "outside of base path" for ESLint, which silently skips it.
        var target = Self.resolvingSymlinks(file)
        var scratch: URL?
        if mode == .temporaryFile {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-format-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            target = folder.appendingPathComponent(file.lastPathComponent)
            try Data(text.utf8).write(to: target)
            scratch = folder
        }
        defer { if let scratch { try? FileManager.default.removeItem(at: scratch) } }

        let arguments = arguments.map {
            $0.replacingOccurrences(of: "{file}", with: target.path).replacingOccurrences(of: "{ext}", with: file.pathExtension.lowercased())
        }
        let result = try await run(arguments, input: mode == .temporaryFile ? nil : Data(text.utf8), environment: environment)
        let errors = String(decoding: result.errors, as: UTF8.self)
        let tail = errors.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }.suffix(8).joined(separator: "\n")
        guard successCodes.contains(result.status) else {
            throw LanguageInstaller.Failure.failed("\(name) failed (exit \(result.status))" + (tail.isEmpty ? "." : ":\n\(tail)"))
        }
        if let syntaxError, errors.contains(syntaxError) {
            let lines = errors.split(whereSeparator: \.isNewline).filter { $0.contains(syntaxError) }.prefix(3).joined(separator: "\n")
            throw LanguageInstaller.Failure.failed("The file doesn't parse:\n\(lines)")
        }
        // A tool set to CRLF (Prettier's endOfLine) still gives the buffer `\n`; saving restores the file's endings.
        let formatted: String = switch mode {
        case .stdin: String(decoding: result.output, as: UTF8.self)
        case .temporaryFile: try String(contentsOf: target, encoding: .utf8)
        case .eslintReport: try Self.eslintOutput(result.output, original: text)
        }
        return TextFile.normalized(formatted)
    }

    /// The real path of a file that may not exist yet (an unsaved one): its nearest existing folder resolved.
    static func resolvingSymlinks(_ file: URL) -> URL {
        var existing = file.deletingLastPathComponent()
        var rest = [file.lastPathComponent]
        while existing.path != "/" {
            if let real = LanguageServer.realPath(existing.path) {
                return rest.reversed().reduce(URL(fileURLWithPath: real)) { $0.appendingPathComponent($1) }
            }
            rest.append(existing.lastPathComponent)
            existing = existing.deletingLastPathComponent()
        }
        return file
    }

    /// The fixed text from ESLint's JSON report; a fatal message is a parse error.
    static func eslintOutput(_ data: Data, original: String) throws -> String {
        guard let reports = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], let report = reports.first else {
            throw LanguageInstaller.Failure.failed("ESLint didn't report on the file.")
        }
        let messages = report["messages"] as? [[String: Any]] ?? []
        if let fatal = messages.first(where: { $0["fatal"] as? Bool == true }) {
            let line = (fatal["line"] as? Int).map { "Line \($0): " } ?? ""
            throw LanguageInstaller.Failure.failed(line + (fatal["message"] as? String ?? "The file doesn't parse."))
        }
        return report["output"] as? String ?? original
    }

    /// Runs the formatter with its pipes read on threads of their own: blocking
    /// reads on Swift's few cooperative threads can starve the app.
    private func run(_ arguments: [String], input: Data?, environment: [String: String]) async throws -> (status: Int32, output: Data, errors: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        let inputPipe = Pipe(), output = Pipe(), errors = Pipe()
        // No stdin for in-place fixers: one that asks a question gets an empty answer, not a hang.
        process.standardInput = input == nil ? FileHandle.nullDevice : inputPipe
        process.standardOutput = output
        process.standardError = errors
        let run = Run(process)
        let name = name
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(status: Int32, output: Data, errors: Data), Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: LanguageInstaller.Failure.failed("Couldn't run \(name): \(error.localizedDescription)"))
                        return
                    }
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.timeout) { run.terminate(timedOut: true) }
                    if let input {
                        let stdin = inputPipe.fileHandleForWriting
                        DispatchQueue.global(qos: .userInitiated).async {
                            stdin.write(input)
                            try? stdin.close()
                        }
                    }
                    // Its own thread, not the global queue: a block waited on from a
                    // global-queue thread can starve on a Mac with few cores.
                    let group = DispatchGroup()
                    group.enter()
                    Thread.detachNewThread {
                        run.errors = errors.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    group.wait()
                    process.waitUntilExit()
                    if run.timedOut {
                        continuation.resume(throwing: LanguageInstaller.Failure.failed("\(name) didn't finish in 15 seconds."))
                    } else {
                        continuation.resume(returning: (process.terminationStatus, data, run.errors))
                    }
                }
            }
        } onCancel: {
            run.terminate(timedOut: false)
        }
    }

    private final class Run: @unchecked Sendable {
        let process: Process
        private let lock = NSLock()
        private var didTimeOut = false
        private var stderr = Data()
        init(_ process: Process) { self.process = process }

        var errors: Data {
            get { lock.withLock { stderr } }
            set { lock.withLock { stderr = newValue } }
        }

        var timedOut: Bool { lock.withLock { didTimeOut } }

        func terminate(timedOut: Bool) {
            lock.withLock {
                guard process.isRunning else { return }
                if timedOut { didTimeOut = true }
                process.terminate()
            }
        }
    }

    /// Where `name` is installed, and what goes before the formatter's own arguments (`exec rubocop` for Bundler).
    static func command(_ name: String, locations: [FormatterPreset.Location], from directory: URL, root: URL?, environment: [String: String]) -> (executable: String, prefix: [String])? {
        let manager = FileManager.default
        func first(_ relativePaths: [String]) -> String? {
            for directory in ancestors(of: directory, root: root) {
                for relative in relativePaths {
                    let path = directory.appendingPathComponent(relative).path
                    if manager.isExecutableFile(atPath: path) { return path }
                }
            }
            return nil
        }
        for location in locations {
            switch location {
            case .nodeModules:
                if let path = first(["node_modules/.bin/\(name)"]) { return (path, []) }
            case .virtualEnvironment:
                if let path = first([".venv/bin/\(name)", "venv/bin/\(name)"]) { return (path, []) }
            case .composer:
                if let path = first(["vendor/bin/\(name)"]) { return (path, []) }
            case .binstub:
                if let path = first(["bin/\(name)"]) { return (path, []) }
            case .bundler:
                let gem = name == "standardrb" ? "standard" : name
                for directory in ancestors(of: directory, root: root) {
                    guard let lock = try? String(contentsOf: directory.appendingPathComponent("Gemfile.lock"), encoding: .utf8) else { continue }
                    if lock.contains("    \(gem) ("), let bundle = Shell.which("bundle", in: environment) { return (bundle, ["exec", name]) }
                    break
                }
            case .path:
                if let path = Shell.which(name, in: environment) { return (path, []) }
            }
        }
        return nil
    }

    /// `directory` and its parents up to `root` (or `/`).
    static func ancestors(of directory: URL, root: URL?) -> [URL] {
        EditorConfig.ancestors(of: directory, root: root)
    }

    static func relative(_ url: URL, to root: URL?) -> String {
        let path = url.standardizedFileURL.path
        guard let base = root?.standardizedFileURL.path, path.hasPrefix(base + "/") else { return path }
        return String(path.dropFirst(base.count + 1))
    }
}

/// `"formatters"` in `.orbit/settings.json` (the project's) and
/// `~/.orbit/settings.json` (everyone's), by file type:
///
///     { "formatters": {
///         "py": "ruff",
///         "sh": { "command": "shfmt", "arguments": ["-i", "2", "-filename", "{file}"] },
///         "md": "off",
///         "ts, tsx": "server",
///         "vue": ["prettier", "eslint"]
///     } }
struct FormatterSettings: Sendable {
    indirect enum Rule: Sendable, Equatable {
        case preset(String)
        case server
        case off
        case command(String, arguments: [String])
        /// One after another (D203): `["prettier", "eslint"]`.
        case chain([Rule])
    }

    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let message): message }
        }
    }

    var rules: [String: Rule]
    var displayPath: String

    static let home = FileManager.default.homeDirectoryForCurrentUser

    /// A new settings file, showing each kind of rule.
    static let example = """
    {
      "formatters": {
        "py": "ruff",
        "md": "off",
        "sh": { "command": "shfmt", "arguments": ["-i", "2", "-filename", "{file}"] }
      }
    }

    """
    static func projectFile(root: URL) -> URL { root.appendingPathComponent(".orbit/settings.json") }
    static func userFile(home: URL = home) -> URL { home.appendingPathComponent(".orbit/settings.json") }

    func rule(for type: String) -> Rule? { rules[type] }

    /// The project's settings, then the user's; missing files are skipped.
    static func layers(root: URL?, home: URL) throws -> [FormatterSettings] {
        var files: [(URL, String)] = []
        if let root { files.append((projectFile(root: root), ".orbit/settings.json")) }
        files.append((userFile(home: home), "~/.orbit/settings.json"))
        return try files.compactMap { url, display in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try parse(data, displayPath: display)
        }
    }

    static func parse(_ data: Data, displayPath: String) throws -> FormatterSettings {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.invalid("\(displayPath) isn't valid JSON.")
        }
        guard let formatters = object["formatters"] else { return FormatterSettings(rules: [:], displayPath: displayPath) }
        guard let table = formatters as? [String: Any] else { throw Failure.invalid("\(displayPath): “formatters” should be an object keyed by file type.") }
        var rules: [String: Rule] = [:]
        func single(_ value: Any, key: String) throws -> Rule {
            switch value {
            case let name as String:
                return switch name.lowercased() {
                case "server": .server
                case "off", "none": .off
                default: .preset(name.lowercased())
                }
            case let command as [String: Any]:
                guard let executable = command["command"] as? String, !executable.isEmpty else {
                    throw Failure.invalid("\(displayPath): “\(key)” needs a “command”.")
                }
                return .command(executable, arguments: command["arguments"] as? [String] ?? [])
            default:
                throw Failure.invalid("\(displayPath): “\(key)” should be a formatter name, { \"command\": … } or a list of them.")
            }
        }
        for (key, value) in table {
            let rule: Rule
            if let list = value as? [Any] {
                let steps = try list.map { try single($0, key: key) }
                guard !steps.isEmpty, !steps.contains(.off) else {
                    throw Failure.invalid("\(displayPath): “\(key)” lists formatters to run one after another; “off” can't be one of them.")
                }
                // The server formats the document it has: only the text as typed, so only first.
                guard !steps.dropFirst().contains(.server) else {
                    throw Failure.invalid("\(displayPath): in “\(key)”, “server” can only come first.")
                }
                rule = steps.count == 1 ? steps[0] : .chain(steps)
            } else {
                rule = try single(value, key: key)
            }
            for type in key.split(separator: ",") {
                let type = type.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
                if !type.isEmpty { rules[type] = rule }
            }
        }
        return FormatterSettings(rules: rules, displayPath: displayPath)
    }
}

/// What formats what in a folder, for Settings → Formatting (D61).
struct FormattingOverview: Sendable, Equatable {
    struct Row: Sendable, Equatable, Identifiable {
        var id: String { "\(source)|\(fileTypes)" }
        var fileTypes: String
        var formatter: String
        var source: String
        /// Configured but unusable: not installed, an unknown name.
        var warning: String?
    }

    var rows: [Row] = []
    var problems: [String] = []

    static let empty = FormattingOverview()

    private init() {}

    init(root: URL?, environment: [String: String], home: URL = FormatterSettings.home) {
        var files: [(URL, String)] = []
        if let root { files.append((FormatterSettings.projectFile(root: root), ".orbit/settings.json")) }
        files.append((FormatterSettings.userFile(home: home), "~/.orbit/settings.json"))
        for (url, display) in files {
            guard let data = try? Data(contentsOf: url) else { continue }
            do {
                let settings = try FormatterSettings.parse(data, displayPath: display)
                var byRule: [String: [String]] = [:]
                var order: [String] = []
                for (type, rule) in settings.rules.sorted(by: { $0.key < $1.key }) {
                    let key = "\(rule)"
                    if byRule[key] == nil { order.append(key) }
                    byRule[key, default: []].append(type)
                }
                for key in order {
                    let types = byRule[key] ?? []
                    guard let rule = settings.rules[types[0]] else { continue }
                    let (name, warning) = Self.describe(rule, root: root, environment: environment)
                    rows.append(Row(fileTypes: Self.list(types), formatter: name, source: display, warning: warning))
                }
            } catch {
                problems.append(error.localizedDescription)
            }
        }
        guard let root else { return }
        for directory in Self.projectFolders(root) {
            for preset in FormatterPreset.all where preset.trigger != .installedFallback {
                guard let config = preset.config(in: directory) else { continue }
                let installed = preset.command(from: directory, root: root, environment: environment) != nil
                let name = preset.trigger == .configuredFallback ? "\(preset.name) (when nothing else formats)" : preset.name
                rows.append(Row(
                    fileTypes: Self.list(preset.fileTypes.sorted()), formatter: name,
                    source: ProjectFormatter.relative(directory.appendingPathComponent(config), to: root),
                    warning: installed ? nil : "Configured, but “\(preset.binary)” isn't installed.\(Self.installHint(preset))"
                ))
            }
        }
        for preset in FormatterPreset.all where preset.trigger == .installedFallback {
            guard let command = preset.command(from: root, root: root, environment: environment) else { continue }
            rows.append(Row(
                fileTypes: Self.list(preset.fileTypes.sorted()), formatter: "\(preset.name) (when nothing else formats)",
                source: command.executable
            ))
        }
    }

    /// A rule's name in Settings, and what's wrong with it.
    private static func describe(_ rule: FormatterSettings.Rule, root: URL?, environment: [String: String]) -> (String, String?) {
        switch rule {
        case .server: return ("Language server", nil)
        case .off: return ("Off", nil)
        case .preset(let id):
            guard let preset = FormatterPreset.preset(id: id) else { return (id, "No formatter called “\(id)”.") }
            if let root, preset.command(from: root, root: root, environment: environment) == nil {
                return (preset.name, "“\(preset.binary)” isn't installed.")
            }
            return (preset.name, nil)
        case .command(let command, let arguments): return (([command] + arguments).joined(separator: " "), nil)
        case .chain(let rules):
            let parts = rules.map { describe($0, root: root, environment: environment) }
            return (parts.map(\.0).joined(separator: " → "), parts.compactMap(\.1).first)
        }
    }

    private static func installHint(_ preset: FormatterPreset) -> String {
        switch preset.locations.first {
        case .nodeModules?: " Run your package manager's install."
        case .composer?: " Run composer install."
        case .binstub?, .bundler?: " Run bundle install."
        case .virtualEnvironment?: " Install it into the project's .venv."
        default: ""
        }
    }

    private static func list(_ types: [String]) -> String {
        let shown = types.prefix(6).map { ".\($0)" }.joined(separator: " ")
        return types.count > 6 ? shown + " …" : shown
    }

    /// The root and folders two levels down (monorepo packages), without dependencies and hidden ones.
    private static func projectFolders(_ root: URL) -> [URL] {
        var result = [root.standardizedFileURL]
        var level = [root.standardizedFileURL]
        for _ in 0..<2 {
            var next: [URL] = []
            for directory in level {
                let children = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
                for child in children where (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    guard !["node_modules", "venv", "build", "dist", "target", "vendor", "Pods", "DerivedData"].contains(child.lastPathComponent) else { continue }
                    next.append(child.standardizedFileURL)
                }
            }
            result += next.sorted { $0.path < $1.path }
            level = next
            if result.count > 400 { break }
        }
        return result
    }
}
