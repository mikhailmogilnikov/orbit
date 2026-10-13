import Foundation

/// Servers converted from nvim-lspconfig by `scripts/import-lspconfig.py`
/// (`make import-lspconfig`, D65): hundreds of languages Orbit has no entry of its own for.
struct ImportedServers: Sendable, Decodable {
    var servers: [LanguageServerConfig]
    /// Extension / file name → server ids, best first.
    var choices: Choices

    struct Choices: Sendable, Decodable {
        var extensions: [String: [String]]
        var fileNames: [String: [String]]
    }

    static let shared = load()

    var byName: [String: LanguageServerConfig] {
        Self.byName
    }

    private static let byName = Dictionary(shared.servers.map { ($0.id, $0) }) { first, _ in first }

    static func load(_ url: URL? = Bundle.module.url(forResource: "Servers", withExtension: "json")) -> ImportedServers {
        guard let url, let data = try? Data(contentsOf: url),
              let table = try? JSONDecoder().decode(ImportedServers.self, from: data) else {
            return ImportedServers(servers: [], choices: Choices(extensions: [:], fileNames: [:]))
        }
        return table
    }
}
