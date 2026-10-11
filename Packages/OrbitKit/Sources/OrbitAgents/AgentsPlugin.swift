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

        ui.addInspectorPanel(PanelContribution(id: "agents", title: "Agents", systemImage: "sparkles", order: 0) {
            AgentsPanel(store: store)
        })

        ui.addStatusItem(StatusItem(
            id: "agents.activity", placement: .leading, order: 0,
            isVisible: { store.sessions.contains { $0.status == .working || $0.hasPendingPermission } }
        ) {
            AgentActivityStatus(store: store)
        })

        context.commands.register(OrbitCommand(
            id: "agents.focus",
            title: "Focus Agent Chat",
            category: "Agents",
            systemImage: "text.bubble",
            shortcut: KeyboardShortcut("l", modifiers: .command)
        ) {
            ui.revealInspectorPanel("agents")
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
            store.newSession(store.preferredProvider)
        })

        for provider in store.providers {
            context.commands.register(OrbitCommand(
                id: "agents.new.\(provider.id)",
                title: "New \(provider.name) Session",
                category: "Agents",
                systemImage: provider.icon,
                isEnabled: { context.workspace.root != nil }
            ) {
                ui.revealInspectorPanel("agents")
                store.newSession(provider)
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
    /// Bumped to ask the composer to take keyboard focus.
    private(set) var focusRequest = 0

    let workspace: Workspace
    private let services: ServiceRegistry
    private let settings: PluginSettings
    private let environmentTask: Task<[String: String], Never>

    init(context: PluginContext) {
        workspace = context.workspace
        services = context.services
        settings = context.settings
        providers = AgentProvider.loadAll()
        history = SessionHistory(settings: context.settings)
        // Resolve the login-shell environment up front; spawning agents needs it.
        environmentTask = Task.detached { await ShellEnvironment.resolve() }
        restoreTabs()
    }

    var selected: AgentSession? { sessions.first { $0.id == selectedID } }

    func environment() async -> [String: String] { await environmentTask.value }

    var preferredProvider: AgentProvider {
        let id = settings.string("lastProvider")
        return providers.first { $0.id == id } ?? providers[0]
    }

    func newSession(_ provider: AgentProvider) {
        guard let root = workspace.root else { return }
        settings.set(provider.id, for: "lastProvider")
        let session = makeSession(provider, cwd: root)
        sessions.append(session)
        selectedID = session.id
        focusComposer()
    }

    /// Opens an earlier conversation, or its tab if it's already open.
    func resume(_ saved: SavedSession) {
        if let open = sessions.first(where: { $0.saved?.id == saved.id }) {
            selectedID = open.id
            return
        }
        guard let provider = providers.first(where: { $0.id == saved.providerID }) else { return }
        let session = makeSession(provider, cwd: URL(fileURLWithPath: saved.cwd), restoring: saved)
        sessions.append(session)
        selectedID = session.id
        focusComposer()
    }

    func close(_ session: AgentSession) {
        session.shutdown()
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions.remove(at: index)
        if selectedID == session.id {
            selectedID = sessions.isEmpty ? nil : sessions[max(0, index - 1)].id
        }
        saveTabs()
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
                let sessions = await Self.listSessions(provider, in: root, environment: await task.value)
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

    private func makeSession(_ provider: AgentProvider, cwd: URL, restoring saved: SavedSession? = nil) -> AgentSession {
        let task = environmentTask
        let session = AgentSession(provider: provider, cwd: cwd, restoring: saved, workspace: workspace, services: services) {
            await task.value
        }
        session.onChange = { [weak self, weak session] in
            guard let self, let saved = session?.saved else { return }
            history.record(saved)
            saveTabs()
        }
        return session
    }

    /// Tabs come back on the next launch; their agents start when shown.
    private func restoreTabs() {
        guard let root = workspace.root else { return }
        let (saved, selected) = history.openTabs(in: root)
        for entry in saved {
            guard let provider = providers.first(where: { $0.id == entry.providerID }) else { continue }
            sessions.append(makeSession(provider, cwd: root, restoring: entry))
        }
        selectedID = sessions.first { $0.saved?.sessionID == selected }?.id ?? sessions.last?.id
        if let session = self.selected, session.status == .dormant { Task { await session.start() } }
    }

    private func saveTabs() {
        guard let root = workspace.root else { return }
        let open = sessions.filter { $0.cwd.path == root.path }
        history.saveOpenTabs(open.compactMap(\.saved), selected: selected?.saved?.sessionID, in: root)
    }

    func focusComposer() { focusRequest += 1 }

    func shutdown() {
        for session in sessions { session.shutdown() }
    }
}
