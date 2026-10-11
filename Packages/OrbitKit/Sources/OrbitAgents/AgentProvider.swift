import Foundation
import OrbitACP

/// An ACP agent Orbit can launch. Built-ins plus any JSON manifest in
/// `~/.orbit/agents/*.json` — adding a new agent needs no code:
///
///     { "id": "gemini", "name": "Gemini CLI",
///       "command": { "executable": "gemini", "arguments": ["--acp"], "environment": {} } }
struct AgentProvider: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var name: String
    var systemImage: String?
    var command: AgentCommand
    var loginHint: String?

    var icon: String { systemImage ?? "sparkle" }

    static let claude = AgentProvider(
        id: "claude-code",
        name: "Claude Code",
        systemImage: "asterisk",
        command: AgentCommand(executable: "npx", arguments: ["-y", "@agentclientprotocol/claude-agent-acp"]),
        loginHint: "Run `claude` in Terminal and sign in with /login, then start a new session."
    )

    static let codex = AgentProvider(
        id: "codex",
        name: "Codex",
        systemImage: "hexagon",
        command: AgentCommand(executable: "npx", arguments: ["-y", "@agentclientprotocol/codex-acp"]),
        loginHint: "Run `codex login` in Terminal, then start a new session."
    )

    static var configDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".orbit/agents", isDirectory: true)
    }

    static func loadAll() -> [AgentProvider] {
        var providers = [claude, codex]
        let files = (try? FileManager.default.contentsOfDirectory(at: configDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let provider = try? JSONDecoder().decode(AgentProvider.self, from: data) else { continue }
            providers.removeAll { $0.id == provider.id }
            providers.append(provider)
        }
        return providers
    }
}
