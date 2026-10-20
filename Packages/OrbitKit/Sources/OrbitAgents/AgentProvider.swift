import Foundation
import OrbitAPI
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
    /// The extension it comes with (D195): removed with it, not on its own.
    var extensionName: String?

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

    /// Where its process starts. npx and uvx start in Orbit's agents folder,
    /// not the project: npm 11 reads the project's package.json and refuses
    /// to run when its `devEngines` asks for pnpm (EBADDEVENGINES, D193).
    /// Sessions get the project in session/new; their tools run there.
    nonisolated func launchDirectory(for project: URL) -> URL {
        let tool = (command.executable as NSString).lastPathComponent
        return ["npx", "uvx", "bunx", "pnpx"].contains(tool) ? Self.configDirectory : project
    }

    static func manifestFile(for id: String) -> URL {
        configDirectory.appendingPathComponent("\(id).json")
    }

    /// The user's agents (`~/.orbit/agents`), then extensions' (D195): the
    /// user's win on the same id.
    static func loadAll(extensions: [ExtensionFile] = []) -> [AgentProvider] {
        let files = (try? FileManager.default.contentsOfDirectory(at: configDirectory, includingPropertiesForKeys: nil)) ?? []
        var providers: [AgentProvider] = []
        let own = files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).filter { $0.pathExtension == "json" }
        for (file, source) in own.map({ ($0, ExtensionFile?.none) }) + extensions.map({ ($0.url, Optional($0)) }) {
            guard let data = try? Data(contentsOf: file),
                  var provider = try? JSONDecoder().decode(AgentProvider.self, from: data),
                  !providers.contains(where: { $0.id == provider.id }) else { continue }
            if provider.loginHint == nil { provider.loginHint = loginHints[provider.id] }
            if let source {
                provider.extensionName = source.extensionName
                // A program inside the extension, named relative to its folder.
                let executable = provider.command.executable
                if executable.hasPrefix("./") || executable.hasPrefix("bin/") {
                    let folder = file.deletingLastPathComponent().deletingLastPathComponent()
                    provider.command.executable = folder.appendingPathComponent(executable).standardizedFileURL.path
                }
            }
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
