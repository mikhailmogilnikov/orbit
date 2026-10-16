import Foundation
import OrbitACP
@testable import OrbitAgents
import Testing

struct MCPServerTests {
    @Test func parsesClaudeAndCursorFormats() {
        let json = """
        {
          "formatters": {},
          "mcpServers": {
            "files": { "command": "npx", "args": ["-y", "server", "${HOME}"], "env": { "TOKEN": "${TOKEN:-none}" } },
            "linear": { "type": "http", "url": "https://mcp.linear.app/mcp", "headers": { "Authorization": "Bearer ${KEY}" } },
            "events": { "type": "sse", "url": "https://example.com/sse" },
            "off": { "command": "x", "disabled": true },
            "broken": { "args": [] }
          }
        }
        """
        let (servers, problems) = MCPServer.parse(Data(json.utf8), displayPath: "s.json", isProject: false)
        #expect(Set(servers.map(\.name)) == ["files", "linear", "events"])
        #expect(problems.count == 1)

        let env = ["HOME": "/Users/me", "KEY": "k", "PATH": "/usr/bin"]
        let files = servers.first { $0.name == "files" }!.acp(environment: env, http: false, sse: false)
        #expect(files?["args"]?.array?.last?.string == "/Users/me")
        #expect(files?["env"]?.array?.first?["value"]?.string == "none")
        let linear = servers.first { $0.name == "linear" }!
        #expect(linear.acp(environment: env, http: false, sse: false) == nil)
        #expect(linear.acp(environment: env, http: true, sse: false)?["headers"]?.array?.first?["value"]?.string == "Bearer k")
        #expect(servers.first { $0.name == "events" }!.acp(environment: env, http: true, sse: true)?["type"]?.string == "sse")
    }

    @Test func resolvesCommandsOnPath() {
        #expect(MCPServer.resolve("ls", path: "/nowhere:/bin") == "/bin/ls")
        #expect(MCPServer.resolve("./run.sh", path: "/bin") == "./run.sh")
    }

    @Test func addsEmptyServersToExistingSettings() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-mcp-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try "{\n  \"formatters\": { \"ts\": \"prettier\" }\n}\n".write(to: url, atomically: true, encoding: .utf8)
        MCPServer.prepareForEditing(url)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(object?["mcpServers"] != nil)
        #expect(object?["formatters"] != nil)
    }
}
