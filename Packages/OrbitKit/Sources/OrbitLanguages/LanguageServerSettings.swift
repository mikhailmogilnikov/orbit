import Foundation
import OrbitACP

/// `"languageServers"` in `.orbit/settings.json` (the project's, then
/// `~/.orbit/settings.json`), keyed by file type like `"formatters"` (D61, D65):
///
///     "kt": "kotlin_language_server"          another known server
///     "vue": "off"                            none
///     "nix": { "command": "nixd", "arguments": [] }
///     "py": { "server": "pyright", "settings": { … }, "initializationOptions": { … } }
///
/// Settings and init options are merged over the server's own.
struct LanguageServerSettings: Sendable {
    enum Rule: Sendable, Equatable {
        case server(String, Overrides)
        case command(String, arguments: [String], Overrides)
        case off
    }

    struct Overrides: Sendable, Equatable {
        var settings: JSONValue?
        var initializationOptions: JSONValue?
    }

    var rules: [String: Rule]
    var displayPath: String

    static let key = "languageServers"

    /// The rule for a file: by extension, else by file name.
    func rule(for file: URL) -> Rule? {
        rules[file.pathExtension.lowercased()] ?? rules[file.lastPathComponent.lowercased()]
    }

    /// The project's settings, then the user's; missing files are skipped.
    static func layers(root: URL?, home: URL = FormatterSettings.home) throws -> [LanguageServerSettings] {
        var files: [(URL, String)] = []
        if let root { files.append((FormatterSettings.projectFile(root: root), ".orbit/settings.json")) }
        files.append((FormatterSettings.userFile(home: home), "~/.orbit/settings.json"))
        return try files.compactMap { url, display in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try parse(data, displayPath: display)
        }
    }

    static func parse(_ data: Data, displayPath: String) throws -> LanguageServerSettings {
        guard let object = try? JSONDecoder().decode(JSONValue.self, from: data), case .object(let root) = object else {
            throw FormatterSettings.Failure.invalid("\(displayPath) isn't valid JSON.")
        }
        guard let section = root[key] else { return LanguageServerSettings(rules: [:], displayPath: displayPath) }
        guard case .object(let table) = section else {
            throw FormatterSettings.Failure.invalid("\(displayPath): “\(key)” should be an object keyed by file type.")
        }
        var rules: [String: Rule] = [:]
        for (types, value) in table {
            let rule: Rule
            switch value {
            case .string(let name):
                rule = ["off", "none"].contains(name.lowercased()) ? .off : .server(name, Overrides())
            case .object(let fields):
                let overrides = Overrides(settings: fields["settings"], initializationOptions: fields["initializationOptions"])
                if let command = fields["command"]?.string, !command.isEmpty {
                    rule = .command(command, arguments: fields["arguments"]?.array?.compactMap(\.string) ?? [], overrides)
                } else if let server = fields["server"]?.string {
                    rule = .server(server, overrides)
                } else {
                    throw FormatterSettings.Failure.invalid("\(displayPath): “\(types)” needs a “server” or a “command”.")
                }
            default:
                throw FormatterSettings.Failure.invalid("\(displayPath): “\(types)” should be a server name, \"off\" or { \"server\" | \"command\": … }.")
            }
            for type in types.split(separator: ",") {
                let type = type.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
                if !type.isEmpty { rules[type] = rule }
            }
        }
        return LanguageServerSettings(rules: rules, displayPath: displayPath)
    }

    /// What the settings make of a file's language server: nil for none
    /// ("off"), the default when no rule names the file. A rule that can't be
    /// followed becomes a server that doesn't start and says why.
    static func resolve(for file: URL, layers: [LanguageServerSettings], default chosen: LanguageServerConfig?) -> LanguageServerConfig? {
        guard let (rule, path) = layers.lazy.compactMap({ layer in layer.rule(for: file).map { ($0, layer.displayPath) } }).first else {
            return chosen
        }
        switch rule {
        case .off:
            return nil
        case .server(let id, let overrides):
            guard var config = LanguageServerConfig.config(id: id) else {
                return broken(file, chosen, "\(path) asks for a language server called “\(id)”, which Orbit doesn't know. Names are nvim-lspconfig's (kotlin_language_server, pyright…) or Orbit's.")
            }
            config.apply(overrides)
            return config
        case .command(let command, let arguments, let overrides):
            let name = chosen?.name ?? file.pathExtension
            var config = LanguageServerConfig(
                id: "custom:\(command) \(arguments.joined(separator: " "))", name: name,
                languages: [file.pathExtension.lowercased(): chosen?.languageID(for: file) ?? file.pathExtension.lowercased()],
                launch: [command.hasPrefix("/") ? .file(path: command, arguments: arguments) : .path(binary: command, arguments: arguments)],
                missingHint: "\(path) runs “\(command)” for these files, but it isn't installed here."
            )
            config.apply(overrides)
            return config
        }
    }

    static func broken(_ file: URL, _ chosen: LanguageServerConfig?, _ message: String) -> LanguageServerConfig {
        LanguageServerConfig(
            id: "invalid:\(file.pathExtension)", name: chosen?.name ?? "Language server", languages: [:], launch: [], missingHint: message
        )
    }

    /// Sets (or with nil, removes) the user's choice for a file type in
    /// `~/.orbit/settings.json`, keeping everything else in it.
    static func choose(_ server: String?, forType type: String, home: URL = FormatterSettings.home) throws {
        let url = FormatterSettings.userFile(home: home)
        var root: [String: JSONValue] = [:]
        if let data = try? Data(contentsOf: url) {
            guard case .object(let existing)? = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                throw FormatterSettings.Failure.invalid("~/.orbit/settings.json isn't valid JSON; fix it first.")
            }
            root = existing
        }
        var section: [String: JSONValue] = [:]
        if case .object(let existing)? = root[key] { section = existing }
        section[type] = server.map(JSONValue.string)
        root[key] = section.isEmpty ? nil : .object(section)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try (encoder.encode(JSONValue.object(root)) + Data("\n".utf8)).write(to: url, options: .atomic)
    }
}

extension LanguageServerConfig {
    mutating func apply(_ overrides: LanguageServerSettings.Overrides) {
        if let settings = overrides.settings { self.settings = self.settings.map { $0.merging(settings) } ?? settings }
        if let options = overrides.initializationOptions {
            initializationOptions = initializationOptions.map { $0.merging(options) } ?? options
        }
    }
}

extension JSONValue {
    /// Objects merged key by key, `other` winning; anything else is replaced.
    func merging(_ other: JSONValue) -> JSONValue {
        guard case .object(var mine) = self, case .object(let theirs) = other else { return other }
        for (key, value) in theirs { mine[key] = mine[key].map { $0.merging(value) } ?? value }
        return .object(mine)
    }
}
