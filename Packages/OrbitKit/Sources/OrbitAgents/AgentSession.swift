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
    /// The project folder the session belongs to.
    let project: URL
    /// Works in its own copy of the project (see `AgentIsolation`).
    let isIsolated: Bool
    private(set) var isolatedCopy: IsolatedCopy? { didSet { if isolatedCopy != oldValue { onChange() } } }
    /// Project files the agent changed in its copy that aren't in the project yet.
    private(set) var unappliedChanges: [URL] = []
    private(set) var isApplying = false
    /// Where the agent runs: its copy when isolated.
    var cwd: URL { isolatedCopy?.directory ?? project }
    var title: String { didSet { if title != oldValue { onChange() } } }
    private(set) var status: Status = .dormant
    /// Called when what's worth remembering changed (id, title, activity).
    @ObservationIgnored var onChange: () -> Void = {}
    /// Called when a turn ends or the agent waits for the user (system notifications).
    @ObservationIgnored var onAttention: (AgentAttention) -> Void = { _ in }
    /// Called after each turn with the files it left changes in (the store tells chats apart by them).
    @ObservationIgnored var onTurnFiles: ([URL]) -> Void = { _ in }
    /// Called with the agent's options whenever they change (the store keeps its model list).
    @ObservationIgnored var onConfigOptions: ([ConfigOption]) -> Void = { _ in }
    /// Option values (by category) to set once the agent is up: the user's last choices.
    var initialValues: [String: String] = [:]
    private(set) var entries: [TranscriptEntry] = []
    private(set) var configOptions: [ConfigOption] = []
    private(set) var slashCommands: [SlashCommand] = []
    /// When the running turn began, for its timer.
    private(set) var turnStartedAt: Date?
    private(set) var usage = SessionUsage()
    var draft = ""
    private(set) var attachments: [PromptAttachment] = []
    private var promptCapabilities = PromptCapabilities()
    private var checkpoints: [MessageCheckpoint]
    private static let checkpointLimit = 100
    /// Told to the agent with the next message: its history still has edits a restore undid.
    private var restoreNote: String?

    private var client: ACPClient?
    private var sessionID: String? { didSet { if sessionID != oldValue { onChange() } } }
    /// The conversation to load instead of starting a new one.
    private let restoredID: String?
    /// Until the first message (or the agent) names the conversation, the tab says "New Chat".
    private var isTitled: Bool
    private var updatedAt = Date()
    /// While the agent replays a loaded conversation: nothing in it is new.
    private var isReplaying = false
    /// A reopened conversation until the agent has replayed it: the transcript
    /// waits for all of it so it opens at the end instead of scrolling there.
    private(set) var isLoadingHistory: Bool
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
    /// Turns are tracked for inline review only when the agent edits the project itself;
    /// a copy's changes arrive through Apply.
    private var projectTracker: ChangeTracking? { isIsolated ? nil : tracker }
    private var isolation: AgentIsolation? { services.resolve(AgentIsolation.self) }
    private var terminalHost: AgentTerminalHosting? { services.resolve(AgentTerminalHosting.self) }

    init(
        provider: AgentProvider,
        project: URL,
        isolated: Bool = false,
        restoring saved: SavedSession? = nil,
        workspace: Workspace,
        services: ServiceRegistry,
        environment: @escaping @MainActor () async -> [String: String]
    ) {
        self.provider = provider
        self.project = project
        // A restored copy that was deleted meanwhile: the session goes on in the project.
        let copy = saved?.isolated.flatMap { FileManager.default.fileExists(atPath: $0.directory.path) ? $0 : nil }
        isolatedCopy = copy
        isIsolated = saved.map { _ in copy != nil } ?? isolated
        lostCopy = saved?.isolated != nil && copy == nil
        self.workspace = workspace
        self.services = services
        self.environment = environment
        restoredID = saved?.sessionID
        title = saved?.title ?? "New Chat"
        isTitled = saved != nil
        isLoadingHistory = saved != nil
        checkpoints = saved?.checkpoints ?? []
        if let saved {
            sessionID = saved.sessionID
            updatedAt = saved.updatedAt
        }
    }

    private let lostCopy: Bool

    /// What it takes to open this conversation again later.
    var saved: SavedSession? {
        sessionID.map {
            SavedSession(providerID: provider.id, sessionID: $0, title: title, cwd: project.path, updatedAt: updatedAt, isolated: isolatedCopy,
                         checkpoints: checkpoints.isEmpty ? nil : checkpoints)
        }
    }

    var isBusy: Bool { status == .working || status == .starting }
    var hasFailed: Bool { if case .failed = status { true } else { false } }
    /// A new chat nothing was sent in yet: not worth remembering, and free to swap for another agent.
    var isEmptyChat: Bool { restoredID == nil && !entries.contains { $0.kind == .user } }
    var hasPendingPermission: Bool { pendingPermissions.contains(where: \.isPending) }
    /// The request the keyboard answers; the others wait their turn.
    var firstPendingPermission: PermissionRequest? { pendingPermissions.first(where: \.isPending) }

    // MARK: Lifecycle

    func start() async {
        guard status == .dormant else { return }
        status = .starting
        if lostCopy { notice("This session's isolated copy was deleted; it continues in the project.", isError: true) }
        if isIsolated, isolatedCopy == nil {
            guard let isolation else {
                status = .failed("Isolated sessions need the Change Review plugin.")
                return
            }
            do {
                isolatedCopy = try await isolation.makeCopy(of: project)
            } catch {
                status = .failed("Couldn't make an isolated copy of the project: \(error.localizedDescription)")
                return
            }
        }
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
            let mcpServers = mcpServers(environment: env, capabilities: info["agentCapabilities"]?["mcpCapabilities"])
            var session: JSONValue?
            if let restoredID {
                session = await load(restoredID, with: client, mcpServers: mcpServers, canLoad: info["agentCapabilities"]?["loadSession"]?.bool == true)
                continuation.yield(.replayFinished)
            }
            if session == nil {
                session = try await client.newSession(cwd: cwd, mcpServers: mcpServers)
                sessionID = session?["sessionId"]?.string
            }
            applyConfigOptions(session?["configOptions"])
            if configOptions.isEmpty { applyLegacyModes(session?["modes"]) }
            status = .ready
            applyInitialValues()
            await refreshUnappliedChanges()
        } catch {
            isLoadingHistory = false
            status = .failed(describe(error))
        }
    }

    /// The MCP servers from Orbit's settings (D86) this agent can take. Problems
    /// show in Settings → Agents, not here: a notice would hide the new-chat screen.
    private func mcpServers(environment: [String: String], capabilities: JSONValue?) -> [JSONValue] {
        let http = capabilities?["http"]?.bool == true, sse = capabilities?["sse"]?.bool == true
        return MCPServer.load(project: project).servers.compactMap { $0.acp(environment: environment, http: http, sse: sse) }
    }

    /// Nil when the conversation can't be opened again; a new one starts instead.
    private func load(_ id: String, with client: ACPClient, mcpServers: [JSONValue], canLoad: Bool) async -> JSONValue? {
        guard canLoad else {
            notice("\(provider.name) can't reopen earlier conversations; this is a new one.", isError: true)
            sessionID = nil
            return nil
        }
        isReplaying = true
        do {
            return try await client.loadSession(sessionID: id, cwd: cwd, mcpServers: mcpServers)
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

    var canSend: Bool { status == .ready && hasDraft }
    private var hasDraft: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }

    // MARK: Queue

    /// A message written while the agent works, sent when its turn ends (D88).
    struct QueuedMessage: Identifiable {
        let id = UUID()
        var text: String
        var attachments: [PromptAttachment]
    }

    private(set) var queue: [QueuedMessage] = []
    /// The queue waits (a stopped or failed turn) until a message is sent by hand.
    var isQueuePaused: Bool { !queue.isEmpty && status == .ready }
    private var sendsQueueAfterStop = false

    /// Return in the composer: sends, or queues while the agent works.
    func submit() {
        guard status == .working, hasDraft else { return send() }
        queue.append(QueuedMessage(text: draft.trimmingCharacters(in: .whitespacesAndNewlines), attachments: attachments))
        draft = ""
        attachments = []
    }

    func removeQueued(_ id: QueuedMessage.ID) {
        queue.removeAll { $0.id == id }
    }

    /// Back into the composer to edit (when it's empty).
    func editQueued(_ id: QueuedMessage.ID) {
        guard !hasDraft, let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let message = queue.remove(at: index)
        draft = message.text
        attachments = message.attachments
    }

    /// Sends it next: stops the running turn first.
    func sendQueuedNow(_ id: QueuedMessage.ID) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue.insert(queue.remove(at: index), at: 0)
        if status == .working {
            sendsQueueAfterStop = true
            stop()
        } else {
            sendNextQueued()
        }
    }

    private func sendNextQueued() {
        guard status == .ready, !queue.isEmpty else { return }
        let message = queue.removeFirst()
        send(text: message.text, attachments: message.attachments)
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
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines), shown = attachments
        draft = ""
        attachments = []
        send(text: text, attachments: shown)
    }

    private func send(text: String, attachments shown: [PromptAttachment]) {
        guard status == .ready, let client, let sessionID else { return }
        let attached = shown.map(intoCopy)
        let entry = TranscriptEntry(kind: .user, text: text)
        entry.attachments = shown
        entries.append(entry)
        updatedAt = Date()
        let summary = text.isEmpty ? shown.map(\.label).joined(separator: ", ") : text
        if !isTitled {
            isTitled = true
            title = String(summary.prefix(40))
        } else {
            onChange()
        }
        var content = PromptBuilder.content(text: text, attachments: attached, capabilities: promptCapabilities) { url in
            workspace.documents.currentText(of: url)
        }
        if let restoreNote {
            content.insert(["type": "text", "text": .string(restoreNote)], at: 0)
            self.restoreNote = nil
        }
        status = .working
        planEntry = nil
        let startedAt = Date()
        turnStartedAt = startedAt
        let before = Dictionary(pendingStats(), uniquingKeysWith: { first, _ in first })

        Task {
            if let checkpoint = await projectTracker?.beginAgentTurn() {
                entry.checkpoint = checkpoint
                checkpoints.append(MessageCheckpoint(message: text, checkpoint: checkpoint))
                checkpoints = Array(checkpoints.suffix(Self.checkpointLimit))
                onChange()
            }
            var attention: AgentAttention?
            var continuesQueue = false
            do {
                let result = try await client.prompt(sessionID: sessionID, content: content)
                usage.apply(turn: result["usage"])
                switch result["stopReason"]?.string {
                case "max_tokens": notice("Stopped: output token limit reached.")
                case "max_turn_requests": notice("Stopped: turn request limit reached.")
                case "refusal": notice("The agent declined to continue.", isError: true)
                case "cancelled": notice("Stopped.")
                default: break
                }
                let stopReason = result["stopReason"]?.string
                continuesQueue = stopReason != "cancelled" && stopReason != "refusal"
                if stopReason != "cancelled" {
                    let reply = entries.last { $0.kind == .agent }?.text ?? ""
                    attention = .finished(summary: String(reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)))
                }
            } catch {
                notice(describe(error), isError: true)
                attention = .failed(describe(error))
            }
            await projectTracker?.endAgentTurn()
            turnStartedAt = nil
            if status == .working {
                status = .ready
                summarizeTurn(duration: Date().timeIntervalSince(startedAt), before: before)
            }
            let sendsNow = sendsQueueAfterStop
            sendsQueueAfterStop = false
            if continuesQueue || sendsNow, !queue.isEmpty, status == .ready {
                sendNextQueued()
            } else if let attention {
                onAttention(attention)
            }
            await refreshUnappliedChanges()
        }
    }

    func stop() {
        guard status == .working, let client, let sessionID else { return }
        for request in pendingPermissions { request.cancel() }
        pendingPermissions.removeAll()
        client.cancel(sessionID: sessionID)
    }

    /// Carries the composer over when a new chat changes agent.
    func takeDraft(from other: AgentSession) {
        draft = other.draft
        attachments = other.attachments
    }

    func setConfigOption(_ option: ConfigOption, value: String) {
        guard let client, let sessionID else {
            if let category = option.category { initialValues[category] = value }
            return
        }
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
            matchCheckpoints()
            isLoadingHistory = false
        case .exited(let code, let stderr):
            stderrTail = stderr
            for request in pendingPermissions { request.cancel() }
            pendingPermissions.removeAll()
            isLoadingHistory = false
            if case .failed = status { return }
            let detail = stderr.split(separator: "\n").suffix(3).joined(separator: "\n")
            let wasWorking = status == .working
            status = .failed(code == 0 ? "Agent exited." : "Agent exited with code \(code).\n\(detail)")
            if wasWorking { onAttention(.failed(code == 0 ? "The agent exited." : "The agent exited with code \(code).")) }
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
            slashCommands = (update["availableCommands"]?.array ?? []).compactMap(SlashCommand.init)
        case "current_mode_update":
            if let mode = update["currentModeId"]?.string,
               let index = configOptions.firstIndex(where: { $0.category == "mode" || $0.id == "mode" }) {
                configOptions[index].currentValue = mode
            }
        case "usage_update":
            usage.apply(update: update)
        case "config_option_update":
            applyConfigOptions(update["configOptions"])
        case "session_info_update":
            if let title = update["title"]?.string, !title.isEmpty {
                isTitled = true
                self.title = String(title.prefix(40))
            }
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
                if entry.output.utf8.count > 24_000 { entry.output = String(entry.output.suffix(20_000)) }
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
            Task {
                await projectTracker?.refreshAgentChanges()
                await refreshUnappliedChanges()
            }
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
            // A single model is still worth showing (Grok Build has one).
            .filter { $0.category != nil && ($0.choices.count > 1 || $0.category == "model") && $0.id != "agent" }
        onConfigOptions(configOptions)
    }

    private func applyInitialValues() {
        for (category, value) in initialValues {
            guard let option = configOptions.first(where: { $0.category == category }),
                  option.currentValue != value, option.choices.contains(where: { $0.value == value }) else { continue }
            setConfigOption(option, value: value)
        }
        initialValues = [:]
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
        onConfigOptions(configOptions)
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
            onAttention(.permission(entry.title.isEmpty ? "Permission requested" : entry.title))

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
            projectTracker?.recordBaseline(workspace.documents.currentText(of: url), for: url)
            do {
                try workspace.documents.write(content, to: url)
                if !isIsolated { workspace.fileSystemDidChange() }
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

    // MARK: Isolated copy

    func refreshUnappliedChanges() async {
        guard let copy = isolatedCopy, let isolation else { return }
        unappliedChanges = await isolation.unappliedChanges(in: copy)
    }

    /// Brings the copy's changes into the project, where they show inline for review.
    func applyIsolatedChanges() {
        guard let copy = isolatedCopy, let isolation, !isApplying else { return }
        isApplying = true
        Task {
            let result = await isolation.apply(copy)
            isApplying = false
            let names = { (urls: [URL]) in urls.map { self.workspace.relativePath($0) }.joined(separator: "\n") }
            if !result.applied.isEmpty {
                let count = result.applied.count
                notice("Applied \(count) file\(count == 1 ? "" : "s") to the project; review the changes in the editor.")
            }
            if !result.conflicts.isEmpty {
                notice("Not applied, changed in the project on the same lines:\n" + names(result.conflicts), isError: true)
            }
            if result.applied.isEmpty, result.conflicts.isEmpty { notice("The project already has these changes.") }
            await refreshUnappliedChanges()
        }
    }

    func discardIsolatedCopy() {
        guard let copy = isolatedCopy else { return }
        isolation?.discard(copy)
    }

    /// Attachments point at project files; the agent should read its own copy of them.
    private func intoCopy(_ attachment: PromptAttachment) -> PromptAttachment {
        guard let copy = isolatedCopy else { return attachment }
        func map(_ url: URL) -> URL {
            let root = project.standardizedFileURL.path + "/"
            guard url.path.hasPrefix(root) else { return url }
            return copy.directory.appendingPathComponent(String(url.path.dropFirst(root.count)))
        }
        switch attachment {
        case .file(let url): return .file(map(url))
        case .selection(var selection):
            selection.url = map(selection.url)
            return .selection(selection)
        case .image: return attachment
        }
    }

    // MARK: Helpers

    // MARK: Restore points

    var canRestore: Bool { projectTracker != nil && status != .working }

    /// Puts the project's files back to how they were before `entry` was sent.
    func restore(to entry: TranscriptEntry) {
        guard let checkpoint = entry.checkpoint, canRestore, let tracker = projectTracker else { return }
        Task {
            do {
                let files = try await tracker.restore(checkpoint)
                guard !files.isEmpty else {
                    notice("The files already match how they were before that message.")
                    return
                }
                let count = files.count
                notice("Restored \(count) file\(count == 1 ? "" : "s") to before that message; undo any change in the editor.")
                let quoted = entry.text.count > 200 ? String(entry.text.prefix(200)) + "…" : entry.text
                restoreNote = "[Orbit: the user restored the project's files to how they were before their message \"\(quoted)\". "
                    + "Changes made after it, yours included, are gone; check files before relying on earlier edits.]"
            } catch {
                notice("Couldn't restore: \(error.localizedDescription)", isError: true)
            }
        }
    }

    /// A reopened conversation's messages get their restore points back.
    private func matchCheckpoints() {
        var remaining = checkpoints[...]
        for entry in entries where entry.kind == .user {
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let index = remaining.firstIndex(where: { $0.message == text }) else { continue }
            entry.checkpoint = remaining[index].checkpoint
            remaining = remaining[(index + 1)...]
        }
    }

    /// Long turns and turns that changed files end with a line saying so.
    private static let summaryThreshold: TimeInterval = 30

    private func pendingStats() -> [(URL, DiffStats)] {
        guard let tracker = projectTracker else { return [] }
        return tracker.changedFiles.map { url in
            let stats = tracker.stats(for: url)
            return (url, DiffStats(added: stats.added, removed: stats.removed))
        }
    }

    private func summarizeTurn(duration: TimeInterval, before: [URL: DiffStats]) {
        let files = TurnActivity.changedFiles(before: before, after: pendingStats())
        if !files.isEmpty { onTurnFiles(files) }
        guard !files.isEmpty || duration >= Self.summaryThreshold else { return }
        let entry = TranscriptEntry(kind: .summary)
        entry.duration = duration
        entry.changedFiles = files
        entries.append(entry)
    }

    /// A file from a tool call, in the editor: at its first unreviewed change when it has one.
    func reveal(path: String) {
        let url = workspace.resolve(path: path)
        if let tracker = projectTracker, tracker.hasChanges(url) {
            tracker.openReview(for: url)
        } else if FileManager.default.fileExists(atPath: url.path) {
            workspace.openFile(url)
        }
    }

    /// Unreviewed changes go through the project's tracker; an isolated session has none until Apply.
    var reviewTracker: ChangeTracking? { projectTracker }

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
