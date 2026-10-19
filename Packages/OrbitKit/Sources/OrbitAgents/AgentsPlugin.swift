import AppKit
import OrbitACP
import OrbitAPI
import OrbitUI
import SwiftUI

public final class AgentsPlugin: OrbitPlugin {
    public static let manifest = PluginManifest(
        id: "orbit.agents",
        name: "Agents",
        summary: "Claude Code, Codex and any ACP agent, side by side.",
        systemImage: "sparkles"
    )

    private var store: AgentStore?
    private var completion: AgentCompletionService?
    private var tasks: AgentTaskService?

    public init() {}

    public func activate(_ context: PluginContext) {
        let store = AgentStore(context: context)
        self.store = store
        let ui = context.ui
        let completion = AgentCompletionService(store: store)
        self.completion = completion
        context.services.register(AgentCompletion.self, completion)
        let tasks = AgentTaskService(store: store, ui: ui)
        self.tasks = tasks
        context.services.register(AgentTasks.self, tasks)
        context.services.register(ReviewComments.self, store.reviewComments)

        ui.addSettingsPane(SettingsPane(
            id: "agents", title: "Agents", systemImage: "sparkles", tint: .indigo, group: .agents, order: 0,
            summary: "The agent new chats start with, and the agents you have.",
            keywords: ["claude", "codex", "gemini", "cursor", "install", "registry", "default", "isolated", "copy", "custom", "acp", "login", "awake", "sleep", "update"]
        ) {
            AgentsSettingsPane(store: store)
        })
        ui.addSettingsPane(SettingsPane(
            id: "mcp", title: "MCP Servers", systemImage: "server.rack", tint: .cyan, group: .agents, order: 10,
            summary: "Tools every agent gets in new chats.",
            keywords: ["mcp", "tools", "servers", "model context protocol", ".mcp.json"]
        ) {
            MCPServersPane(store: store)
        })
        ui.addSettingsPane(SettingsPane(
            id: "notifications", title: "Notifications", systemImage: "bell.badge.fill", tint: .red, group: .app, order: 2,
            summary: "When an agent finishes or needs you while Orbit is in the background.",
            keywords: ["notify", "notification", "sound", "dock", "badge", "alert"]
        ) {
            NotificationSettingsPane(store: store)
        })

        ui.addInspectorPanel(PanelContribution(id: "agents", title: "Agents", systemImage: "sparkles", order: 0) {
            AgentsPanel(store: store)
        })

        ui.addStatusItem(StatusItem(
            id: "agents.activity", placement: .leading, order: 0,
            // Any window's agents: the overview lists them all (D130).
            isVisible: {
                store.isOverviewShown || AgentDirectory.shared.workingCount > 0 || AgentDirectory.shared.waitingCount > 0
            }
        ) {
            AgentActivityStatus(store: store)
        })

        ui.addStatusItem(StatusItem(
            id: "agents.pendingChanges", placement: .leading, order: 10,
            isVisible: { store.changes?.changedFiles.isEmpty == false }
        ) {
            PendingChangesStatus(store: store) {
                store.isChangesExpanded = true
                ui.revealInspectorPanel("agents")
            }
        })

        // Like Cursor: ⌘L brings up the chat with the editor's selection attached.
        context.commands.register(OrbitCommand(
            id: "agents.focus",
            title: "Focus Agent Chat",
            category: "Agents",
            systemImage: "text.bubble",
            shortcut: KeyboardShortcut("l", modifiers: .command),
            editorMenu: EditorMenuPlacement(.agent, title: "Ask Agent About This")
        ) {
            ui.revealInspectorPanel("agents")
            if let selection = context.services.resolve(EditorSelectionProviding.self)?.selection {
                store.attachToChat(.selection(selection))
            }
            store.focusComposer()
        })

        context.commands.register(OrbitCommand(
            id: "agents.new",
            title: "New Agent Session",
            category: "Agents",
            systemImage: "plus.bubble",
            shortcut: KeyboardShortcut("n", modifiers: [.command, .shift]),
            isEnabled: { context.workspace.root != nil }
        ) {
            ui.revealInspectorPanel("agents")
            store.newChat()
        })

        context.commands.register(OrbitCommand(
            id: "agents.newIsolated",
            title: "New Isolated Agent Session",
            category: "Agents",
            systemImage: "square.on.square.dashed",
            shortcut: KeyboardShortcut("n", modifiers: [.command, .shift, .option]),
            isEnabled: { context.workspace.root != nil }
        ) {
            ui.revealInspectorPanel("agents")
            store.newChat(isolated: true)
        })

        store.registerProviderCommands()

        context.commands.register(OrbitCommand(
            id: "agents.sendReviewComments",
            title: "Send Review Comments to Agent",
            category: "Review",
            systemImage: "paperplane",
            isEnabled: { !store.reviewComments.comments.isEmpty }
        ) {
            ui.revealInspectorPanel("agents")
            store.sendReviewComments()
        })

        context.commands.register(OrbitCommand(
            id: "agents.overview",
            title: "Show All Agents",
            category: "Agents",
            systemImage: "rectangle.stack",
            shortcut: KeyboardShortcut("a", modifiers: [.command, .control])
        ) {
            store.isOverviewShown = true
        })

        context.commands.register(OrbitCommand(
            id: "agents.stop",
            title: "Stop Agent",
            category: "Agents",
            systemImage: "stop.circle",
            shortcut: KeyboardShortcut(".", modifiers: .command),
            isEnabled: { store.selected?.status == .working }
        ) {
            store.selected?.stop()
        })
    }

    public func deactivate() {
        store?.shutdown()
        completion?.shutdown()
    }
}

/// `AgentTasks`: a task from another plugin lands in a chat's composer.
@MainActor
final class AgentTaskService: AgentTasks {
    private let store: AgentStore
    private let ui: UIRegistry

    init(store: AgentStore, ui: UIRegistry) {
        self.store = store
        self.ui = ui
    }

    func attachFile(_ url: URL) {
        ui.revealInspectorPanel("agents")
        store.attachToChat(.from(fileURL: url))
        store.focusComposer()
    }

    func attachFileToNewChat(_ url: URL) {
        ui.revealInspectorPanel("agents")
        store.newChat()
        store.attachToChat(.from(fileURL: url))
        store.focusComposer()
    }

    func draftTask(_ prompt: String) -> Bool {
        ui.revealInspectorPanel("agents")
        store.newChat()
        guard let session = store.selected, session.isEmptyChat else { return false }
        session.draft = prompt
        store.focusComposer()
        return true
    }
}

@MainActor
@Observable
final class AgentStore {
    /// What's installed in `~/.orbit/agents`; reloaded after installing or removing one.
    private(set) var providers: [AgentProvider]
    let registry = AgentRegistry()
    private(set) var sessions: [AgentSession] = []
    /// Showing a restored tab starts its agent.
    var selectedID: AgentSession.ID? {
        didSet {
            guard selectedID != oldValue else { return }
            if let session = selected, session.status == .dormant { Task { await session.start() } }
            saveTabs()
        }
    }
    let history: SessionHistory
    /// The folder the tabs belong to; other folders' tabs are saved under their own.
    private var folder: URL?
    /// Bumped to ask the composer to take keyboard focus.
    private(set) var focusRequest = 0

    let workspace: Workspace
    let commands: CommandRegistry
    let ui: UIRegistry
    private let services: ServiceRegistry
    private var providerCommandIDs: [String] = []
    /// The changed-files list above the composer is expanded.
    var isChangesExpanded = false
    /// The status bar's all-agents popover (D130).
    var isOverviewShown = false
    /// Notes from the editor waiting to go to a chat (D125).
    let reviewComments = ReviewCommentStore()
    /// The chat whose turn last changed each file: with parallel chats, the list says whose change it is.
    private(set) var changeAuthors: [URL: AgentSession.ID] = [:]

    /// The open chat that last changed `url`, when there's more than one chat to tell apart.
    func author(of url: URL) -> AgentSession? {
        guard sessions.count > 1, let id = changeAuthors[url] else { return nil }
        return sessions.first { $0.id == id }
    }
    private let settings: PluginSettings
    private let environmentTask: Task<[String: String], Never>

    init(context: PluginContext) {
        workspace = context.workspace
        commands = context.commands
        ui = context.ui
        services = context.services
        settings = context.settings
        providers = AgentProvider.loadAll()
        history = SessionHistory(settings: context.settings)
        // Agents Orbit used to ship moved to the registry's ids (D52).
        preferredProviderID = context.settings.string("lastProvider").map(AgentProvider.migratedID)
        chosenIsolated = context.settings.bool("isolatedByDefault")
        notifies = !context.settings.bool("notificationsOff")
        lastValues = Self.migratingKeys(context.settings.data("lastOptions").flatMap { try? JSONDecoder().decode([String: [String: String]].self, from: $0) } ?? [:])
        models = Self.migratingKeys(context.settings.data("models").flatMap { try? JSONDecoder().decode([String: ConfigOption].self, from: $0) } ?? [:])
        // Resolve the login-shell environment up front; spawning agents needs it.
        environmentTask = Task.detached { await ShellEnvironment.resolve() }
        folder = workspace.root
        refreshMissing()
        migrateBuiltinAgents()
        restoreTabs()
        observeFolder()
        notifier.isEnabled = notifies
        notifier.playsSound = playsSound
        AgentWakeLock.shared.start()
        notifier.onOpen = { [weak self] id in
            guard let self, let session = sessions.first(where: { $0.id == id }) else { return }
            show(session)
        }
        notifier.onAnswer = { [weak self] id, request, answer in
            guard let self, let session = sessions.first(where: { $0.id == id }),
                  let permission = session.pendingPermission(request) else { return }
            if let option = permission.option(allow: answer != .deny, always: answer == .allowAlways) {
                permission.choose(option)
            } else {
                show(session)
            }
        }
        AgentDirectory.shared.add(self)
        reviewComments.onChange = { [weak self] in self?.saveReviewComments() }
        loadReviewComments()
        services.resolve(AgentIsolation.self)?.discardCopies(except: history.copiesInUse)
    }

    var fileIndex: ProjectFileIndex? { services.resolve(ProjectFileIndex.self) }
    var changes: ChangeTracking? { services.resolve(ChangeTracking.self) }
    var highlighter: SyntaxHighlighting? { services.resolve(SyntaxHighlighting.self) }

    /// Into the selected session, starting one if there's none.
    func attachToChat(_ attachment: PromptAttachment) {
        if selected == nil { newChat() }
        selected?.attach(attachment)
    }

    private func observeFolder() {
        withObservationTracking {
            _ = workspace.root
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.workspace.isClosed else { return }
                self.folderDidChange()
                self.observeFolder()
            }
        }
    }

    /// Another folder brings its own tabs back. Idle sessions of the previous
    /// folder close (they're saved and come back with it); busy ones keep working.
    private func folderDidChange() {
        guard workspace.root != folder else { return }
        folder = workspace.root
        for session in sessions where session.project.path != folder?.path && !session.isBusy && !session.hasPendingPermission {
            session.shutdown()
            sessions.removeAll { $0.id == session.id }
        }
        // Restore before touching the selection: saving tabs now would overwrite the new folder's.
        restoreTabs()
        loadReviewComments()
        if selected == nil, selectedID != nil { selectedID = nil }
        loadAgentHistory()
    }

    var selected: AgentSession? { sessions.first { $0.id == selectedID } }

    func environment() async -> [String: String] { await environmentTask.value }

    /// The last agent started; new sessions and helpers (commit messages) use it.
    var preferredProviderID: String? {
        didSet { settings.set(preferredProviderID, for: "lastProvider") }
    }

    /// Nil only when no agent is installed.
    var preferredProvider: AgentProvider? {
        projectProvider ?? availableProviders.first { $0.id == preferredProviderID } ?? availableProviders.first ?? providers.first
    }

    /// `"agents": { "default": "codex" }` in a settings file (D108): by id or name.
    var projectProvider: AgentProvider? {
        guard let wanted = workspace.settings.string("agents.default")?.lowercased() else { return nil }
        return availableProviders.first { $0.id.lowercased() == wanted || $0.name.lowercased() == wanted }
            ?? availableProviders.first { $0.id.lowercased().hasPrefix(wanted) || $0.name.lowercased().hasPrefix(wanted) }
    }

    /// Agents whose CLI isn't on the PATH; known once the shell environment is.
    private(set) var missing: Set<String> = []

    var availableProviders: [AgentProvider] { providers.filter { !missing.contains($0.id) } }

    let notifier = AgentNotifier()
    /// System notifications and the Dock badge when an agent finishes or waits in the background (D87).
    var notifies: Bool {
        didSet {
            settings.set(!notifies, for: "notificationsOff")
            notifier.isEnabled = notifies
        }
    }

    /// When notifications are off or not allowed (D153).
    var playsSound: Bool = UserDefaults.standard.object(forKey: "orbit.agents.sound") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(playsSound, forKey: "orbit.agents.sound")
            notifier.playsSound = playsSound
        }
    }

    var keepsAwake: Bool {
        get {
            access(keyPath: \.keepsAwake)
            return AgentWakeLock.shared.isEnabled
        }
        set {
            withMutation(keyPath: \.keepsAwake) { AgentWakeLock.shared.isEnabled = newValue }
        }
    }

    /// ⇧⌘N and the start screen make isolated sessions unless asked otherwise;
    /// `"agents": { "isolated": true }` in a settings file decides it (D108).
    var isolatedByDefault: Bool {
        get { workspace.settings.bool("agents.isolated") ?? chosenIsolated }
        set { chosenIsolated = newValue }
    }

    private var chosenIsolated: Bool {
        didSet { settings.set(chosenIsolated, for: "isolatedByDefault") }
    }

    /// Option values (by category) remembered per agent for new chats; mode
    /// isn't among them, a new chat shouldn't start in "bypass permissions".
    private var lastValues: [String: [String: String]] {
        didSet { if let data = try? JSONEncoder().encode(lastValues) { settings.set(data, for: "lastOptions") } }
    }
    private static let rememberedCategories: Set<String> = ["model", "thought_level"]

    /// Each agent's model list as it last reported it, so the picker can offer
    /// models of agents that aren't running.
    private(set) var models: [String: ConfigOption] {
        didSet { if let data = try? JSONEncoder().encode(models) { settings.set(data, for: "models") } }
    }

    /// A new conversation with the last used agent; an empty one already open is reused.
    func newChat(_ provider: AgentProvider? = nil, isolated: Bool? = nil) {
        guard let provider = provider ?? preferredProvider else { return }
        let isolated = isolated ?? isolatedByDefault
        if let empty = sessions.first(where: {
            $0.isEmptyChat && !$0.hasFailed && $0.provider.id == provider.id && $0.isIsolated == isolated && $0.project.path == workspace.root?.path
        }) {
            selectedID = empty.id
            focusComposer()
            return
        }
        newSession(provider, isolated: isolated)
    }

    func newSession(_ provider: AgentProvider, isolated: Bool = false) {
        guard let root = workspace.root else { return }
        preferredProviderID = provider.id
        let session = makeSession(provider, project: root, isolated: isolated)
        sessions.append(session)
        selectedID = session.id
        focusComposer()
    }

    /// Opens an earlier conversation, or its tab if it's already open. It
    /// takes the place of an empty new chat.
    func resume(_ saved: SavedSession) {
        if let open = sessions.first(where: { $0.saved?.id == saved.id }) {
            selectedID = open.id
            return
        }
        guard let provider = providers.first(where: { $0.id == saved.providerID }) else { return }
        let session = makeSession(provider, project: URL(fileURLWithPath: saved.cwd), restoring: saved)
        if let current = selected, current.isEmptyChat, let index = sessions.firstIndex(where: { $0.id == current.id }) {
            current.discardIsolatedCopy()
            current.shutdown()
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        selectedID = session.id
        focusComposer()
    }

    /// Sets an option from the picker and remembers it for this agent's next chats.
    func choose(_ value: String, for option: ConfigOption, in session: AgentSession) {
        session.setConfigOption(option, value: value)
        if let category = option.category, Self.rememberedCategories.contains(category) {
            lastValues[session.provider.id, default: [:]][category] = value
        }
    }

    /// A model of another agent. An empty chat changes agent in place, keeping
    /// the draft; a conversation can't, so a new chat starts.
    func switchAgent(of session: AgentSession, to provider: AgentProvider, model: String?) {
        if let model { lastValues[provider.id, default: [:]]["model"] = model }
        guard session.isEmptyChat, let index = sessions.firstIndex(where: { $0.id == session.id }) else {
            newSession(provider, isolated: session.isIsolated)
            return
        }
        let replacement = makeSession(provider, project: session.project, isolated: session.isIsolated)
        replacement.takeDraft(from: session)
        session.discardIsolatedCopy()
        session.shutdown()
        sessions[index] = replacement
        preferredProviderID = provider.id
        selectedID = replacement.id
        focusComposer()
    }

    func close(_ session: AgentSession) {
        if session.isolatedCopy != nil {
            guard confirmDiscardingCopy(of: session) else { return }
            session.discardIsolatedCopy()
        }
        session.shutdown()
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions.remove(at: index)
        if selectedID == session.id {
            selectedID = sessions.isEmpty ? nil : sessions[max(0, index - 1)].id
        }
        // The panel always has a chat to type into.
        if !sessions.contains(where: { $0.project.path == workspace.root?.path }) { newChat() }
        saveTabs()
    }

    /// Closing an isolated session deletes its copy; changes not applied yet go with it.
    private func confirmDiscardingCopy(of session: AgentSession) -> Bool {
        let count = session.unappliedChanges.count
        guard count > 0 else { return true }
        let alert = NSAlert()
        alert.messageText = "Close “\(session.title)”?"
        alert.informativeText = "Its isolated copy has \(count) changed file\(count == 1 ? "" : "s") not applied to the project. Closing deletes the copy."
        alert.addButton(withTitle: "Cancel")
        let discard = alert.addButton(withTitle: "Close and Delete Copy")
        discard.hasDestructiveAction = true
        return alert.runSheetModal() == .alertSecondButtonReturn
    }

    /// Earlier conversations in this folder that aren't open in a tab, newest first.
    var recent: [SavedSession] {
        guard let root = workspace.root else { return [] }
        let open = Set(sessions.compactMap { $0.saved?.id })
        return history.recent(in: root).filter { !open.contains($0.id) && provider(for: $0) != nil }
    }

    func provider(for saved: SavedSession) -> AgentProvider? {
        providers.first { $0.id == saved.providerID }
    }

    /// Asks each agent once per folder for its own list of conversations (it
    /// includes ones started outside Orbit). Each needs its agent process, so
    /// this runs in the background and the list fills in as answers come.
    func loadAgentHistory() {
        guard let root = workspace.root else { return }
        for provider in providers where !history.hasListed(provider.id, in: root) {
            history.setListed([], for: provider.id, in: root)
            let task = environmentTask
            Task {
                let environment = await task.value
                guard provider.isInstalled(in: environment) else { return }
                let sessions = await Self.listSessions(provider, in: root, environment: environment)
                history.setListed(sessions, for: provider.id, in: root)
            }
        }
    }

    private nonisolated static func listSessions(_ provider: AgentProvider, in folder: URL, environment: [String: String]) async -> [SavedSession] {
        guard let client = try? ACPClient(
            command: provider.command,
            environment: environment,
            currentDirectory: folder,
            onNotification: { _, _ in },
            onRequest: { method, _ in throw JSONRPCError.methodNotFound(method) },
            onExit: { _, _ in }
        ) else { return [] }
        defer { client.terminate() }
        do {
            let info = try await client.initialize()
            guard info["agentCapabilities"]?["sessionCapabilities"]?["list"] != nil else { return [] }
            // Codex pages through every project's threads and filters by folder
            // afterwards, so a page can hold few (or none) of this folder's.
            var sessions: [SavedSession] = []
            var cursor: String?
            for _ in 0..<20 {
                guard let page = try? await client.listSessions(cwd: folder, cursor: cursor) else { break }
                sessions += SessionHistory.parseList(page, providerID: provider.id, folder: folder)
                cursor = page["nextCursor"]?.string
                if cursor == nil || sessions.count >= 200 { break }
            }
            return sessions
        } catch {
            return []
        }
    }

    private func makeSession(_ provider: AgentProvider, project: URL, isolated: Bool = false, restoring saved: SavedSession? = nil) -> AgentSession {
        let task = environmentTask
        let session = AgentSession(provider: provider, project: project, isolated: isolated, restoring: saved, workspace: workspace, services: services) {
            await task.value
        }
        session.initialValues = lastValues[provider.id] ?? [:]
        session.onChange = { [weak self, weak session] in
            guard let self, let session, let saved = session.saved else { return }
            if !session.isEmptyChat { history.record(saved) }
            saveTabs()
        }
        session.onAttention = { [weak self, weak session] attention in
            guard let self, let session else { return }
            notifier.post(attention, session: session.id, agent: session.provider.name, chat: session.title)
        }
        session.onTurnFiles = { [weak self, weak session] files in
            guard let self, let session else { return }
            for file in files { changeAuthors[file] = session.id }
        }
        session.onConfigOptions = { [weak self] options in
            guard let self, let model = options.first(where: { $0.category == "model" }) else { return }
            var stored = model
            stored.currentValue = ""
            if models[provider.id] != stored { models[provider.id] = stored }
        }
        return session
    }

    /// Tabs come back on the next launch; their agents start when shown.
    private func restoreTabs() {
        guard let root = workspace.root else { return }
        let (saved, selected) = history.openTabs(in: root)
        let open = Set(sessions.compactMap { $0.saved?.id })
        for entry in saved where !open.contains(entry.id) {
            guard let provider = providers.first(where: { $0.id == entry.providerID }) else { continue }
            sessions.append(makeSession(provider, project: root, restoring: entry))
        }
        selectedID = sessions.first { $0.saved?.sessionID == selected }?.id ?? sessions.last?.id
        if let session = self.selected, session.status == .dormant { Task { await session.start() } }
        if !sessions.contains(where: { $0.project.path == root.path }) { newChat() }
    }

    private func saveTabs() {
        guard let root = workspace.root else { return }
        // Empty chats aren't kept: a fresh one opens next time anyway.
        let open = sessions.filter { $0.project.path == root.path && !$0.isEmptyChat }
        let current = selected.flatMap { $0.isEmptyChat ? nil : $0.saved?.sessionID }
        history.saveOpenTabs(open.compactMap(\.saved), selected: current, in: root)
    }

    func focusComposer() { focusRequest += 1 }

    // MARK: Review notes, per project folder (D131)

    private var savedReviewComments: [String: [ReviewComment]] {
        get { settings.data("reviewComments").flatMap { try? JSONDecoder().decode([String: [ReviewComment]].self, from: $0) } ?? [:] }
        set { settings.set(try? JSONEncoder().encode(newValue), for: "reviewComments") }
    }

    private func loadReviewComments() {
        reviewComments.load(workspace.root.flatMap { savedReviewComments[$0.path] } ?? [])
    }

    private func saveReviewComments() {
        guard let root = workspace.root?.path else { return }
        var all = savedReviewComments
        all[root] = reviewComments.comments.isEmpty ? nil : reviewComments.comments
        savedReviewComments = all
    }

    /// The chat in front: its window, the agents panel, its tab.
    func show(_ session: AgentSession) {
        workspace.bringWindowToFront?()
        selectedID = session.id
        ui.revealInspectorPanel("agents")
    }

    /// All review notes as one message to the open chat (a new one when there's none).
    func sendReviewComments() {
        let comments = reviewComments.comments
        guard !comments.isEmpty else { return }
        if selected == nil { newChat() }
        guard let session = selected else { return }
        let documents = workspace.documents
        session.deliver(ReviewCommentPrompt.text(for: comments, root: workspace.root) { documents.currentText(of: $0) })
        reviewComments.removeAll()
        focusComposer()
    }

    // MARK: Installed agents

    private func refreshMissing() {
        let providers = providers
        let task = environmentTask
        Task { [weak self] in
            let environment = await task.value
            self?.missing = Set(providers.filter { !$0.isInstalled(in: environment) }.map(\.id))
        }
    }

    /// Picks up agents installed, updated or removed since launch.
    func reloadProviders() {
        let previous = providers
        providers = AgentProvider.loadAll()
        guard providers != previous else { return }
        refreshMissing()
        registerProviderCommands()
        // A freshly installed agent is listed too.
        if let root = workspace.root {
            for provider in providers where !previous.contains(where: { $0.id == provider.id }) {
                history.forgetListed(provider.id, in: root)
            }
        }
        loadAgentHistory()
        if sessions.isEmpty { restoreTabs() }
    }

    func install(_ agent: RegistryAgent) async {
        guard await registry.install(agent) else { return }
        reloadProviders()
        // Running sessions keep the old command until they restart; new ones get the update.
    }

    func uninstall(_ provider: AgentProvider) {
        registry.uninstall(provider)
        reloadProviders()
    }

    /// "New <Agent> Session" for each installed agent, in the palette and the Agents menu.
    func registerProviderCommands() {
        for id in providerCommandIDs { commands.unregister(id) }
        providerCommandIDs = providers.map { "agents.new.\($0.id)" }
        let workspace = workspace
        let ui = ui
        for provider in providers {
            commands.register(OrbitCommand(
                id: "agents.new.\(provider.id)",
                title: "New \(provider.name) Session",
                category: "Agents",
                systemImage: provider.icon,
                isEnabled: { [weak self] in workspace.root != nil && self?.missing.contains(provider.id) == false }
            ) { [weak self] in
                ui.revealInspectorPanel("agents")
                self?.newChat(provider)
            })
        }
    }

    /// Orbit used to ship Claude Code and Codex (and launch Cursor, Grok and
    /// OpenCode from the PATH). Once, for people who used them: Claude Code and
    /// Codex are installed from the registry, and the PATH ones that are there
    /// keep working as custom agents.
    private func migrateBuiltinAgents() {
        guard !settings.bool("registryMigrated") else { return }
        guard settings.string("lastProvider") != nil || settings.data("history") != nil else {
            settings.set(true, for: "registryMigrated")
            return
        }
        let task = environmentTask
        Task { [weak self] in
            let environment = await task.value
            let legacy: [(id: String, name: String, executable: String, arguments: [String])] = [
                ("cursor", "Cursor", "cursor-agent", ["acp"]),
                ("grok", "Grok Build", "grok", ["agent", "stdio"]),
                ("opencode", "OpenCode", "opencode", ["acp"]),
            ]
            for agent in legacy where !FileManager.default.fileExists(atPath: AgentProvider.manifestFile(for: agent.id).path) {
                let provider = AgentProvider(id: agent.id, name: agent.name, command: AgentCommand(executable: agent.executable, arguments: agent.arguments))
                guard provider.isInstalled(in: environment), let data = try? JSONEncoder().encode(provider) else { continue }
                try? FileManager.default.createDirectory(at: AgentProvider.configDirectory, withIntermediateDirectories: true)
                try? data.write(to: AgentProvider.manifestFile(for: agent.id))
            }
            guard let self else { return }
            await registry.refresh()
            guard registry.loadError == nil else { reloadProviders(); return }
            for id in AgentProvider.legacyIDs.values where !providers.contains(where: { $0.id == id }) {
                if let agent = registry.agents.first(where: { $0.id == id }) { _ = await registry.install(agent) }
            }
            settings.set(true, for: "registryMigrated")
            reloadProviders()
        }
    }

    private static func migratingKeys<Value>(_ values: [String: Value]) -> [String: Value] {
        Dictionary(values.map { (AgentProvider.migratedID($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    func shutdown() {
        AgentDirectory.shared.remove(self)
        for session in sessions { session.shutdown() }
    }
}
