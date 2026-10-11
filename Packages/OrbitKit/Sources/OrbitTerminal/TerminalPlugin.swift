import AppKit
import OrbitAPI
import OrbitUI
import SwiftUI

public final class TerminalPlugin: OrbitPlugin {
    public static let manifest = PluginManifest(
        id: "orbit.terminal",
        name: "Terminal",
        summary: "Integrated terminal in the bottom panel.",
        systemImage: "terminal"
    )

    private var store: TerminalStore?

    public init() {}

    public func activate(_ context: PluginContext) {
        let ui = context.ui
        let store = TerminalStore(workspace: context.workspace, ui: ui)
        self.store = store
        context.services.register(AgentTerminalHosting.self, store)

        ui.addBottomPanel(PanelContribution(id: TerminalStore.panelID, title: "Terminal", systemImage: "terminal") {
            TerminalPanel(store: store)
        })

        context.commands.register(OrbitCommand(
            id: "terminal.toggle",
            title: "Toggle Terminal",
            category: "Terminal",
            systemImage: "terminal",
            shortcut: KeyboardShortcut("`", modifiers: .control)
        ) {
            store.toggle()
        })
        context.commands.register(OrbitCommand(
            id: "terminal.new",
            title: "New Terminal",
            category: "Terminal",
            systemImage: "plus.rectangle",
            shortcut: KeyboardShortcut("`", modifiers: [.control, .shift])
        ) {
            store.newSession()
        })
        context.commands.register(OrbitCommand(
            id: "terminal.kill",
            title: "Kill Terminal",
            category: "Terminal",
            systemImage: "trash",
            isEnabled: { store.selected != nil }
        ) {
            if let session = store.selected { store.close(session) }
        })
    }

    public func deactivate() {
        store?.terminateAll()
    }
}

@MainActor
@Observable
final class TerminalStore {
    static let panelID = "terminal"

    private let workspace: Workspace
    private let ui: UIRegistry
    private(set) var sessions: [TerminalSession] = []
    var selectedID: TerminalSession.ID?

    init(workspace: Workspace, ui: UIRegistry) {
        self.workspace = workspace
        self.ui = ui
    }

    var selected: TerminalSession? { sessions.first { $0.id == selectedID } }

    private var isShown: Bool {
        ui.isBottomPanelVisible && (ui.selectedBottomPanel ?? ui.bottomPanels.first?.id) == Self.panelID
    }

    func toggle() {
        if isShown {
            ui.isBottomPanelVisible = false
            return
        }
        ui.revealBottomPanel(Self.panelID)
        if hasShell { focusSelected() } else { newSession() }
    }

    /// Agent command tabs don't count: toggling the terminal should give the user a shell.
    var hasShell: Bool { sessions.contains { !$0.isAgent } }

    func newSession() {
        let session = TerminalSession(directory: workspace.root ?? URL(fileURLWithPath: NSHomeDirectory()))
        session.onExit = { [weak self] session in self?.remove(session) }
        sessions.append(session)
        selectedID = session.id
        ui.revealBottomPanel(Self.panelID)
        focusSelected()
    }

    func select(_ session: TerminalSession) {
        selectedID = session.id
        focusSelected()
    }

    func close(_ session: TerminalSession) {
        session.terminate()
        remove(session)
    }

    /// Also called when the shell exits on its own (`exit`, ⌃D). Tabs closed
    /// on the user's behalf (`automatic`) leave the panel and focus alone.
    private func remove(_ session: TerminalSession, automatic: Bool = false) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions.remove(at: index)
        session.agentTerminal?.hostDidCloseTerminal()
        if selectedID == session.id {
            selectedID = sessions.isEmpty ? nil : sessions[min(index, sessions.count - 1)].id
        }
        guard !automatic else { return }
        if sessions.isEmpty {
            if isShown { ui.isBottomPanelVisible = false }
        } else {
            focusSelected()
        }
    }

    /// Agents run many commands; keep the tabs from piling up. Released commands
    /// go away unless the user is looking at them, and only the newest few
    /// finished ones stay.
    private func pruneAgentSessions() {
        let finished = sessions.filter { $0.isAgent && !$0.isRunning && $0.id != selectedID }
        for session in finished.dropLast(Self.keptAgentTabs) { remove(session, automatic: true) }
    }

    private static let keptAgentTabs = 3

    func terminateAll() {
        for session in sessions { session.terminate() }
        sessions.removeAll()
    }

    /// The view may only now be entering the window; focus on the next pass.
    func focusSelected() {
        DispatchQueue.main.async { [weak self] in self?.selected?.focus() }
    }
}

extension TerminalStore: AgentTerminalHosting {
    /// Opens the command in a background tab: it never takes the selection,
    /// focus or the panel away from the user.
    func run(_ request: AgentTerminalRequest) -> AgentTerminal {
        let terminal = AgentTerminal(request: request)
        adopt(TerminalSession(agentTerminal: terminal), for: terminal)
        return terminal
    }

    func display(_ request: AgentTerminalRequest) -> AgentTerminal {
        let terminal = AgentTerminal(request: request, ownsProcess: false)
        adopt(TerminalSession(displaying: terminal), for: terminal)
        return terminal
    }

    private func adopt(_ session: TerminalSession, for terminal: AgentTerminal) {
        session.onExit = { [weak self] _ in self?.pruneAgentSessions() }
        terminal.onKill = { [weak session] in session?.kill() }
        terminal.onReveal = { [weak self, weak session] in
            guard let self, let session, sessions.contains(where: { $0.id == session.id }) else { return }
            selectedID = session.id
            ui.revealBottomPanel(Self.panelID)
        }
        terminal.onRelease = { [weak self, weak session] in
            guard let self, let session, session.id != selectedID else { return }
            remove(session, automatic: true)
        }
        sessions.append(session)
        if selectedID == nil { selectedID = session.id }
    }
}

struct TerminalPanel: View {
    let store: TerminalStore

    var body: some View {
        VStack(spacing: 0) {
            TerminalTabs(store: store)
            Divider()
            if let session = store.selected {
                TerminalHost(session: session)
                    .padding(.leading, 8)
                    .padding(.top, 4)
            } else {
                Spacer()
            }
        }
        // Opaque, matching the terminal itself, so the tab strip doesn't show the window through.
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            // Revealed from the shell (e.g. its own toggle) without a session yet.
            if store.sessions.isEmpty { store.newSession() }
        }
    }
}

private struct TerminalTabs: View {
    let store: TerminalStore

    var body: some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(store.sessions) { session in
                        TerminalTab(session: session, isSelected: session.id == store.selectedID) {
                            store.select(session)
                        } close: {
                            store.close(session)
                        }
                    }
                }
            }
            IconButton("plus", help: "New Terminal (⌃⇧`)") { store.newSession() }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
    }
}

private struct TerminalTab: View {
    let session: TerminalSession
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: session.isAgent ? "sparkles" : "terminal")
                .font(.system(size: 10))
                .foregroundStyle(session.isAgent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            Text(session.title)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180, alignment: .leading)
                .opacity(session.isAgent && !session.isRunning ? 0.6 : 1)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isHovered || isSelected ? 1 : 0)
            .help(session.isAgent && session.isRunning ? "Stop Command" : "Kill Terminal")
        }
        .help(session.isAgent ? "Agent: \(session.title)" : session.title)
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: 22)
        .background(isSelected ? AnyShapeStyle(Theme.subtleFill) : AnyShapeStyle(.clear), in: .rect(cornerRadius: Theme.smallCorner))
        .foregroundStyle(isSelected ? .primary : .secondary)
        .contentShape(.rect)
        .onTapGesture(perform: select)
        .onHover { isHovered = $0 }
    }
}

/// Hosts the session's long-lived terminal view inside a container, so SwiftUI
/// re-creating this representable never tears the terminal down.
private struct TerminalHost: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if session.view.superview !== container { attach(to: container) }
    }

    private func attach(to container: NSView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        let view = session.view
        view.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
    }
}
