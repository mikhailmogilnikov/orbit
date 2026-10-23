import AppKit
import OrbitAPI
import OrbitUI
import SwiftUI

public final class TerminalPlugin: OrbitPlugin {
    public static let manifest = PluginManifest(
        id: "orbit.terminal",
        name: "Terminal",
        summary: "Integrated terminal in the bottom panel.",
        systemImage: "terminal",
        tint: Color(white: 0.16)
    )

    private var store: TerminalStore?

    public init() {}

    public func activate(_ context: PluginContext) {
        let ui = context.ui
        let options = TerminalOptions(settings: context.settings)
        let store = TerminalStore(workspace: context.workspace, ui: ui, options: options)
        ui.addSettingsPane(SettingsPane(
            id: "terminal", title: "Terminal", systemImage: "apple.terminal.fill", tint: Color(white: 0.16), group: .code, order: 40,
            summary: "The shell new tabs start, the font, the cursor and the keyboard.",
            keywords: ["shell", "zsh", "bash", "fish", "cursor", "caret", "option", "meta", "alt", "scrollback", "history", "font"],
            items: { [
                SettingsItem("shell", "Shell", keywords: ["zsh", "bash", "fish", "login shell"]),
                SettingsItem("fontSize", "Terminal font size", keywords: ["font", "size", "zoom"]),
                SettingsItem("cursor", "Cursor shape", keywords: ["caret", "block", "bar", "underline", "beam"]),
                SettingsItem("cursorBlinks", "Blinking cursor", keywords: ["caret", "blink"]),
                SettingsItem("optionAsMeta", "Use Option as Meta key", keywords: ["alt", "meta", "emacs", "vim", "escape"]),
                SettingsItem("scrollback", "Scrollback", keywords: ["history", "lines", "buffer"]),
            ] }
        ) {
            TerminalSettingsPane(options: options)
        })
        self.store = store
        context.services.register(AgentTerminalHosting.self, store)
        context.services.register(TerminalOpening.self, store)
        context.services.register(TaskProblems.self, store.problems)
        context.services.register(LocalServers.self, store)
        let services = context.services
        store.browser = { services.resolve(WebPreviewing.self) }

        ui.addStatusItem(StatusItem(id: "tasks.running", placement: .leading, order: 40, isVisible: { !store.runningTasks.isEmpty }) {
            RunningTasksStatus(store: store)
        })

        ui.addBottomPanel(PanelContribution(id: TerminalStore.panelID, title: "Terminal", systemImage: "terminal") {
            TerminalPanel(store: store)
        }.accessory {
            IconButton("plus", help: "New Terminal (⌃⇧`)") { store.newSession() }
        }.command("terminal.toggle"))

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
        // SwiftTerm's find bar; ⌘F (Find → Find…) opens it too while the terminal has focus.
        context.commands.register(OrbitCommand(
            id: "terminal.find",
            title: "Find in Terminal…",
            category: "Terminal",
            systemImage: "magnifyingglass",
            isEnabled: { store.selected != nil }
        ) {
            guard let view = store.selected?.view else { return }
            ui.revealBottomPanel(TerminalStore.panelID)
            DispatchQueue.main.async {
                view.window?.makeFirstResponder(view)
                let item = NSMenuItem()
                item.tag = NSTextFinder.Action.showFindInterface.rawValue
                view.performTextFinderAction(item)
            }
        })
        context.commands.register(OrbitCommand(
            id: "tasks.run",
            title: "Run Task…",
            category: "Terminal",
            systemImage: "play",
            shortcut: KeyboardShortcut("r", modifiers: [.command, .control]),
            isEnabled: { context.workspace.root != nil }
        ) {
            Self.pickTask(store: store, ui: ui, commands: context.commands)
        })
        context.commands.register(OrbitCommand(
            id: "tasks.runLast",
            title: "Run Last Task",
            category: "Terminal",
            systemImage: "arrow.clockwise",
            shortcut: KeyboardShortcut("r", modifiers: .command),
            isEnabled: { context.workspace.root != nil }
        ) {
            if let task = store.lastTask {
                store.run(task)
            } else {
                Self.pickTask(store: store, ui: ui, commands: context.commands)
            }
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
        #if DEBUG
        TerminalStress.register(context, store: store)
        #endif
    }

    public func deactivate() {
        store?.terminateAll()
    }

    public func deactivationWarning() -> String? {
        guard let store, !store.sessions.isEmpty else { return nil }
        let tasks = store.runningTasks.count
        if tasks > 0 { return tasks == 1 ? "A running task stops." : "\(tasks) running tasks stop." }
        return store.sessions.count == 1 ? "The open terminal closes." : "\(store.sessions.count) open terminals close."
    }

    @MainActor
    private static func pickTask(store: TerminalStore, ui: UIRegistry, commands: CommandRegistry) {
        let tasks = store.tasks()
        ui.presentQuickPick(QuickPick(id: "tasks", placeholder: "Run a task", initialSelection: store.lastTask?.id) { query in
            guard !tasks.isEmpty else {
                return [QuickPickItem(
                    id: "none", title: AttributedString("No tasks found: add \"tasks\" to .orbit/settings.json"),
                    subtitle: "Scripts in package.json, Makefile targets, Swift, Cargo and Go are found by themselves",
                    systemImage: "gearshape"
                ) { commands.run("editor.openProjectSettings") }]
            }
            let matched: [(task: ProjectTask, positions: [Int], score: Int)] = tasks.compactMap { task in
                guard let match = FuzzyMatch.match(query, in: task.name) ?? FuzzyMatch.match(query, in: task.command).map({ .init(score: $0.score - 5, positions: []) })
                else { return nil }
                return (task, match.positions, match.score)
            }
            let ordered = query.isEmpty ? matched : matched.sorted { $0.score > $1.score }
            return ordered.map { entry in
                QuickPickItem(
                    id: entry.task.id,
                    title: FuzzyMatch.highlighted(entry.task.name, positions: entry.positions),
                    subtitle: entry.task.detail.map { $0 == entry.task.command ? $0 : "\(entry.task.command) · \($0)" } ?? entry.task.command,
                    systemImage: store.isRunning(entry.task) ? "play.circle.fill" : "play",
                    trailing: entry.task.source
                ) { store.run(entry.task) }
            }
        })
    }
}

@MainActor
@Observable
final class TerminalStore: TerminalOpening {
    func openTerminal(in directory: URL) { newSession(in: directory) }

    static let panelID = "terminal"

    private let workspace: Workspace
    private let ui: UIRegistry
    private let options: TerminalOptions
    private(set) var sessions: [TerminalSession] = []
    var selectedID: TerminalSession.ID?

    init(workspace: Workspace, ui: UIRegistry, options: TerminalOptions) {
        self.workspace = workspace
        self.ui = ui
        self.options = options
        options.onChange = { [weak self] in
            guard let self else { return }
            for session in sessions { options.apply(to: session.view) }
        }
    }

    var selected: TerminalSession? { sessions.first { $0.id == selectedID } }

    // MARK: Tasks (D128)

    /// Run Last Task's.
    private(set) var lastTask: ProjectTask?

    func tasks() -> [ProjectTask] {
        let templates = Extensions.shared.taskFiles.flatMap { file in
            (try? Data(contentsOf: file.url)).flatMap { try? TaskTemplate.parse($0, source: file.extensionName) } ?? []
        }
        return workspace.root.map { ProjectTasks.find(in: $0, templates: templates) } ?? []
    }

    let problems = TaskProblemStore()
    @ObservationIgnored var browser: () -> WebPreviewing? = { nil }
    /// Task tabs with something running in them now, for the status bar (D138).
    private(set) var runningTasks: [TerminalSession.ID] = []
    @ObservationIgnored private var watchingTasks: Task<Void, Never>?

    /// In the task's own tab; running it again restarts it there.
    func run(_ task: ProjectTask) {
        guard let root = workspace.root else { return }
        lastTask = task
        let session: TerminalSession
        if let open = sessions.first(where: { $0.taskID == task.id && $0.isRunning }) {
            session = open
        } else {
            let directory = task.directory.isEmpty ? root : root.appendingPathComponent(task.directory)
            session = TerminalSession(directory: directory, task: task, root: root, shell: options.effectiveShell)
            options.apply(to: session.view)
            session.onExit = { [weak self] session in self?.remove(session) }
            session.onProblems = { [weak self] session in self?.problems.update(session.id, session.output?.problems ?? [:]) }
            linkFiles(session)
            sessions.append(session)
        }
        selectedID = session.id
        ui.revealBottomPanel(Self.panelID)
        session.type(task.command)
        focusSelected()
        watchTasks()
    }

    func isRunning(_ task: ProjectTask) -> Bool {
        sessions.contains { $0.taskID == task.id && $0.isBusy }
    }

    /// Whether a task still runs isn't observable (the terminal's foreground
    /// process), so it's looked at every second while there are task tabs.
    private func watchTasks() {
        guard watchingTasks == nil else { return }
        watchingTasks = Task { [weak self] in
            while let self, !workspace.isClosed, sessions.contains(where: \.isTask) {
                let running = sessions.filter { $0.isTask && $0.isBusy }.map(\.id)
                if running != runningTasks { runningTasks = running }
                try? await Task.sleep(for: .seconds(1))
            }
            self?.runningTasks = []
            self?.watchingTasks = nil
        }
    }

    /// ⌘-clicked paths open in the editor (D148).
    func linkFiles(_ session: TerminalSession) {
        if let root = workspace.root, !session.view.directories.contains(root) { session.view.directories.append(root) }
        session.view.onOpenFile = { [weak self] url, line, column in
            guard let workspace = self?.workspace else { return false }
            if let line { workspace.openFile(url, line: line, column: column) } else { workspace.openFile(url) }
            return true
        }
    }

    func reveal(_ session: TerminalSession) {
        selectedID = session.id
        ui.revealBottomPanel(Self.panelID)
        focusSelected()
    }

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

    func newSession(in directory: URL? = nil) {
        let session = TerminalSession(directory: directory ?? workspace.root ?? URL(fileURLWithPath: NSHomeDirectory()), root: workspace.root, shell: options.effectiveShell)
        options.apply(to: session.view)
        session.onExit = { [weak self] session in self?.remove(session) }
        linkFiles(session)
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
        problems.remove(session.id)
        runningTasks.removeAll { $0 == session.id }
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

    private static let keptAgentTabs = 5

    func terminateAll() {
        watchingTasks?.cancel()
        for session in sessions { session.terminate() }
        sessions.removeAll()
    }

    /// The view may only now be entering the window; focus on the next pass.
    func focusSelected() {
        DispatchQueue.main.async { [weak self] in self?.selected?.focus() }
    }
}

extension TerminalStore: LocalServers {
    /// The running tasks' dev servers, the newest tab first.
    var localURLs: [URL] {
        var seen = Set<URL>()
        return sessions.reversed().filter { runningTasks.contains($0.id) }.compactMap(\.output?.localURL).filter { seen.insert($0).inserted }
    }
}

extension TerminalStore: AgentTerminalHosting {
    /// The command owns a process here and may ask for input, so it gets a tab
    /// right away, in the background: it never takes the selection, focus or
    /// the panel away from the user.
    func run(_ request: AgentTerminalRequest) -> AgentTerminal {
        let terminal = AgentTerminal(request: request)
        let session = add(TerminalSession(agentTerminal: terminal))
        if selectedID == nil { selectedID = session.id }
        wire(terminal)
        return terminal
    }

    /// Output only: the tool card shows it, and a tab opens just when the user
    /// asks for it (Show in Terminal).
    func display(_ request: AgentTerminalRequest) -> AgentTerminal {
        let terminal = AgentTerminal(request: request, ownsProcess: false)
        wire(terminal)
        return terminal
    }

    private func wire(_ terminal: AgentTerminal) {
        terminal.onKill = { [weak self, weak terminal] in
            guard let terminal else { return }
            self?.tab(showing: terminal)?.kill()
        }
        terminal.onReveal = { [weak self, weak terminal] in
            guard let self, let terminal else { return }
            // Opened on demand, or again after being closed: drawn from what the command printed.
            let shown = tab(showing: terminal) ?? add(TerminalSession(displaying: terminal))
            selectedID = shown.id
            ui.revealBottomPanel(Self.panelID)
        }
        terminal.onRelease = { [weak self, weak terminal] in
            guard let self, let terminal, let shown = tab(showing: terminal), shown.id != selectedID else { return }
            remove(shown, automatic: true)
        }
    }

    @discardableResult
    private func add(_ session: TerminalSession) -> TerminalSession {
        options.apply(to: session.view)
        session.onExit = { [weak self] _ in self?.pruneAgentSessions() }
        linkFiles(session)
        sessions.append(session)
        return session
    }

    private func tab(showing terminal: AgentTerminal) -> TerminalSession? {
        sessions.first { $0.agentTerminal === terminal }
    }
}

struct TerminalPanel: View {
    let store: TerminalStore

    var body: some View {
        HStack(spacing: 0) {
            if let session = store.selected {
                TerminalHost(session: session, fontSize: Preferences.shared.effectiveTerminalFontSize, fontFamily: Preferences.shared.codeFontFamily)
                    .padding(.leading, 8)
                    .padding(.top, 4)
            } else {
                Spacer()
            }
            // Sessions get a list of their own beside the output, like VS Code's,
            // so they never mix with the panel tabs above (D167).
            if store.sessions.count > 1 {
                TerminalList(store: store)
                    .frame(width: 180)
            }
        }
        .background(Theme.terminalBackground)
        .onAppear {
            // Revealed from the shell (e.g. its own toggle) without a session yet.
            if store.sessions.isEmpty { store.newSession() }
        }
    }
}

struct TerminalList: View {
    let store: TerminalStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(store.sessions) { session in
                        TerminalTab(session: session, isSelected: session.id == store.selectedID, isRunningTask: store.runningTasks.contains(session.id)) {
                            store.select(session)
                        } close: {
                            store.close(session)
                        }
                        .id(session.id)
                    }
                }
                .padding(6)
            }
            .scrollsToActiveTab(store.selectedID, in: proxy)
        }
        .overlay(alignment: .leading) { Divider() }
    }
}

private struct TerminalTab: View {
    let session: TerminalSession
    let isSelected: Bool
    var isRunningTask = false
    let select: () -> Void
    let close: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: session.isAgent ? "sparkles" : isRunningTask ? "play.fill" : session.isTask ? "play" : "terminal")
                .orbitFont(.micro)
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(session.isAgent ? AnyShapeStyle(.tint) : isRunningTask ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
            Text(session.title)
                .orbitFont(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(session.isAgent && !session.isRunning ? 0.6 : 1)
            Button(action: close) {
                Image(systemName: "xmark")
                    .orbitFont(.glyph, weight: .bold)
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
        .background(isSelected ? Theme.activeFill : .clear, in: .capsule)
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
    let fontSize: Double
    let fontFamily: String?

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if session.view.superview !== container { attach(to: container) }
        let font = Preferences.codeFont(family: fontFamily, size: fontSize)
        if session.view.font.pointSize != fontSize || session.view.font.fontName != font.fontName {
            session.view.font = font
        }
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

/// "▶ dev" while a task runs (two or more: "▶ 2 tasks"); click for its tab, Restart or Stop.
private struct RunningTasksStatus: View {
    let store: TerminalStore

    var body: some View {
        let running = store.runningTasks.compactMap { id in store.sessions.first { $0.id == id } }
        Menu {
            ForEach(running) { session in
                Section(session.title) {
                    Button("Show Output") { store.reveal(session) }
                    if let url = session.output?.localURL, let browser = store.browser() {
                        Button("Open \(url.host() ?? "")\(url.port.map { ":\($0)" } ?? "") in Orbit") { browser.openBrowser(url) }
                    }
                    Button("Restart") { session.type(session.title) }
                    Button("Stop") { session.interrupt() }
                }
            }
        } label: {
            Label(running.count == 1 ? running[0].title : "\(running.count) tasks", systemImage: "play.fill")
                .orbitFont(.caption)
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Running tasks")
    }
}
