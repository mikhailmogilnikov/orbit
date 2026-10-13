import Foundation
import OrbitACP
import OrbitAPI

/// Answers `AgentCompletion` with hidden ACP sessions of the user's last used
/// agent. The agent process stays warm between requests (starting one costs
/// ~3 s); each request gets a fresh session, set to read-only and low effort
/// when the agent offers those options. Permission requests are refused and
/// file writes fail, so the agent can only read and reply.
@MainActor
final class AgentCompletionService: AgentCompletion {
    private struct WarmAgent {
        let providerID: String
        let client: ACPClient
    }

    private let store: AgentStore
    private let replies = ReplyRouter()
    private var warm: WarmAgent?
    private var starting: Task<WarmAgent, Error>?
    private var idleTimer: Task<Void, Never>?
    private static let idleTimeout: Duration = .seconds(600)

    init(store: AgentStore) {
        self.store = store
    }

    var agentName: String { store.preferredProvider?.name ?? "Agent" }

    func prewarm() {
        Task { _ = try? await agent() }
    }

    func complete(_ prompt: String, in directory: URL) async throws -> String {
        guard let provider = store.preferredProvider else { throw Self.noAgent }
        let warm = try await agent()
        let client = warm.client
        idleTimer?.cancel()
        defer { scheduleIdleShutdown() }

        let session = try await client.newSession(cwd: directory)
        guard let sessionID = session["sessionId"]?.string else {
            throw JSONRPCError(code: -32603, message: "\(provider.name) didn't start a session")
        }
        // The agent will list it with the user's conversations; it isn't one.
        store.history.hide(SavedSession(providerID: provider.id, sessionID: sessionID, title: "", cwd: directory.path, updatedAt: Date()).id)
        await applyQuickSettings(session["configOptions"], client: client, sessionID: sessionID)
        replies.open(sessionID)
        defer { replies.close(sessionID) }

        return try await withTaskCancellationHandler {
            _ = try await client.prompt(sessionID: sessionID, content: [["type": "text", "text": .string(prompt)]])
            try Task.checkCancellation()
            let text = replies.text(of: sessionID).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw JSONRPCError(code: -32603, message: "\(provider.name) returned an empty reply") }
            return text
        } onCancel: {
            client.cancel(sessionID: sessionID)
        }
    }

    /// The running agent for the preferred provider, starting it if needed.
    private static let noAgent = JSONRPCError(code: -32603, message: "No agent is installed. Install one in Settings → Agents.")

    private func agent() async throws -> WarmAgent {
        guard let provider = store.preferredProvider else { throw Self.noAgent }
        if let warm, warm.providerID == provider.id { return warm }
        if let starting { return try await starting.value }
        warm?.client.terminate()
        warm = nil

        let replies = replies
        let directory = store.workspace.root ?? URL(fileURLWithPath: NSHomeDirectory())
        let task = Task { [store, weak self] () throws -> WarmAgent in
            let environment = await store.environment()
            let client = try ACPClient(
                command: provider.command,
                environment: environment,
                currentDirectory: directory,
                onNotification: { method, params in
                    guard method == "session/update", let sessionID = params["sessionId"]?.string,
                          let update = params["update"], update["sessionUpdate"]?.string == "agent_message_chunk",
                          let text = update["content"]?["text"]?.string else { return }
                    replies.append(text, to: sessionID)
                },
                onRequest: { method, params in
                    switch method {
                    case "session/request_permission":
                        return ["outcome": ["outcome": "cancelled"]]
                    case "fs/read_text_file":
                        guard let path = params["path"]?.string,
                              let text = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
                        else { throw JSONRPCError(code: -32002, message: "File not found") }
                        return ["content": .string(text)]
                    default:
                        throw JSONRPCError(code: -32601, message: "Not available in a read-only session: \(method)")
                    }
                },
                onExit: { _, _ in
                    Task { @MainActor in
                        if self?.warm?.providerID == provider.id { self?.warm = nil }
                    }
                }
            )
            do {
                _ = try await client.initialize()
            } catch {
                client.terminate()
                throw error
            }
            return WarmAgent(providerID: provider.id, client: client)
        }
        starting = task
        defer { starting = nil }
        let agent = try await task.value
        warm = agent
        scheduleIdleShutdown()
        return agent
    }

    /// One-off answers don't need edits or deep reasoning; both cost seconds.
    private func applyQuickSettings(_ options: JSONValue?, client: ACPClient, sessionID: String) async {
        for option in options?.array ?? [] {
            guard let id = option["id"]?.string else { continue }
            let values = (option["options"]?.array ?? []).compactMap { $0["value"]?.string }
            let category = option["category"]?.string ?? ""
            let preferred: [String]
            if id.localizedCaseInsensitiveContains("effort") || category == "thought_level" {
                preferred = ["minimal", "low"]
            } else if id == "mode" || category == "mode" {
                preferred = ["read-only", "plan"]
            } else {
                continue
            }
            if let value = preferred.first(where: values.contains), value != option["currentValue"]?.string {
                _ = try? await client.setConfigOption(sessionID: sessionID, configID: id, value: value)
            }
        }
    }

    private func scheduleIdleShutdown() {
        idleTimer?.cancel()
        idleTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.idleTimeout)
            guard !Task.isCancelled, let self else { return }
            self.warm?.client.terminate()
            self.warm = nil
        }
    }

    func shutdown() {
        idleTimer?.cancel()
        warm?.client.terminate()
        warm = nil
    }
}

/// Collects message chunks per hidden session; filled from the connection's queue.
private final class ReplyRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [String: String] = [:]

    func open(_ sessionID: String) { lock.withLock { buffers[sessionID] = "" } }
    func close(_ sessionID: String) { _ = lock.withLock { buffers.removeValue(forKey: sessionID) } }
    func text(of sessionID: String) -> String { lock.withLock { buffers[sessionID] ?? "" } }

    func append(_ chunk: String, to sessionID: String) {
        lock.withLock {
            guard buffers[sessionID] != nil else { return }
            buffers[sessionID]! += chunk
        }
    }
}
