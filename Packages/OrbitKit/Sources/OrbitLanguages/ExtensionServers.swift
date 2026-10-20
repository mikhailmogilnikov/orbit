import Foundation
import OrbitACP
import Synchronization

/// Language servers extensions bring (D195), in `language_servers.json`:
///
///     { "servers": [ {
///         "id": "kotlin-lsp", "name": "Kotlin",
///         "fileTypes": { "kt": "kotlin", "kts": "kotlin" },     extension → LSP languageId
///         "fileNames": { "build.gradle.kts": "kotlin" },
///         "roots": [["settings.gradle.kts", "settings.gradle"], ["build.gradle.kts"]],
///         "command": "kotlin-lsp", "arguments": ["--stdio"],    on the PATH, or ./bin/… in the extension
///         "install": { "mason": "kotlin-lsp", "needs": "Java" }, Orbit installs it from Mason
///         "settings": { … }, "initializationOptions": { … }
///     } ] }
///
/// They come before Orbit's own and the imported ones for their file types:
/// installing one is asking for it.
enum ExtensionServers {
    private static let servers = Mutex<[LanguageServerConfig]>([])

    static var current: [LanguageServerConfig] { servers.withLock { $0 } }

    static func set(_ new: [LanguageServerConfig]) {
        servers.withLock { $0 = new }
    }

    private struct File: Decodable {
        var servers: [Entry]
    }

    private struct Entry: Decodable {
        var id: String
        var name: String
        var fileTypes: [String: String]?
        var fileNames: [String: String]?
        var roots: [[String]]?
        var command: String?
        var arguments: [String]?
        var install: Install?
        var settings: JSONValue?
        var initializationOptions: JSONValue?

        struct Install: Decodable {
            var mason: String
            var binary: String?
            var arguments: [String]?
            var needs: String?
        }
    }

    /// One extension's servers; `folder` is the extension's, for `./` commands.
    static func parse(_ data: Data, folder: URL, extensionName: String) throws -> [LanguageServerConfig] {
        try JSONDecoder().decode(File.self, from: data).servers.map { entry in
            var launch: [LanguageServerConfig.Launch] = []
            var install: LanguageServerConfig.Install?
            if let mason = entry.install {
                let binary = mason.binary ?? entry.command ?? mason.mason
                install = .init(package: mason.mason, binary: binary, arguments: mason.arguments ?? entry.arguments ?? [], needs: mason.needs)
                launch.append(.installed)
            }
            if let command = entry.command {
                let arguments = entry.arguments ?? []
                if command.hasPrefix("./") {
                    launch.append(.file(path: folder.appendingPathComponent(command).standardizedFileURL.path, arguments: arguments))
                } else {
                    launch.append(.path(binary: command, arguments: arguments))
                }
            }
            return LanguageServerConfig(
                id: entry.id, name: entry.name, languages: Dictionary(uniqueKeysWithValues: (entry.fileTypes ?? [:]).map { ($0.key.lowercased(), $0.value) }),
                fileNames: entry.fileNames ?? [:], roots: entry.roots ?? [], launch: launch, install: install,
                missingHint: install == nil ? "Install \(entry.command ?? entry.name) (the \(extensionName) extension runs it)." : nil,
                settings: entry.settings, initializationOptions: entry.initializationOptions
            )
        }
    }
}
