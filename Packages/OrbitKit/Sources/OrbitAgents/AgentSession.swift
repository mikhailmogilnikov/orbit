import Foundation
import OrbitACP
import OrbitAPI

/// Everything the agent process sends, funnelled through one ordered stream so
/// chunks, tool calls and permission requests are applied in arrival order.
private enum AgentEvent: Sendable {
    case notification(String, JSONValue)
    case request(String, JSONValue, CheckedContinuation<JSONValue, Error>)
    case exited(Int32, String)
    /// Sent after `session/load` returns: everything before it was history.
    case replayFinished
}

@MainActor
@Observable
final class AgentSession: Identifiable {
    enum Status: Equatable {
        /// A restored tab whose agent isn't running yet; it starts when shown.
        case dormant
        case starting, ready, working
        case failed(String)
    }

    let id = UUID()
    let provider: AgentProvider
    let cwd: URL
    var title: String { didSet { if title != oldValue { onChange() } } }
    private(set) var status: Status = .dormant
    /// Called when what's worth remembering changed (id, title, activity).
    @ObservationIgnored var onChange: () -> Void = {}
    private(set) var entries: [TranscriptEntry] = []
    private(set) var configOptions: [ConfigOption] = []
    private(set) var slashCommands: [String] = []
    var draft = ""
    private(set) var attachments: [PromptAttachment] = []
    private var promptCapabilities = PromptCapabilities()

    private var client: ACPClient?
    private var sessionID: String? { didSet { if sessionID != oldValue { onChange() } } }
    /// The conversation to load instead of starting a new one.
    private let restoredID: String?
    private var updatedAt = Date()
    /// While the agent replays a loaded conversation: nothing in it is new.
    private var isReplaying = false
    private var eventTask: Task<Void, Never>?
    private var toolEntries: [String: TranscriptEntry] = [:]
    private var planEntry: TranscriptEntry?
    private var pendingPermissions: [PermissionRequest] = []
    private var terminals: [String: AgentTerminal] = [:]
    private var stderrTail = ""
    /// Whether the agent exposes modes through `modes` rather than `configOptions`.
    private var usesLegacyModes = false

    private let workspace: Workspace
    private let services: ServiceRegistry
    private let environment: @MainActor () async -> [String: String]

    private var tracker: ChangeTracking? { services.resolve(ChangeTracking.self) }
    private var terminalHost: AgentTerminalHosting? { services.resolve(AgentTerminalHosting.self) }

    init(
        provider: AgentProvider,
        cwd: URL,
        restoring saved: SavedSession? = nil,
        workspace: Workspace,
        services: ServiceRegistry,
        environment: @escaping @MainActor () async -> [String: String]
    ) {
        self.provider = provider
        self.cwd = cwd
        self.workspace = workspace
        self.services = services
        self.environment = environment
        restoredID = saved?.sessionID
        title = saved?.title ?? provider.name
        if let saved {
            sessionID = saved.sessionID
            updatedAt = saved.updatedAt
        }
    }

    /// What it takes to open this conversation again later.
    var saved: SavedSession? {
        sessionID.map { SavedSession(providerID: provider.id, sessionID: $0, title: title, cwd: cwd.path, updatedAt: updatedAt) }
    }

    var isBusy: Bool { status == .working || status == .starting }
    var hasPendingPermission: Bool { pendingPermissions.contains(where: \.isPending) }

    // MARK: Lifecycle

    func start() async {
        guard status == .dormant else { return }
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
            let info = try await client.initialize(terminal: terminalHost != nil)
            promptCapabilities = PromptCapabilities(info["agentCapabilities"]?["promptCapabilities"])
            var session: JSONValue?
            if let restoredID {
                session = await load(restoredID, with: client, canLoad: info["agentCapabilities"]?["loadSession"]?.bool == true)
                continuation.yield(.replayFinished)
            }
            if session == nil {
                session = try await client.newSession(cwd: cwd)
                sessionID = session?["sessionId"]?.string
            }
            applyConfigOptions(session?["configOptions"])
            if configOptions.isEmpty { applyLegacyModes(session?["modes"]) }
            status = .ready
        } catch {
            status = .failed(describe(error))
        }
    }

    /// Nil when the conversation can't be opened again; a new one starts instead.
    private func load(_ id: String, with client: ACPClient, canLoad: Bool) async -> JSONValue? {
        guard canLoad else {
            notice("\(provider.name) can't reopen earlier conversations; this is a new one.", isError: true)
            sessionID = nil
            return nil
        }
        isReplaying = true
        do {
            return try await client.loadSession(sessionID: id, cwd: cwd)
        } catch {
            notice("Couldn't reopen this conversation: \(describe(error))\nThis is a new one.", isError: true)
            sessionID = nil
            return nil
        }
    }

    func shutdown() {
        for request in pendingPermissions { request.cancel() }
        for terminal in terminals.values { terminal.release() }
        terminals.removeAll()
        client?.terminate()
        client = nil
        eventTask?.cancel()
    }

    // MARK: Prompting

    var canSend: Bool {
        status == .ready && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    func attach(_ attachment: PromptAttachment) {
        if case .image(let data, _) = attachment {
            guard data.count <= PromptAttachment.maxImageBytes else {
                notice("That image is over \(PromptAttachment.maxImageBytes >> 20) MB; agents won't take it.", isError: true)
                return
            }
            // Known only once the agent started; a dormant or starting session gets the benefit of the doubt.
            if status == .ready, !promptCapabilities.image {
                notice("\(provider.name) doesn't accept images.", isError: true)
                return
            }
        }
        guard !attachments.contains(where: { $0.id == attachment.id }) else { return }
        attachments.append(attachment)
    }

    func detach(_ attachment: PromptAttachment) {
        attachments.removeAll { $0.id == attachment.id }
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, let client, let sessionID else { return }
        let attached = attachments
        draft = ""
        attachments = []
        let entry = TranscriptEntry(kind: .user, text: text)
        entry.attachments = attached
        entries.append(entry)
        updatedAt = Date()
        let summary = text.isEmpty ? attached.map(\.label).joined(separator: ", ") : text
        if title == provider.name { title = String(summary.prefix(40)) } else { onChange() }
        let content = PromptBuilder.content(text: text, attachments: attached, capabilities: promptCapabilities) { url in
            workspace.documents.currentText(of: url)
        }
        status = .working
        planEntry = nil

        Task {
            await tracker?.beginAgentTurn()
            do {
                let result = try await client.prompt(sessionID: sessionID, content: content)
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
        case .replayFinished:
            isReplaying = false
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
        case "user_message_chunk":
            // Only history replays the user's own messages; live ones are already shown.
            if isReplaying { appendChunk(.user, update["content"]?["text"]?.string) }
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
        let meta = update["_meta"]
        // Agents also read and list files through the shell; only real commands get a terminal tab.
        if !isReplaying, entry.toolKind == "execute", let info = meta?["terminal_info"], let id = info["terminal_id"]?.string,
           terminals[id] == nil, let host = terminalHost {
            let directory = info["cwd"]?.string.map { workspace.resolve(path: $0) } ?? cwd
            let command = entry.command ?? (entry.title.isEmpty ? "command" : entry.title)
            terminals[id] = host.display(AgentTerminalRequest(command: command, environment: [:], directory: directory))
            entry.terminalID = id
        }
        if let contents = update["content"]?.array {
            let parsed = contents.compactMap(parseToolContent)
            if !parsed.isEmpty || entry.contents.isEmpty { entry.contents = parsed }
            if let id = contents.lazy.compactMap({ $0["type"]?.string == "terminal" ? $0["terminalId"]?.string : nil }).first {
                entry.terminalID = id
            }
        }
        if let id = entry.terminalID, entry.terminal == nil { entry.terminal = terminals[id] }
        if let delta = meta?["terminal_output_delta"]?["data"]?.string {
            if let terminal = entry.terminal, !terminal.ownsProcess {
                terminal.append(delta)
            } else {
                entry.output += delta
                if entry.output.count > 20_000 { entry.output = String(entry.output.suffix(20_000)) }
            }
        }
        if let exit = meta?["terminal_exit"], let terminal = entry.terminal, !terminal.ownsProcess {
            terminal.finish(TerminalExitStatus(exitCode: exit["exit_code"]?.int, signal: exit["signal"]?.string))
        }
        let wasRunning = entry.isRunning
        if let status = update["status"]?.string { entry.status = status }
        // Not every adapter reports an exit for the commands it runs.
        if !entry.isRunning, let terminal = entry.terminal, !terminal.ownsProcess { terminal.finish(TerminalExitStatus()) }

        if wasRunning, !entry.isRunning, !isReplaying, Self.mutatingKinds.contains(entry.toolKind) || entry.contents.contains(where: { if case .diff = $0 { true } else { false } }) {
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

        case "terminal/create":
            createTerminal(params, reply)

        case "terminal/output":
            guard let terminal = lookupTerminal(params, reply) else { return }
            let (output, truncated) = terminal.currentOutput()
            var result: [String: JSONValue] = ["output": .string(output), "truncated": .bool(truncated)]
            if let status = terminal.exitStatus { result["exitStatus"] = Self.json(status) }
            reply.resume(returning: .object(result))

        case "terminal/wait_for_exit":
            guard let terminal = lookupTerminal(params, reply) else { return }
            Task {
                let status = await terminal.waitForExit()
                reply.resume(returning: Self.json(status))
            }

        case "terminal/kill":
            guard let terminal = lookupTerminal(params, reply) else { return }
            terminal.kill()
            reply.resume(returning: [:])

        case "terminal/release":
            guard let terminal = lookupTerminal(params, reply) else { return }
            terminals[terminal.id] = nil
            terminal.release()
            reply.resume(returning: [:])

        default:
            reply.resume(throwing: JSONRPCError.methodNotFound(method))
        }
    }

    // MARK: Terminals

    private func createTerminal(_ params: JSONValue, _ reply: CheckedContinuation<JSONValue, Error>) {
        guard let host = terminalHost, let command = params["command"]?.string else {
            reply.resume(throwing: JSONRPCError(code: -32602, message: "Missing command"))
            return
        }
        let arguments = (params["args"]?.array ?? []).compactMap(\.string)
        var overrides: [String: String] = [:]
        for variable in params["env"]?.array ?? [] {
            if let name = variable["name"]?.string, let value = variable["value"]?.string { overrides[name] = value }
        }
        let directory = params["cwd"]?.string.map { workspace.resolve(path: $0) } ?? cwd
        let limit = params["outputByteLimit"]?.int
        Task {
            var env = await environment()
            // The command runs in a real terminal: a pager would wait for keys nobody presses.
            env["PAGER"] = "cat"
            env["GIT_PAGER"] = "cat"
            env.merge(overrides) { _, new in new }
            let terminal = host.run(AgentTerminalRequest(
                command: command,
                arguments: arguments,
                environment: env,
                directory: directory,
                outputByteLimit: limit
            ))
            terminals[terminal.id] = terminal
            // The tool call that shows it may have arrived first.
            for entry in toolEntries.values where entry.terminalID == terminal.id { entry.terminal = terminal }
            reply.resume(returning: ["terminalId": .string(terminal.id)])
        }
    }

    private func lookupTerminal(_ params: JSONValue, _ reply: CheckedContinuation<JSONValue, Error>) -> AgentTerminal? {
        guard let id = params["terminalId"]?.string, let terminal = terminals[id] else {
            reply.resume(throwing: JSONRPCError(code: -32602, message: "Unknown terminal"))
            return nil
        }
        return terminal
    }

    private static func json(_ status: TerminalExitStatus) -> JSONValue {
        [
            "exitCode": status.exitCode.map { JSONValue.number(Double($0)) } ?? .null,
            "signal": status.signal.map { JSONValue.string($0) } ?? .null,
        ]
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
