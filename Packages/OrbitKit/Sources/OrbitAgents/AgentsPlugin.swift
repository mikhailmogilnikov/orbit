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

    public init() {}

    public func activate(_ context: PluginContext) {
        let store = AgentStore(context: context)
        self.store = store
        let ui = context.ui
        let completion = AgentCompletionService(store: store)
        self.completion = completion
        context.services.register(AgentCompletion.self, completion)

        ui.addSettingsPane(SettingsPane(
            id: "agents", title: "Agents", systemImage: "sparkles", order: 20,
            keywords: ["claude", "codex", "default", "isolated", "copy", "custom", "acp", "login"]
        ) {
            AgentsSettingsPane(store: store)
        })

        ui.addInspectorPanel(PanelContribution(id: "agents", title: "Agents", systemImage: "sparkles", order: 0) {
            AgentsPanel(store: store)
        })

        ui.addStatusItem(StatusItem(
            id: "agents.activity", placement: .leading, order: 0,
            isVisible: { store.sessions.contains { $0.status == .working || $0.hasPendingPermission } }
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
            shortcut: KeyboardShortcut("l", modifiers: .command)
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

        for provider in store.providers {
            context.commands.register(OrbitCommand(
                id: "agents.new.\(provider.id)",
                title: "New \(provider.name) Session",
                category: "Agents",
                systemImage: provider.icon,
                isEnabled: { context.workspace.root != nil && !store.missing.contains(provider.id) }
            ) {
                ui.revealInspectorPanel("agents")
                store.newChat(provider)
            })
        }

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

@MainActor
@Observable
final class AgentStore {
    let providers: [AgentProvider]
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
    private let services: ServiceRegistry
    /// The changed-files list above the composer is expanded.
    var isChangesExpanded = false
    private let settings: PluginSettings
    private let environmentTask: Task<[String: String], Never>

    init(context: PluginContext) {
        workspace = context.workspace
        commands = context.commands
        services = context.services
        settings = context.settings
        providers = AgentProvider.loadAll()
        history = SessionHistory(settings: context.settings)
        preferredProviderID = context.settings.string("lastProvider")
        isolatedByDefault = context.settings.bool("isolatedByDefault")
        lastValues = context.settings.data("lastOptions").flatMap { try? JSONDecoder().decode([String: [String: String]].self, from: $0) } ?? [:]
        models = context.settings.data("models").flatMap { try? JSONDecoder().decode([String: ConfigOption].self, from: $0) } ?? [:]
        // Resolve the login-shell environment up front; spawning agents needs it.
        environmentTask = Task.detached { await ShellEnvironment.resolve() }
        folder = workspace.root
        Task { [weak self, providers, environmentTask] in
            let environment = await environmentTask.value
            let missing = Set(providers.filter { !$0.isInstalled(in: environment) }.map(\.id))
            self?.missing = missing
        }
        restoreTabs()
        observeFolder()
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
                self?.folderDidChange()
                self?.observeFolder()
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
        if selected == nil, selectedID != nil { selectedID = nil }
        loadAgentHistory()
    }

    var selected: AgentSession? { sessions.first { $0.id == selectedID } }

    func environment() async -> [String: String] { await environmentTask.value }

    /// The last agent started; new sessions and helpers (commit messages) use it.
    var preferredProviderID: String? {
        didSet { settings.set(preferredProviderID, for: "lastProvider") }
    }

    var preferredProvider: AgentProvider {
        availableProviders.first { $0.id == preferredProviderID } ?? availableProviders.first ?? providers[0]
    }

    /// Agents whose CLI isn't on the PATH; known once the shell environment is.
    private(set) var missing: Set<String> = []

    var availableProviders: [AgentProvider] { providers.filter { !missing.contains($0.id) } }

    /// ⇧⌘N and the start screen make isolated sessions unless asked otherwise.
    var isolatedByDefault: Bool {
        didSet { settings.set(isolatedByDefault, for: "isolatedByDefault") }
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
        let provider = provider ?? preferredProvider
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
        return alert.runModal() == .alertSecondButtonReturn
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
            return SessionHistory.parseList(try await client.listSessions(cwd: folder), providerID: provider.id, folder: folder)
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

    func shutdown() {
        for session in sessions { session.shutdown() }
    }
}
