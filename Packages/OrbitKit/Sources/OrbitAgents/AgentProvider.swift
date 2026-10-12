import Foundation
import OrbitACP

/// An ACP agent Orbit can launch: a JSON manifest in `~/.orbit/agents/*.json`.
/// Agents installed from the ACP registry are written there by `AgentRegistry`
/// (D52); a hand-written one needs no code either:
///
///     { "id": "my-agent", "name": "My Agent",
///       "command": { "executable": "my-agent", "arguments": ["--acp"], "environment": {} } }
struct AgentProvider: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var name: String
    var systemImage: String?
    var command: AgentCommand
    var loginHint: String?
    /// Set for agents installed from the registry.
    var registry: RegistryInstall?

    struct RegistryInstall: Hashable, Codable, Sendable {
        var version: String
        var description: String?
        /// `npx`, `uvx` or `binary`.
        var distribution: String
    }

    var icon: String { systemImage ?? "sparkle" }

    /// The registry's monochrome SVG, saved next to the manifest on install.
    var iconFile: URL { Self.directory(for: id).appendingPathComponent("icon.svg") }

    /// Whether the command can run with this environment's PATH (`npx` needs
    /// Node.js, `uvx` needs uv; downloaded agents run from an absolute path).
    func isInstalled(in environment: [String: String]) -> Bool {
        let executable = command.executable
        if executable.contains("/") { return FileManager.default.isExecutableFile(atPath: executable) }
        let path = environment["PATH"] ?? "/usr/bin:/bin"
        return path.split(separator: ":").contains { directory in
            FileManager.default.isExecutableFile(atPath: "\(directory)/\(executable)")
        }
    }

    /// What to install so the command can run, when it's a launcher.
    var requirement: String? {
        switch command.executable {
        case "npx": "Node.js"
        case "uvx": "uv"
        default: nil
        }
    }

    static var configDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".orbit/agents", isDirectory: true)
    }

    /// Where a registry agent keeps its download and icon.
    static func directory(for id: String) -> URL {
        configDirectory.appendingPathComponent(id, isDirectory: true)
    }

    static func manifestFile(for id: String) -> URL {
        configDirectory.appendingPathComponent("\(id).json")
    }

    static func loadAll() -> [AgentProvider] {
        let files = (try? FileManager.default.contentsOfDirectory(at: configDirectory, includingPropertiesForKeys: nil)) ?? []
        var providers: [AgentProvider] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  var provider = try? JSONDecoder().decode(AgentProvider.self, from: data),
                  !providers.contains(where: { $0.id == provider.id }) else { continue }
            if provider.loginHint == nil { provider.loginHint = loginHints[provider.id] }
            providers.append(provider)
        }
        return providers
    }

    /// Orbit used to ship these agents under its own ids; their saved chats,
    /// tabs and options follow them to the registry's ids.
    static let legacyIDs = ["claude-code": "claude-acp", "codex": "codex-acp"]

    static func migratedID(_ id: String) -> String { legacyIDs[id] ?? id }

    /// The registry has no sign-in instructions; these agents fail until their CLI is logged in.
    static let loginHints = [
        "claude-acp": "Run `claude` in Terminal and sign in with /login, then start a new session.",
        "codex-acp": "Run `codex login` in Terminal, then start a new session.",
        "cursor": "Run `cursor-agent login` in Terminal, then start a new session.",
        "opencode": "Run `opencode auth login` in Terminal, then start a new session.",
        "gemini": "Run `gemini` in Terminal and sign in, then start a new session.",
    ]
}
