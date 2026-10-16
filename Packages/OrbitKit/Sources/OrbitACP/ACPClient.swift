import Foundation

/// How to launch an ACP-speaking agent.
public struct AgentCommand: Sendable, Hashable, Codable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]

    public init(executable: String, arguments: [String] = [], environment: [String: String] = [:]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }
}

/// Thin typed layer over JSON-RPC for the Agent Client Protocol.
/// See https://agentclientprotocol.com
public final class ACPClient: Sendable {
    public static let protocolVersion = 1

    private let connection: JSONRPCConnection

    public init(
        command: AgentCommand,
        environment: [String: String],
        currentDirectory: URL,
        onNotification: @escaping JSONRPCConnection.NotificationHandler,
        onRequest: @escaping JSONRPCConnection.RequestHandler,
        onExit: @escaping JSONRPCConnection.ExitHandler
    ) throws {
        var env = environment
        env.merge(command.environment) { _, new in new }
        // `/usr/bin/env` resolves the executable through the login-shell PATH.
        connection = JSONRPCConnection(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [command.executable] + command.arguments,
            environment: env,
            currentDirectory: currentDirectory,
            onNotification: onNotification,
            onRequest: onRequest,
            onExit: onExit
        )
        try connection.start()
    }

    /// `terminal`: whether we implement `terminal/*`, so agents may run shell
    /// commands through us. Claude Code and Codex never do; they stream the
    /// output of commands they run themselves when we declare `terminal_output`
    /// (`_meta.terminal_info` / `terminal_output_delta` / `terminal_exit` on tool calls).
    public func initialize(terminal: Bool = false) async throws -> JSONValue {
        try await connection.request("initialize", [
            "protocolVersion": .number(Double(Self.protocolVersion)),
            "clientCapabilities": [
                "fs": ["readTextFile": true, "writeTextFile": true],
                "terminal": .bool(terminal),
                "_meta": ["terminal_output": true, "terminal_output_delta": true],
            ],
            "clientInfo": ["name": "orbit", "title": "Orbit", "version": "0.1.0"],
        ])
    }

    public func newSession(cwd: URL, mcpServers: [JSONValue] = []) async throws -> JSONValue {
        try await connection.request("session/new", [
            "cwd": .string(cwd.path),
            "mcpServers": .array(mcpServers),
        ])
    }

    /// Reopens an earlier conversation. The agent replays its history as
    /// `session/update` notifications before it answers.
    public func loadSession(sessionID: String, cwd: URL, mcpServers: [JSONValue] = []) async throws -> JSONValue {
        try await connection.request("session/load", [
            "sessionId": .string(sessionID),
            "cwd": .string(cwd.path),
            "mcpServers": .array(mcpServers),
        ])
    }

    /// The agent's earlier conversations in `cwd` (when it declares `sessionCapabilities.list`).
    public func listSessions(cwd: URL, cursor: String? = nil) async throws -> JSONValue {
        var params: [String: JSONValue] = ["cwd": .string(cwd.path)]
        if let cursor { params["cursor"] = .string(cursor) }
        return try await connection.request("session/list", .object(params))
    }

    /// Resolves when the turn ends; the result carries `stopReason`.
    public func prompt(sessionID: String, content: [JSONValue]) async throws -> JSONValue {
        try await connection.request("session/prompt", [
            "sessionId": .string(sessionID),
            "prompt": .array(content),
        ])
    }

    public func cancel(sessionID: String) {
        connection.notify("session/cancel", ["sessionId": .string(sessionID)])
    }

    public func setMode(sessionID: String, modeID: String) async throws {
        _ = try await connection.request("session/set_mode", [
            "sessionId": .string(sessionID),
            "modeId": .string(modeID),
        ])
    }

    public func setConfigOption(sessionID: String, configID: String, value: String) async throws -> JSONValue {
        try await connection.request("session/set_config_option", [
            "sessionId": .string(sessionID),
            "configId": .string(configID),
            "value": .string(value),
        ])
    }

    public func terminate() {
        connection.terminate()
    }
}
