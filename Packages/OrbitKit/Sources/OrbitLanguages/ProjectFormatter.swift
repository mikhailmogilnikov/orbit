import Foundation

/// A formatter Orbit recognizes in a repository by its config (D60, D61).
/// Language servers format by their built-in rules; these are the tools repos
/// use instead of them. Plain data: adding one is a new entry.
struct FormatterPreset: Sendable {
    enum Location: Sendable {
        /// `node_modules/.bin` above the file.
        case nodeModules
        /// `.venv/bin` or `venv/bin` above the file.
        case virtualEnvironment
        case path
    }

    var id: String
    var name: String
    var fileTypes: Set<String>
    var configFiles: [String]
    /// A `[tool.<name>]` table in `pyproject.toml` that configures it.
    var pyprojectTool: String?
    /// A key in `package.json` that configures it.
    var packageKey: String?
    var binary: String
    /// Where its executable may be, in order. Node tools only from the repo:
    /// a global one may be another major version, which formats differently.
    var locations: [Location]
    /// `{file}` is the file's path; the text comes on stdin, the result on stdout.
    var arguments: [String]

    private static let web: Set<String> = ["js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts", "json", "jsonc", "css"]

    /// Nearer configs win; in one folder, the first match.
    static let all: [FormatterPreset] = [
        FormatterPreset(
            id: "biome", name: "Biome", fileTypes: web.union(["graphql", "gql"]), configFiles: ["biome.json", "biome.jsonc"],
            binary: "biome", locations: [.nodeModules], arguments: ["format", "--stdin-file-path={file}"]
        ),
        FormatterPreset(
            id: "dprint", name: "dprint", fileTypes: web.union(["json5", "md", "toml", "yaml", "yml", "scss", "less", "html", "graphql"]),
            configFiles: ["dprint.json", ".dprint.json", "dprint.jsonc", ".dprint.jsonc"],
            binary: "dprint", locations: [.nodeModules, .path], arguments: ["fmt", "--stdin", "{file}"]
        ),
        FormatterPreset(
            id: "prettier", name: "Prettier",
            fileTypes: web.union(["json5", "scss", "less", "html", "vue", "yaml", "yml", "md", "mdx", "graphql", "gql", "hbs", "handlebars"]),
            configFiles: [
                ".prettierrc", ".prettierrc.json", ".prettierrc.json5", ".prettierrc.yaml", ".prettierrc.yml", ".prettierrc.toml",
                ".prettierrc.js", ".prettierrc.cjs", ".prettierrc.mjs", ".prettierrc.ts",
                "prettier.config.js", "prettier.config.cjs", "prettier.config.mjs", "prettier.config.ts",
            ],
            packageKey: "prettier", binary: "prettier", locations: [.nodeModules], arguments: ["--stdin-filepath", "{file}"]
        ),
        FormatterPreset(
            id: "ruff", name: "Ruff", fileTypes: ["py", "pyi"], configFiles: ["ruff.toml", ".ruff.toml"], pyprojectTool: "ruff",
            binary: "ruff", locations: [.virtualEnvironment, .path], arguments: ["format", "--stdin-filename", "{file}", "-"]
        ),
        FormatterPreset(
            id: "black", name: "Black", fileTypes: ["py", "pyi"], configFiles: [], pyprojectTool: "black",
            binary: "black", locations: [.virtualEnvironment, .path], arguments: ["--quiet", "--stdin-filename", "{file}", "-"]
        ),
        FormatterPreset(
            id: "stylua", name: "StyLua", fileTypes: ["lua"], configFiles: ["stylua.toml", ".stylua.toml"],
            binary: "stylua", locations: [.path], arguments: ["--stdin-filepath", "{file}", "-"]
        ),
    ]

    static func preset(id: String) -> FormatterPreset? { all.first { $0.id == id } }

    /// The config in `directory` that turns it on, if any.
    func config(in directory: URL) -> String? {
        let manager = FileManager.default
        if let file = configFiles.first(where: { manager.fileExists(atPath: directory.appendingPathComponent($0).path) }) { return file }
        if let tool = pyprojectTool,
           let text = try? String(contentsOf: directory.appendingPathComponent("pyproject.toml"), encoding: .utf8),
           text.split(whereSeparator: \.isNewline).contains(where: { $0.hasPrefix("[tool.\(tool)]") || $0.hasPrefix("[tool.\(tool).") }) {
            return "pyproject.toml"
        }
        if let key = packageKey,
           let data = try? Data(contentsOf: directory.appendingPathComponent("package.json")),
           let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any], package[key] != nil {
            return "package.json"
        }
        return nil
    }

    func executable(from directory: URL, root: URL?, environment: [String: String]) -> String? {
        ProjectFormatter.executable(binary, locations: locations, from: directory, root: root, environment: environment)
    }
}

/// What formats a file, and why.
enum FormatterChoice: Sendable, Equatable {
    case tool(ProjectFormatter)
    /// The language server, indented per `.editorconfig`.
    case server
    /// Turned off in settings.
    case off(source: String)
}

/// A command a file's text is piped through.
struct ProjectFormatter: Sendable, Equatable {
    var name: String
    var executable: String
    /// With `{file}` still in them.
    var arguments: [String]
    /// It runs here: the folder with its config, or the project root.
    var directory: URL
    /// What turned it on, shown in Settings: `apps/web/.prettierrc`, `.orbit/settings.json`.
    var source: String

    /// Settings first (the project's, then the user's), then a config found
    /// above the file, else the language server.
    static func choice(for file: URL, root: URL?, environment: [String: String], home: URL = FormatterSettings.home) throws -> FormatterChoice {
        let type = file.pathExtension.lowercased()
        for settings in try FormatterSettings.layers(root: root, home: home) {
            guard let rule = settings.rule(for: type) else { continue }
            switch rule {
            case .server: return .server
            case .off: return .off(source: settings.displayPath)
            case .preset(let id):
                guard let preset = FormatterPreset.preset(id: id) else {
                    throw FormatterSettings.Failure.invalid("\(settings.displayPath): no formatter called “\(id)”. Known: \(FormatterPreset.all.map(\.id).joined(separator: ", ")), server, off.")
                }
                let directory = root ?? file.deletingLastPathComponent()
                guard let executable = preset.executable(from: file.deletingLastPathComponent(), root: root, environment: environment) else {
                    throw FormatterSettings.Failure.invalid("\(settings.displayPath) asks for \(preset.name), but “\(preset.binary)” isn't installed here.")
                }
                return .tool(ProjectFormatter(name: preset.name, executable: executable, arguments: preset.arguments, directory: directory, source: settings.displayPath))
            case .command(let command, let arguments):
                let directory = root ?? file.deletingLastPathComponent()
                let expanded = (command as NSString).expandingTildeInPath
                let executable: String? = expanded.hasPrefix("/") ? expanded
                    : command.contains("/") ? directory.appendingPathComponent(command).standardizedFileURL.path
                    : Self.executable(command, locations: [.nodeModules, .virtualEnvironment, .path], from: file.deletingLastPathComponent(), root: root, environment: environment)
                guard let executable, FileManager.default.isExecutableFile(atPath: executable) else {
                    throw FormatterSettings.Failure.invalid("\(settings.displayPath): “\(command)” isn't installed here.")
                }
                return .tool(ProjectFormatter(name: (command as NSString).lastPathComponent, executable: executable, arguments: arguments, directory: directory, source: settings.displayPath))
            }
        }
        return detected(for: file, root: root, environment: environment).map(FormatterChoice.tool) ?? .server
    }

    /// The nearest configured preset above `file`, not looking past `root`.
    static func detected(for file: URL, root: URL?, environment: [String: String]) -> ProjectFormatter? {
        let type = file.pathExtension.lowercased()
        let presets = FormatterPreset.all.filter { $0.fileTypes.contains(type) }
        guard !presets.isEmpty else { return nil }
        for directory in ancestors(of: file.deletingLastPathComponent(), root: root) {
            for preset in presets {
                guard let config = preset.config(in: directory),
                      let executable = preset.executable(from: directory, root: root, environment: environment) else { continue }
                let source = relative(directory.appendingPathComponent(config), to: root)
                return ProjectFormatter(name: preset.name, executable: executable, arguments: preset.arguments, directory: directory, source: source)
            }
        }
        return nil
    }

    /// The file's whole new text.
    func format(_ text: String, file: URL, environment: [String: String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments.map { $0.replacingOccurrences(of: "{file}", with: file.path) }
        process.currentDirectoryURL = directory
        process.environment = environment
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let box = ProcessBox(process)
        let name = name
        return try await withTaskCancellationHandler {
            try await Task.detached {
                try process.run()
                let stdin = input.fileHandleForWriting
                Task.detached {
                    stdin.write(Data(text.utf8))
                    try? stdin.close()
                }
                // Both pipes drain at once: a big file's errors mustn't block its output.
                let errorData = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let failure = await errorData.value
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    let tail = String(decoding: failure, as: UTF8.self).split(whereSeparator: \.isNewline).prefix(6).joined(separator: "\n")
                    throw LanguageInstaller.Failure.failed("\(name) failed" + (tail.isEmpty ? "" : ":\n\(tail)"))
                }
                return String(decoding: data, as: UTF8.self)
            }.value
        } onCancel: {
            box.terminate()
        }
    }

    private final class ProcessBox: @unchecked Sendable {
        let process: Process
        init(_ process: Process) { self.process = process }
        func terminate() { if process.isRunning { process.terminate() } }
    }

    static func executable(_ name: String, locations: [FormatterPreset.Location], from directory: URL, root: URL?, environment: [String: String]) -> String? {
        let manager = FileManager.default
        for location in locations {
            switch location {
            case .nodeModules:
                for directory in ancestors(of: directory, root: root) {
                    let path = directory.appendingPathComponent("node_modules/.bin/\(name)").path
                    if manager.isExecutableFile(atPath: path) { return path }
                }
            case .virtualEnvironment:
                for directory in ancestors(of: directory, root: root) {
                    for folder in [".venv", "venv"] {
                        let path = directory.appendingPathComponent("\(folder)/bin/\(name)").path
                        if manager.isExecutableFile(atPath: path) { return path }
                    }
                }
            case .path:
                if let path = Shell.which(name, in: environment) { return path }
            }
        }
        return nil
    }

    /// `directory` and its parents up to `root` (or `/`).
    static func ancestors(of directory: URL, root: URL?) -> [URL] {
        var result: [URL] = []
        var current = directory.standardizedFileURL
        let stop = root?.standardizedFileURL.path
        while true {
            result.append(current)
            if current.path == stop || current.path == "/" { break }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return result
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
///         "ts, tsx": "server"
///     } }
struct FormatterSettings: Sendable {
    enum Rule: Sendable, Equatable {
        case preset(String)
        case server
        case off
        case command(String, arguments: [String])
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
        for (key, value) in table {
            let rule: Rule
            switch value {
            case let name as String:
                rule = switch name.lowercased() {
                case "server": .server
                case "off", "none": .off
                default: .preset(name.lowercased())
                }
            case let command as [String: Any]:
                guard let executable = command["command"] as? String, !executable.isEmpty else {
                    throw Failure.invalid("\(displayPath): “\(key)” needs a “command”.")
                }
                let arguments = command["arguments"] as? [String] ?? []
                rule = .command(executable, arguments: arguments)
            default:
                throw Failure.invalid("\(displayPath): “\(key)” should be a formatter name or { \"command\": … }.")
            }
            for type in key.split(separator: ",") {
                let type = type.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
                if !type.isEmpty { rules[type] = rule }
            }
        }
        return FormatterSettings(rules: rules, displayPath: displayPath)
    }
}

/// What formats what in a folder, for Settings → Languages (D61).
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
                    var warning: String?
                    let name: String
                    switch rule {
                    case .server: name = "Language server"
                    case .off: name = "Off"
                    case .preset(let id):
                        let preset = FormatterPreset.preset(id: id)
                        name = preset?.name ?? id
                        if preset == nil {
                            warning = "No formatter called “\(id)”."
                        } else if let preset, let root, preset.executable(from: root, root: root, environment: environment) == nil {
                            warning = "“\(preset.binary)” isn't installed."
                        }
                    case .command(let command, let arguments): name = ([command] + arguments).joined(separator: " ")
                    }
                    rows.append(Row(fileTypes: Self.list(types), formatter: name, source: display, warning: warning))
                }
            } catch {
                problems.append(error.localizedDescription)
            }
        }
        guard let root else { return }
        for directory in Self.projectFolders(root) {
            for preset in FormatterPreset.all {
                guard let config = preset.config(in: directory) else { continue }
                let installed = preset.executable(from: directory, root: root, environment: environment) != nil
                let hint = preset.locations.first == .nodeModules ? " Run your package manager's install." : ""
                rows.append(Row(
                    fileTypes: Self.list(preset.fileTypes.sorted()), formatter: preset.name,
                    source: ProjectFormatter.relative(directory.appendingPathComponent(config), to: root),
                    warning: installed ? nil : "Configured, but “\(preset.binary)” isn't installed.\(hint)"
                ))
            }
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

/// How a file is indented: from `.editorconfig`, else guessed from the file.
struct Indentation: Sendable, Equatable {
    var size: Int
    var spaces: Bool

    static func of(_ file: URL, text: String, root: URL?) -> Indentation {
        let guessed = guess(text)
        guard let config = EditorConfig.properties(for: file, root: root) else { return guessed }
        var result = guessed
        if let style = config["indent_style"] { result.spaces = style != "tab" }
        let size = config["indent_size"].flatMap { $0 == "tab" ? config["tab_width"] : $0 } ?? config["tab_width"]
        if let size = size.flatMap(Int.init), size > 0 { result.size = size }
        return result
    }

    /// The most common step between consecutive indented lines. Not the smallest
    /// indent: a JSDoc block's ` * ` lines are indented by one space.
    static func guess(_ text: String) -> Indentation {
        var steps: [Int: Int] = [:]
        var tabs = 0, spaced = 0, previous = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(2000) {
            let body = line.drop { $0 == " " || $0 == "\t" }
            if body.isEmpty || body.hasPrefix("*") { continue }
            if line.hasPrefix("\t") {
                tabs += 1
                continue
            }
            let indent = line.count - body.count
            if indent > 0 { spaced += 1 }
            let step = abs(indent - previous)
            if step > 0, step <= 8 { steps[step, default: 0] += 1 }
            previous = indent
        }
        if tabs > spaced { return Indentation(size: 4, spaces: false) }
        // Ties go to the smaller step: 2 and 4 are both common in a 2-space file.
        let size = steps.max { lhs, rhs in lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key }?.key ?? 4
        return Indentation(size: size, spaces: true)
    }
}

/// The `.editorconfig` properties for a file: files nearer to it win, later sections win.
enum EditorConfig {
    static func properties(for file: URL, root: URL?) -> [String: String]? {
        var layers: [[String: String]] = []
        for directory in ProjectFormatter.ancestors(of: file.deletingLastPathComponent(), root: root) {
            guard let text = try? String(contentsOf: directory.appendingPathComponent(".editorconfig"), encoding: .utf8) else { continue }
            let relative = String(file.standardizedFileURL.path.dropFirst(directory.path == "/" ? 1 : directory.path.count + 1))
            let (properties, isRoot) = parse(text, for: relative)
            layers.append(properties)
            if isRoot { break }
        }
        guard !layers.isEmpty else { return nil }
        var merged: [String: String] = [:]
        for layer in layers.reversed() { merged.merge(layer) { _, new in new } }
        return merged
    }

    /// The properties that apply to `path` (relative to the file's folder), and whether it says `root = true`.
    static func parse(_ text: String, for path: String) -> (properties: [String: String], isRoot: Bool) {
        var properties: [String: String] = [:]
        var isRoot = false
        var matches: Bool?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                matches = glob(String(line.dropFirst().dropLast()), matches: path)
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces).lowercased()
            switch matches {
            case nil: if key == "root" { isRoot = value == "true" }
            case true?: properties[key] = value
            case false?: break
            }
        }
        return (properties, isRoot)
    }

    /// EditorConfig globs: `*`, `**`, `?`, `[…]`, `{a,b}`; one without a `/` matches the file name anywhere.
    static func glob(_ pattern: String, matches path: String) -> Bool {
        var pattern = pattern
        if pattern.hasPrefix("/") { pattern.removeFirst() } else if !pattern.contains("/") { pattern = "**/" + pattern }
        var regex = "^"
        var chars = Array(pattern)[...]
        var braces = 0
        while let char = chars.popFirst() {
            switch char {
            case "*":
                if chars.first == "*" {
                    chars.removeFirst()
                    if chars.first == "/" {
                        chars.removeFirst()
                        regex += "(?:.*/)?"
                    } else {
                        regex += ".*"
                    }
                } else {
                    regex += "[^/]*"
                }
            case "?": regex += "[^/]"
            case "[":
                var set = ""
                while let next = chars.popFirst(), next != "]" { set.append(next == "!" && set.isEmpty ? "^" : next) }
                regex += "[\(set.replacingOccurrences(of: "\\", with: "\\\\"))]"
            case "{":
                braces += 1
                regex += "(?:"
            case "}" where braces > 0:
                braces -= 1
                regex += ")"
            case "," where braces > 0: regex += "|"
            default: regex += NSRegularExpression.escapedPattern(for: String(char))
            }
        }
        regex += "$"
        return path.range(of: regex, options: .regularExpression) != nil
    }
}
