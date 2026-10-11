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
    var selectedID: AgentSession.ID?
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
        // Resolve the login-shell environment up front; spawning agents needs it.
        environmentTask = Task.detached { await ShellEnvironment.resolve() }
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
        let task = environmentTask
        let session = AgentSession(provider: provider, cwd: root, workspace: workspace, services: services) {
            await task.value
        }
        sessions.append(session)
        selectedID = session.id
        focusComposer()
        Task { await session.start() }
    }

    func close(_ session: AgentSession) {
        session.shutdown()
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions.remove(at: index)
        if selectedID == session.id {
            selectedID = sessions.isEmpty ? nil : sessions[max(0, index - 1)].id
        }
    }

    func focusComposer() { focusRequest += 1 }

    func shutdown() {
        for session in sessions { session.shutdown() }
    }
}
