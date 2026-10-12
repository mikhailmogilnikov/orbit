import Foundation
@testable import OrbitAgents
@testable import OrbitAPI
import Testing

@Suite struct AgentRegistryTests {
    @Test func decodesRegistryAndPrefersADownload() throws {
        let json = """
        {"version": "1.0.0", "agents": [
          {"id": "opencode", "name": "OpenCode", "version": "1.19.0", "authors": ["Anomaly"],
           "icon": "https://cdn.example/opencode.svg",
           "distribution": {
             "binary": {
               "darwin-aarch64": {"archive": "https://x/opencode-darwin-arm64.zip", "cmd": "./opencode", "args": ["acp"], "sha256": "ab"},
               "darwin-x86_64": {"archive": "https://x/opencode-darwin-x64.zip", "cmd": "./opencode", "args": ["acp"]}
             },
             "npx": {"package": "opencode-ai@1.19.0", "args": ["acp"]}
           }},
          {"id": "gemini", "name": "Gemini CLI", "version": "0.63.0",
           "distribution": {"npx": {"package": "@google/gemini-cli@0.63.0", "args": ["--acp"]}}},
          {"id": "linux-only", "name": "Linux Only", "version": "1.0.0",
           "distribution": {"binary": {"linux-x86_64": {"archive": "https://x/a.tar.gz", "cmd": "./a"}}}}
        ]}
        """
        struct Index: Decodable { var agents: [RegistryAgent] }
        let agents = try JSONDecoder().decode(Index.self, from: Data(json.utf8)).agents
        guard case .binary(let binary) = agents[0].method else { Issue.record("expected a download"); return }
        #expect(binary.cmd == "./opencode")
        guard case .npx(let package) = agents[1].method else { Issue.record("expected npx"); return }
        #expect(package.package == "@google/gemini-cli@0.63.0")
        #expect(agents[2].method == nil)
    }

    @MainActor @Test func movesConversationsToRegistryIDs() throws {
        let settings = PluginSettings(pluginID: "test.registry.\(UUID().uuidString)")
        let folder = URL(fileURLWithPath: "/tmp/orbit-project")
        SessionHistory(settings: settings).saveOpenTabs([
            SavedSession(providerID: "claude-code", sessionID: "1", title: "A", cwd: folder.path, updatedAt: Date()),
            SavedSession(providerID: "my-agent", sessionID: "2", title: "B", cwd: folder.path, updatedAt: Date()),
        ], selected: nil, in: folder)
        let restored = SessionHistory(settings: settings).openTabs(in: folder).sessions
        #expect(restored.map(\.providerID) == ["claude-acp", "my-agent"])
        #expect(AgentProvider.migratedID("codex") == "codex-acp")
    }
}
