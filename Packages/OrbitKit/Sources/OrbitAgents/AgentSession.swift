import Foundation
import OrbitACP
import OrbitAPI

/// Everything the agent process sends, funnelled through one ordered stream so
/// chunks, tool calls and permission requests are applied in arrival order.
private enum AgentEvent: Sendable {
    case notification(String, JSONValue)
    case request(String, JSONValue, CheckedContinuation<JSONValue, Error>)
    case exited(Int32, String)
}

@MainActor
@Observable
final class AgentSession: Identifiable {
    enum Status: Equatable {
        case starting, ready, working
        case failed(String)
    }

    let id = UUID()
    let provider: AgentProvider
    let cwd: URL
    var title: String
    private(set) var status: Status = .starting
    private(set) var entries: [TranscriptEntry] = []
    private(set) var configOptions: [ConfigOption] = []
    private(set) var slashCommands: [String] = []
    var draft = ""

    private var client: ACPClient?
    private var sessionID: String?
    private var eventTask: Task<Void, Never>?
    private var toolEntries: [String: TranscriptEntry] = [:]
    private var planEntry: TranscriptEntry?
    private var pendingPermissions: [PermissionRequest] = []
    private var stderrTail = ""
    /// Whether the agent exposes modes through `modes` rather than `configOptions`.
    private var usesLegacyModes = false

    private let workspace: Workspace
    private let services: ServiceRegistry
    private let environment: @MainActor () async -> [String: String]

    private var tracker: ChangeTracking? { services.resolve(ChangeTracking.self) }

    init(provider: AgentProvider, cwd: URL, workspace: Workspace, services: ServiceRegistry, environment: @escaping @MainActor () async -> [String: String]) {
        self.provider = provider
        self.cwd = cwd
        self.workspace = workspace
        self.services = services
        self.environment = environment
        title = provider.name
    }

    var isBusy: Bool { status == .working || status == .starting }
    var hasPendingPermission: Bool { pendingPermissions.contains(where: \.isPending) }

    // MARK: Lifecycle

    func start() async {
        status = .starting
        let (stream, continuation) = AsyncStream.makeStream(of: AgentEvent.self)
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handle(event)
            }
        }

        do {
            let env = await environment()
            let client = try ACPClient(
                command: provider.command,
                environment: env,
                currentDirectory: cwd,
                onNotification: { method, params in continuation.yield(.notification(method, params)) },
                onRequest: { method, params in
                    try await withCheckedThrowingContinuation { reply in
                        continuation.yield(.request(method, params, reply))
                    }
                },
                onExit: { status, stderr in
                    continuation.yield(.exited(status, stderr))
                    continuation.finish()
                }
            )
            self.client = client
            _ = try await client.initialize()
            let session = try await client.newSession(cwd: cwd)
            sessionID = session["sessionId"]?.string
            applyConfigOptions(session["configOptions"])
            if configOptions.isEmpty { applyLegacyModes(session["modes"]) }
            status = .ready
        } catch {
            status = .failed(describe(error))
        }
    }

    func shutdown() {
        for request in pendingPermissions { request.cancel() }
        client?.terminate()
        client = nil
        eventTask?.cancel()
    }

    // MARK: Prompting

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, status == .ready, let client, let sessionID else { return }
        draft = ""
        entries.append(TranscriptEntry(kind: .user, text: text))
        if title == provider.name { title = String(text.prefix(40)) }
        status = .working
        planEntry = nil

        Task {
            await tracker?.beginAgentTurn()
            do {
                let result = try await client.prompt(sessionID: sessionID, content: [["type": "text", "text": .string(text)]])
                switch result["stopReason"]?.string {
                case "max_tokens": notice("Stopped: output token limit reached.")
                case "max_turn_requests": notice("Stopped: turn request limit reached.")
                case "refusal": notice("The agent declined to continue.", isError: true)
                case "cancelled": notice("Stopped.")
                default: break
                }
            } catch {
                notice(describe(error), isError: true)
            }
            await tracker?.endAgentTurn()
            if status == .working { status = .ready }
        }
    }

    func stop() {
        guard status == .working, let client, let sessionID else { return }
        for request in pendingPermissions { request.cancel() }
        pendingPermissions.removeAll()
        client.cancel(sessionID: sessionID)
    }

    func setConfigOption(_ option: ConfigOption, value: String) {
        guard let client, let sessionID else { return }
        if let index = configOptions.firstIndex(where: { $0.id == option.id }) {
            configOptions[index].currentValue = value
        }
        Task {
            do {
                if usesLegacyModes {
                    try await client.setMode(sessionID: sessionID, modeID: value)
                } else {
                    let result = try await client.setConfigOption(sessionID: sessionID, configID: option.id, value: value)
                    applyConfigOptions(result["configOptions"])
                }
            } catch {
                notice("Couldn't change \(option.name): \(describe(error))", isError: true)
            }
        }
    }

    // MARK: Event handling

    private func handle(_ event: AgentEvent) {
        switch event {
        case .notification(let method, let params):
            if method == "session/update", let update = params["update"] { apply(update) }
        case .request(let method, let params, let reply):
            handleRequest(method, params, reply)
        case .exited(let code, let stderr):
            stderrTail = stderr
            for request in pendingPermissions { request.cancel() }
            pendingPermissions.removeAll()
            if case .failed = status { return }
            let detail = stderr.split(separator: "\n").suffix(3).joined(separator: "\n")
            status = .failed(code == 0 ? "Agent exited." : "Agent exited with code \(code).\n\(detail)")
        }
    }

    private func apply(_ update: JSONValue) {
        switch update["sessionUpdate"]?.string {
        case "agent_message_chunk":
            appendChunk(.agent, update["content"]?["text"]?.string)
        case "agent_thought_chunk":
            appendChunk(.thought, update["content"]?["text"]?.string)
        case "tool_call", "tool_call_update":
            applyToolCall(update)
        case "plan":
            applyPlan(update["entries"])
        case "available_commands_update":
            slashCommands = (update["availableCommands"]?.array ?? []).compactMap { $0["name"]?.string }
        case "current_mode_update":
            if let mode = update["currentModeId"]?.string,
               let index = configOptions.firstIndex(where: { $0.category == "mode" || $0.id == "mode" }) {
                configOptions[index].currentValue = mode
            }
        case "config_option_update":
            applyConfigOptions(update["configOptions"])
        case "session_info_update":
            if let title = update["title"]?.string, !title.isEmpty { self.title = String(title.prefix(40)) }
        default:
            break
        }
    }

    private func appendChunk(_ kind: TranscriptEntry.Kind, _ text: String?) {
        guard let text, !text.isEmpty else { return }
        if let last = entries.last, last.kind == kind {
            last.text += text
        } else {
            entries.append(TranscriptEntry(kind: kind, text: text))
        }
    }

    @discardableResult
    private func applyToolCall(_ update: JSONValue) -> TranscriptEntry? {
        guard let id = update["toolCallId"]?.string else { return nil }
        let entry: TranscriptEntry
        if let existing = toolEntries[id] {
            entry = existing
        } else {
            entry = TranscriptEntry(kind: .tool)
            entry.toolCallID = id
            toolEntries[id] = entry
            entries.append(entry)
        }
        if let title = update["title"]?.string { entry.title = title }
        if let kind = update["kind"]?.string { entry.toolKind = kind }
        if let command = update["rawInput"]?["command"]?.string { entry.command = command }
        if let contents = update["content"]?.array {
            let parsed = contents.compactMap(parseToolContent)
            if !parsed.isEmpty || entry.contents.isEmpty { entry.contents = parsed }
        }
        if let delta = update["_meta"]?["terminal_output_delta"]?["data"]?.string {
            entry.output += delta
            if entry.output.count > 20_000 { entry.output = String(entry.output.suffix(20_000)) }
        }
        let wasRunning = entry.isRunning
        if let status = update["status"]?.string { entry.status = status }

        if wasRunning, !entry.isRunning, Self.mutatingKinds.contains(entry.toolKind) || entry.contents.contains(where: { if case .diff = $0 { true } else { false } }) {
            Task { await tracker?.refreshAgentChanges() }
        }
        return entry
    }

    private static let mutatingKinds: Set<String> = ["edit", "delete", "move", "execute", "other"]

    private func parseToolContent(_ json: JSONValue) -> ToolContent? {
        switch json["type"]?.string {
        case "content":
            if let text = json["content"]?["text"]?.string, !text.isEmpty { return .text(text) }
            return nil
        case "diff":
            guard let path = json["path"]?.string, let new = json["newText"]?.string else { return nil }
            return .diff(path: path, old: json["oldText"]?.string, new: new)
        default:
            return nil
        }
    }

    private func applyPlan(_ json: JSONValue?) {
        let items = (json?.array ?? []).compactMap { item -> PlanItem? in
            guard let content = item["content"]?.string else { return nil }
            return PlanItem(content: content, status: item["status"]?.string ?? "pending")
        }
        if let planEntry {
            planEntry.plan = items
        } else {
            let entry = TranscriptEntry(kind: .plan)
            entry.plan = items
            entries.append(entry)
            planEntry = entry
        }
    }

    private func applyConfigOptions(_ json: JSONValue?) {
        guard let array = json?.array else { return }
        configOptions = array.compactMap(ConfigOption.init)
            .filter { $0.category != nil && $0.choices.count > 1 && $0.id != "agent" }
    }

    private func applyLegacyModes(_ json: JSONValue?) {
        guard let modes = json?["availableModes"]?.array, !modes.isEmpty else { return }
        usesLegacyModes = true
        configOptions = [ConfigOption(
            id: "mode",
            name: "Mode",
            category: "mode",
            currentValue: json?["currentModeId"]?.string ?? "",
            choices: modes.compactMap { mode in
                guard let id = mode["id"]?.string else { return nil }
                return ConfigOption.Choice(value: id, name: mode["name"]?.string ?? id, description: mode["description"]?.string)
            }
        )]
    }

    // MARK: Client-side methods (agent → Orbit)

    private func handleRequest(_ method: String, _ params: JSONValue, _ reply: CheckedContinuation<JSONValue, Error>) {
        switch method {
        case "session/request_permission":
            let options = (params["options"]?.array ?? []).compactMap { option -> PermissionRequest.Option? in
                guard let id = option["optionId"]?.string else { return nil }
                return .init(id: id, name: option["name"]?.string ?? id, kind: option["kind"]?.string ?? "allow_once")
            }
            let request = PermissionRequest(options: options, continuation: reply)
            var toolCall = params["toolCall"] ?? [:]
            if toolCall["status"] == nil, case .object(var object) = toolCall {
                object["status"] = "pending"
                toolCall = .object(object)
            }
            let entry = applyToolCall(toolCall) ?? {
                let entry = TranscriptEntry(kind: .tool)
                entry.title = "Permission requested"
                entries.append(entry)
                return entry
            }()
            entry.permission = request
            pendingPermissions.append(request)

        case "fs/read_text_file":
            guard let path = params["path"]?.string else {
                reply.resume(throwing: JSONRPCError(code: -32602, message: "Missing path"))
                return
            }
            guard var text = workspace.documents.currentText(of: workspace.resolve(path: path)) else {
                reply.resume(throwing: JSONRPCError(code: -32002, message: "File not found: \(path)"))
                return
            }
            if let line = params["line"]?.int, line > 0 || params["limit"] != nil {
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                let start = max(0, min(lines.count, line - 1))
                let limit = params["limit"]?.int ?? lines.count
                text = lines[start..<min(lines.count, start + limit)].joined(separator: "\n")
            }
            reply.resume(returning: ["content": .string(text)])

        case "fs/write_text_file":
            guard let path = params["path"]?.string, let content = params["content"]?.string else {
                reply.resume(throwing: JSONRPCError(code: -32602, message: "Missing path or content"))
                return
            }
            let url = workspace.resolve(path: path)
            tracker?.recordBaseline(workspace.documents.currentText(of: url), for: url)
            do {
                try workspace.documents.write(content, to: url)
                workspace.fileSystemDidChange()
                reply.resume(returning: .null)
            } catch {
                reply.resume(throwing: JSONRPCError(code: -32603, message: error.localizedDescription))
            }

        default:
            reply.resume(throwing: JSONRPCError.methodNotFound(method))
        }
    }

    // MARK: Helpers

    private func notice(_ text: String, isError: Bool = false) {
        let entry = TranscriptEntry(kind: .notice, text: text)
        entry.isError = isError
        entries.append(entry)
    }

    private func describe(_ error: Error) -> String {
        let message = (error as? JSONRPCError)?.message ?? error.localizedDescription
        if message.localizedCaseInsensitiveContains("auth"), let hint = provider.loginHint {
            return "\(message)\n\(hint)"
        }
        if let rpc = error as? JSONRPCError, rpc.code == JSONRPCError.processExited.code, !stderrTail.isEmpty {
            return "\(message)\n" + stderrTail.split(separator: "\n").suffix(3).joined(separator: "\n")
        }
        return message
    }
}
