import OrbitKit
import SwiftUI

struct MainWindow: View {
    let host: PluginHost
    // The window's layout comes back on launch (D80). Each window has its own
    // (D101); the last one changed is what a new window starts with.
    @State private var sidebarPanelID = UserDefaults.standard.string(forKey: "orbit.sidebarPanel")
    @State private var inspectorPanelID = UserDefaults.standard.string(forKey: "orbit.inspectorPanel")
    @State private var showsInspector = UserDefaults.standard.object(forKey: "orbit.showsInspector") as? Bool ?? true
    @State private var columnVisibility = UserDefaults.standard.bool(forKey: "orbit.sidebarHidden")
        ? NavigationSplitViewVisibility.detailOnly : .all
    @State private var tabDrag = TabDrag()
    /// The part of the detail column under the floating sidebar.
    @State private var sidebarInset: CGFloat = 0

    private var workspace: Workspace { host.workspace }
    private var ui: UIRegistry { host.ui }

    var body: some View {
        // Settings replace the workspace view while shown (see SettingsScreen).
        Group {
            if ui.isSettingsVisible {
                SettingsScreen(host: host)
            } else if workspace.root == nil {
                ProjectPicker(host: host)
            } else {
                workspaceView
            }
        }
        .overlay(alignment: .top) {
            if let pick = ui.quickPick {
                QuickPickOverlay(pick: pick) { ui.dismissQuickPick() }
                    .id(pick.id)
            }
        }
        // A command run by mouse shows its shortcut, so it gets learned (D67).
        .overlay(alignment: .bottom) {
            CommandHintOverlay(commands: host.commands)
                .padding(.bottom, 44)
        }
        // A tab being dragged follows the pointer over the whole window (D91).
        .overlay { TabDragOverlay(workspace: workspace) }
        .overlay { TabSwitcherOverlay(workspace: workspace) }
        // The first launch's tour (D205), over everything, the top bar too.
        .overlay {
            if Onboarding.shared.isShowing(in: host) {
                OnboardingView(host: host)
                    .transition(.opacity)
            }
        }
        .environment(tabDrag)
        .onAppear {
            Onboarding.shared.windowAppeared(host)
            registerLayoutCommands()
            let services = host.services
            tabDrag.agent = { services.resolve(AgentTasks.self) }
        }
        .onChange(of: sidebarPanelID) { _, id in UserDefaults.standard.set(id, forKey: "orbit.sidebarPanel") }
        .onChange(of: inspectorPanelID) { _, id in UserDefaults.standard.set(id, forKey: "orbit.inspectorPanel") }
        .onChange(of: showsInspector) { _, shows in UserDefaults.standard.set(shows, forKey: "orbit.showsInspector") }
        // A theme being tried on brings its own mode (it only draws in that one).
        .onChange(of: appearance, initial: true) { _, appearance in
            NSApp.appearance = switch appearance {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
        .onChange(of: columnVisibility) { _, visibility in
            UserDefaults.standard.set(visibility == .detailOnly, forKey: "orbit.sidebarHidden")
        }
        .onChange(of: ui.requestedInspectorPanel) { _, id in
            guard let id else { return }
            ui.isSettingsVisible = false
            showsInspector = true
            inspectorPanelID = id
            ui.requestedInspectorPanel = nil
        }
        .onChange(of: ui.requestedSidebarPanel) { _, id in
            guard let id else { return }
            ui.isSettingsVisible = false
            columnVisibility = .all
            sidebarPanelID = id
            ui.requestedSidebarPanel = nil
        }
    }

    /// The window's own columns: macOS's ⌃⌘S for the sidebar, and ⌥⌘I (an
    /// inspector, as in Pages and Keynote) for the agents.
    private func registerLayoutCommands() {
        let columns = $columnVisibility, inspector = $showsInspector
        host.commands.register(OrbitCommand(
            id: "shell.toggleSidebar", title: "Toggle Sidebar", category: "View", systemImage: "sidebar.left",
            shortcut: KeyboardShortcut("s", modifiers: [.command, .control])
        ) {
            withAnimation { columns.wrappedValue = columns.wrappedValue == .detailOnly ? .all : .detailOnly }
        })
        host.commands.register(OrbitCommand(
            id: "shell.toggleAgents", title: "Toggle Agents", category: "View", systemImage: "sidebar.right",
            shortcut: KeyboardShortcut("i", modifiers: [.command, .option])
        ) {
            inspector.wrappedValue.toggle()
        })
        // Split editor (D90); ⌘\ as in VS Code and Zed.
        let workspace = workspace
        host.commands.register(OrbitCommand(
            id: "shell.splitEditor", title: "Split Editor", category: "View", systemImage: "rectangle.split.2x1",
            shortcut: KeyboardShortcut("\\", modifiers: .command),
            isEnabled: { workspace.activeTab != nil }
        ) { workspace.splitEditor() })
        host.commands.register(OrbitCommand(
            id: "shell.moveTabToOtherSide", title: "Move Tab to Other Side", category: "View", systemImage: "arrow.left.arrow.right",
            shortcut: KeyboardShortcut("\\", modifiers: [.command, .option]),
            isEnabled: { workspace.activeTab != nil && (workspace.isSplit || workspace.tabs.count > 1) }
        ) { workspace.moveActiveTabToOtherGroup() })
        host.commands.register(OrbitCommand(
            id: "shell.focusOtherSide", title: "Focus Other Side", category: "View", systemImage: "rectangle.righthalf.inset.filled",
            shortcut: KeyboardShortcut("\\", modifiers: [.command, .control]),
            isEnabled: { workspace.isSplit }
        ) { workspace.focusGroup(workspace.focusedGroup == 0 ? 1 : 0) })
        host.commands.register(OrbitCommand(
            id: "shell.joinEditors", title: "Join Editors", category: "View", systemImage: "rectangle",
            isEnabled: { workspace.isSplit }
        ) { workspace.joinGroups() })
        // Getting around by keyboard (D98): VS Code's and Cursor's keys on a Mac.
        host.commands.register(OrbitCommand(
            id: "shell.focusEditor", title: "Focus Editor", category: "View", systemImage: "character.cursor.ibeam",
            shortcut: KeyboardShortcut("1", modifiers: .command),
            isEnabled: { workspace.activeTab != nil }
        ) { workspace.focusEditor(group: 0) })
        host.commands.register(OrbitCommand(
            id: "shell.focusSecondSide", title: "Focus Right Side", category: "View", systemImage: "rectangle.righthalf.inset.filled",
            shortcut: KeyboardShortcut("2", modifiers: .command),
            isEnabled: { workspace.isSplit }
        ) { workspace.focusEditor(group: 1) })
        host.commands.register(OrbitCommand(
            id: "shell.nextTab", title: "Show Next Tab", category: "View", systemImage: "chevron.right",
            shortcut: KeyboardShortcut("]", modifiers: [.command, .shift]),
            isEnabled: { workspace.tabs.count > 1 }
        ) { workspace.showAdjacentTab(1) })
        host.commands.register(OrbitCommand(
            id: "shell.previousTab", title: "Show Previous Tab", category: "View", systemImage: "chevron.left",
            shortcut: KeyboardShortcut("[", modifiers: [.command, .shift]),
            isEnabled: { workspace.tabs.count > 1 }
        ) { workspace.showAdjacentTab(-1) })
        host.commands.register(OrbitCommand(
            id: "shell.reopenClosedTab", title: "Reopen Closed Tab", category: "View", systemImage: "arrow.uturn.backward",
            shortcut: KeyboardShortcut("t", modifiers: [.command, .shift]),
            isEnabled: { !workspace.closedFiles.isEmpty }
        ) { workspace.reopenClosedTab() })
        // Location history and recent tabs (D99): VS Code's keys on a Mac.
        TabSwitcher.shared.install()
        ShiftedKeys.shared.install()
        host.commands.register(OrbitCommand(
            id: "shell.goBack", title: "Go Back", category: "View", systemImage: "chevron.backward",
            shortcut: KeyboardShortcut("-", modifiers: .control),
            isEnabled: { !workspace.backLocations.isEmpty }
        ) { workspace.goBack() })
        host.commands.register(OrbitCommand(
            id: "shell.goForward", title: "Go Forward", category: "View", systemImage: "chevron.forward",
            shortcut: KeyboardShortcut("-", modifiers: [.control, .shift]),
            isEnabled: { !workspace.forwardLocations.isEmpty }
        ) { workspace.goForward() })
        host.commands.register(OrbitCommand(
            id: "shell.recentTab", title: "Show Recent Tab", category: "View", systemImage: "clock.arrow.circlepath",
            shortcut: KeyboardShortcut(.tab, modifiers: .control),
            isEnabled: { workspace.allTabs.count > 1 }
        ) { if let tab = workspace.recentTabs.dropFirst().first { workspace.open(tab) } })
    }

    private var appearance: Preferences.Appearance {
        if let theme = Extensions.shared.preview?.colorTheme { return theme.isDark ? .dark : .light }
        return Preferences.shared.appearance
    }

    private var workspaceView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarHost(panels: ui.sidebarPanels, selection: $sidebarPanelID)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 420)
                .background(SidebarWidthLimit(min: 200, max: 420))
                // Our own toggle is in the tab row; the system one floated over the sidebar.
                .toolbar(removing: .sidebarToggle)
        } detail: {
            EditorArea(host: host, columnVisibility: $columnVisibility, showsInspector: $showsInspector, sidebarInset: sidebarInset)
                .inspector(isPresented: $showsInspector) {
                    InspectorHost(panels: ui.inspectorPanels, selection: $inspectorPanelID)
                        .inspectorColumnWidth(min: 340, ideal: 420, max: 720)
                }
                .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.leading } action: { sidebarInset = $0 }
        }
        // The project's name alone: the Dock's and Window menu's window lists show it.
        .navigationTitle(workspace.name)
        .themedWindowBackground()
        // No toolbar (hidden title bar): the tab row sits next to the traffic
        // lights and carries the window buttons, sidebar toggle included. Even
        // empty, the toolbar kept an opaque grey title plate in full screen.
//EXP         .toolbarVisibility(.hidden, for: .windowToolbar)
        .background(TrafficLightsKeeper())
        .background(FullScreenCompositingGuard())
    }
}

// MARK: - Sidebar & inspector

/// Navigator-style host: a row of panel icons on top, the selected panel below.
struct SidebarHost: View {
    let panels: [PanelContribution]
    @Binding var selection: String?

    var body: some View {
        let current = panels.first { $0.id == selection } ?? panels.first
        VStack(spacing: 0) {
            if panels.count > 1 {
                HStack(spacing: 2) {
                    ForEach(panels) { panel in
                        PanelTabButton(panel: panel, isSelected: panel.id == current?.id) {
                            selection = panel.id
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
            if let current {
                current.makeView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyStateView("No Panels", systemImage: "puzzlepiece.extension")
            }
        }
        // See InspectorHost: split-view columns must not report fluctuating min sizes.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }
}

/// A navigator button, like Xcode 26's: a bare symbol, the selected one filled
/// in the accent color, the others brightening under the pointer (D169).
struct PanelTabButton: View {
    let panel: PanelContribution
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: panel.systemImage)
                .symbolVariant(isSelected ? .fill : .none)
                .orbitFont(.control, weight: .medium)
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : isHovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(maxWidth: .infinity, minHeight: 26)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .accessibilityLabel(panel.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(panelHelp(panel))
    }
}

/// A panel button's tooltip: its name, and the shortcut of the command showing it.
@MainActor
func panelHelp(_ panel: PanelContribution, _ text: String? = nil) -> String {
    guard let id = panel.commandID, let commands = ProjectWindows.shared.activeHost?.commands else { return text ?? panel.title }
    return commands.help(id, text ?? panel.title)
}

struct InspectorHost: View {
    let panels: [PanelContribution]
    @Binding var selection: String?
    @Environment(TabDrag.self) private var drag

    var body: some View {
        let current = panels.first { $0.id == selection } ?? panels.first
        VStack(spacing: 0) {
            if panels.count > 1 {
                Picker("Panel", selection: Binding(get: { current?.id ?? "" }, set: { selection = $0 })) {
                    ForEach(panels) { panel in
                        Label(panel.title, systemImage: panel.systemImage).tag(panel.id)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(8)
            }
            if let current {
                current.makeView()
                    // A tab dropped on the agent chat attaches its file (D91).
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                        drag.chatFrame = current.id == "agents" ? frame : nil
                    }
                    .onDisappear { drag.chatFrame = nil }
            } else {
                EmptyStateView("No Panels", systemImage: "puzzlepiece.extension")
            }
        }
        // Up into the hidden title bar like the editor area: a panel's own tab
        // row lines up with the editor tabs.
        .ignoresSafeArea(.container, edges: .top)
        // Plugin content must never push size constraints back into the split
        // view: fluctuating min sizes there send AppKit into a layout loop.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }
}

// MARK: - Editor area

struct EditorArea: View {
    let host: PluginHost
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @Binding var showsInspector: Bool
    let sidebarInset: CGFloat
    @State private var width: CGFloat = 0
    @State private var dropZone: EditorDropZone?
    @Environment(TabDrag.self) private var drag

    private var draggedTabZone: EditorDropZone? {
        if case .editor(let zone) = drag.target { zone } else { nil }
    }

    var body: some View {
        let workspace = host.workspace
        VStack(spacing: 0) {
            WindowTopBar(host: host, columnVisibility: $columnVisibility, showsInspector: $showsInspector, areaWidth: width, sidebarInset: sidebarInset)
            Divider()
            Group {
                if workspace.allTabs.isEmpty {
                    WelcomeView(host: host)
                } else if workspace.isSplit {
                    EditorGroups(host: host, width: width)
                } else {
                    GroupEditor(host: host, group: workspace.groups[0])
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { EditorDropHighlight(zone: dropZone ?? draggedTabZone, workspace: workspace) }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { drag.editorFrame = $0 }
            .overlay { EditorDropCatcher(workspace: workspace, zone: $dropZone) }
            .overlay(alignment: .bottom) { TryOnBar(host: host) }
            // SwiftUI scroll views draw into the safe area under the floating glass
            // sidebar and inspector, which then pick up their colors (green diff rows).
            .clipped()
            if host.ui.isBottomPanelVisible, !host.ui.bottomPanels.isEmpty {
                BottomPanelHost(ui: host.ui)
            }
            let statusItems = host.ui.statusItems.filter { $0.isVisible() }
            if !statusItems.isEmpty || !host.ui.bottomPanels.isEmpty {
                StatusBar(items: statusItems, ui: host.ui, commands: host.commands)
            }
        }
        // Up into the hidden title bar, so the tab row lines up with the traffic lights.
        .ignoresSafeArea(.container, edges: .top)
        // The split line runs through the tab row too: both measure from here.
        .coordinateSpace(.named(EditorGroups.space))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // Clears the floating sidebar by hand: its safe-area inset is cancelled
        // for this column (see SidebarInsetCanceller).
        .padding(.leading, sidebarInset)
        // Switching tabs swaps the editor view; its min size must not reach the
        // split view (constraint-loop crash, same as InspectorHost).
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        // The column's inherited inset is cancelled a run loop late
        // (SidebarInsetCanceller): for a frame after the sidebar opens it
        // counted on top of the padding and everything jumped twice as far,
        // then back. Ignored here, the padding alone clears the sidebar.
        .ignoresSafeArea(.container, edges: .leading)
        .nativeSurface(.background)
        .background(SidebarInsetCanceller(inset: sidebarInset))
    }
}

/// The shown tab of one group.
struct GroupEditor: View {
    let host: PluginHost
    let group: EditorGroup

    var body: some View {
        if let tab = group.activeTab {
            if let provider = host.ui.provider(for: tab) {
                provider.makeView(tab)
            } else {
                EmptyStateView("No Editor", systemImage: "questionmark.square.dashed", message: "No plugin can open \(tab.title).")
            }
        } else {
            Color.clear
        }
    }
}

/// Two groups side by side with a draggable line between them (D90). A click
/// into a group focuses it: AppKit text views swallow SwiftUI's tap gestures,
/// so mouse-downs are watched instead.
struct EditorGroups: View {
    nonisolated static let space = "editorArea"
    let host: PluginHost
    let width: CGFloat
    @State private var dragStart: Double?
    @State private var frame: CGRect = .zero
    @State private var monitor: Any?

    var body: some View {
        let workspace = host.workspace
        let left = (width * workspace.splitFraction).rounded()
        HStack(spacing: 0) {
            GroupEditor(host: host, group: workspace.groups[0])
                .frame(width: max(0, left))
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
                .overlay {
                    Color.clear
                        .frame(width: 7)
                        .contentShape(.rect)
                        .pointerStyle(.columnResize)
                        .gesture(resize)
                }
                .zIndex(1)
            GroupEditor(host: host, group: workspace.groups[1])
                .frame(maxWidth: .infinity)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        .onAppear(perform: watchClicks)
        .onDisappear {
            monitor.map(NSEvent.removeMonitor)
            monitor = nil
        }
    }

    private var resize: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { value in
                let workspace = host.workspace
                let start = dragStart ?? workspace.splitFraction
                dragStart = start
                guard width > 0 else { return }
                workspace.splitFraction = min(0.85, max(0.15, start + value.translation.width / width))
            }
            .onEnded { _ in dragStart = nil }
    }

    private func watchClicks() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            MainActor.assumeIsolated {
                guard let window = event.window, let content = window.contentView,
                      ProjectWindows.shared.host(for: window) === host else { return }
                // SwiftUI's global frame is the window's content, top-left origin.
                let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
                guard frame.contains(point) else { return }
                host.workspace.focusGroup(point.x < frame.minX + frame.width * host.workspace.splitFraction ? 0 : 1)
            }
            return event
        }
    }
}

/// The area under the editor (terminal, …) with a draggable top edge.
struct BottomPanelHost: View {
    let ui: UIRegistry
    @State private var height = UserDefaults.standard.object(forKey: "orbit.bottomPanelHeight") as? Double ?? 260
    @State private var dragStartHeight: Double?

    var body: some View {
        let current = ui.bottomPanels.first { $0.id == ui.selectedBottomPanel } ?? ui.bottomPanels.first
        VStack(spacing: 0) {
            Divider()
                .overlay {
                    // A taller invisible strip makes the 1 pt edge easy to grab.
                    Color.clear
                        .frame(height: 7)
                        .contentShape(.rect)
                        .pointerStyle(.rowResize)
                        .gesture(resizeGesture)
                }
                .zIndex(1)
            if let current {
                BottomPanelHeader(ui: ui, current: current)
                Divider()
                current.makeView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: height)
        .nativeSurface(.background)
        // Same rule as the split-view columns: no min sizes leaking upwards.
        .frame(minWidth: 0, minHeight: 0)
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let start = dragStartHeight ?? height
                dragStartHeight = start
                height = min(max(start - value.translation.height, 90), 900)
            }
            .onEnded { _ in
                dragStartHeight = nil
                UserDefaults.standard.set(height, forKey: "orbit.bottomPanelHeight")
            }
    }
}

/// The window's top row in place of a toolbar: editor tabs, command palette
/// and agents. Empty space in it drags the window.
struct WindowTopBar: View {
    let host: PluginHost
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @Binding var showsInspector: Bool
    /// The editor area's width: a split puts each group's tabs over its editor.
    let areaWidth: CGFloat
    /// How much of the window the sidebar covers right now (it slides).
    let sidebarInset: CGFloat
    @State private var tabsMinX: CGFloat = 0
    @State private var isFullScreen = false

    /// The traffic lights take the window's first 76 pt (not in full screen):
    /// the row clears what of them the sidebar doesn't cover.
    private static let windowedInset: CGFloat = 76
    private static let fullScreenInset: CGFloat = 6

    var body: some View {
        let sidebarHidden = columnVisibility == .detailOnly
        HStack(spacing: 4) {
            TopBarButton("sidebar.left", help: host.commands.help("shell.toggleSidebar", sidebarHidden ? "Show Sidebar" : "Hide Sidebar")) {
                withAnimation { columnVisibility = sidebarHidden ? .all : .detailOnly }
            }
            let workspace = host.workspace
            if workspace.allTabs.isEmpty {
                Spacer(minLength: 0)
            } else if workspace.isSplit {
                // The left group's tabs end where its editor does.
                let leftWidth = max(60, (areaWidth * workspace.splitFraction).rounded() - tabsMinX)
                HStack(spacing: 0) {
                    TabBar(workspace: workspace, group: workspace.groups[0])
                        .frame(width: leftWidth)
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: 1, height: 16)
                    TabBar(workspace: workspace, group: workspace.groups[1])
                }
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(EditorGroups.space)).minX } action: { tabsMinX = $0 }
            } else {
                TabBar(workspace: workspace, group: workspace.groups[0])
            }
            TopBarButton("command", help: "Command Palette (⇧⌘P)") {
                CommandPalette.toggle(in: host)
            }
            TopBarButton("sidebar.right", help: host.commands.help("shell.toggleAgents", showsInspector ? "Hide Agents" : "Show Agents")) {
                showsInspector.toggle()
            }
        }
        // Follows the sliding sidebar frame by frame (D104). Switched on the
        // visibility flag, it jumped at the start of the slide and animated
        // on its own clock, so the tabs went one way and then the other.
        .padding(.leading, isFullScreen ? Self.fullScreenInset : max(Self.fullScreenInset, Self.windowedInset - sidebarInset))
        .padding(.trailing, 8)
        .frame(height: Theme.topBarHeight)
        .background {
            Color.clear
                .contentShape(.rect)
                .gesture(WindowDragGesture())
        }
        .background(FullScreenObserver(isFullScreen: $isFullScreen))
    }
}

/// The sidebar's width limits, enforced on the AppKit split view item.
/// SwiftUI ignores `navigationSplitViewColumnWidth` here and resets the item to
/// its own defaults (no max) when a drag starts. Without a max the sidebar could
/// be dragged until the detail column (which runs under the sidebar, so its min
/// width grows with it) no longer fit the screen: the window bounced between
/// two widths and AppKit crashed in an update-constraints loop.
private struct SidebarWidthLimit: NSViewRepresentable {
    let min: CGFloat
    let max: CGFloat

    func makeNSView(context: Context) -> LimitView { LimitView() }

    func updateNSView(_ view: LimitView, context: Context) {
        view.limits = (min, max)
        DispatchQueue.main.async { [weak view] in view?.apply() }
    }

    final class LimitView: NSView {
        var limits: (min: CGFloat, max: CGFloat) = (0, .greatestFiniteMagnitude)
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observer.map(NotificationCenter.default.removeObserver)
            observer = nil
            guard let window else { return }
            // Re-applied on every split view resize: SwiftUI's reset comes with a drag.
            observer = NotificationCenter.default.addObserver(forName: NSSplitView.willResizeSubviewsNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.window === window else { return }
                    self.apply()
                }
            }
            // After SwiftUI has built the split view around us.
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        func apply() {
            var view = superview
            while let current = view {
                if let split = current as? NSSplitView,
                   let controller = split.delegate as? NSSplitViewController,
                   let item = controller.splitViewItems.first(where: { isDescendant(of: $0.viewController.view) }) {
                    // Only on a real change: each write re-lays out the split view.
                    if item.minimumThickness != limits.min { item.minimumThickness = limits.min }
                    if item.maximumThickness != limits.max { item.maximumThickness = limits.max }
                    return
                }
                view = current.superview
            }
        }

        isolated deinit {
            observer.map(NotificationCenter.default.removeObserver)
        }
    }
}

/// The inspector's split view runs under the floating sidebar and inherits its
/// safe-area inset. SwiftUI counts that inset into the editor column's min width,
/// and the outer split view adds it again: with the sidebar and inspector open, a
/// window narrower than 2 × sidebar + inspector looped and crashed (D104). The
/// inherited inset is cancelled here; `EditorArea` pads itself instead.
private struct SidebarInsetCanceller: NSViewRepresentable {
    let inset: CGFloat

    func makeNSView(context: Context) -> CancellerView { CancellerView() }

    func updateNSView(_ view: CancellerView, context: Context) {
        view.inset = inset
        DispatchQueue.main.async { [weak view] in view?.apply() }
    }

    final class CancellerView: NSView {
        var inset: CGFloat = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        func apply() {
            var view = superview
            while let current = view {
                if let split = current as? NSSplitView,
                   let controller = split.delegate as? NSSplitViewController,
                   controller.splitViewItems.contains(where: { $0.behavior == .inspector }) {
                    var insets = controller.view.additionalSafeAreaInsets
                    // Only on a real change: each write re-lays out the split view.
                    guard insets.left != -inset else { return }
                    insets.left = -inset
                    controller.view.additionalSafeAreaInsets = insets
                    return
                }
                view = current.superview
            }
        }
    }
}

/// Hiding the window toolbar also hides the title bar container, and the
/// traffic lights with it. The container is transparent anyway (hidden title
/// bar), so it is shown again, and again whenever AppKit hides it.
/// Not in full screen: there the container moves into a separate toolbar
/// window with an opaque background (a grey plate over the tab row), and
/// there are no traffic lights to keep anyway.
private struct TrafficLightsKeeper: NSViewRepresentable {
    func makeNSView(context: Context) -> KeeperView { KeeperView() }
    func updateNSView(_ view: KeeperView, context: Context) {}

    final class KeeperView: NSView {
        /// How far the traffic lights sit below where AppKit puts them, to
        /// line up with the tab row.
        static let trafficLightsDrop: CGFloat = 5

        private var observations: [NSKeyValueObservation] = []
        private var observers: [NSObjectProtocol] = []
        private var buttonObservers: [NSObjectProtocol] = []
        private var layerObservations: [NSKeyValueObservation] = []
        private var isAligningLayer = false
        private weak var container: NSView?
        private weak var titlebar: NSView?
        /// AppKit's own y for each button, kept on the button itself: a new
        /// keeper (Close Folder rebuilds the view) must not take an already
        /// moved button for AppKit's position.
        nonisolated(unsafe) private static var baselineKey: UInt8 = 0
        private var clickMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observations = []
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let names: [Notification.Name] = [
                NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification,
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.enforce() }
                }
            }
            // After SwiftUI has configured the window.
            DispatchQueue.main.async { [weak self] in self?.attach() }
            watchFullScreenClicks()
        }

        /// In full screen the revealed traffic lights ignored clicks: with the
        /// toolbar hidden (D42) AppKit treats its strip as empty and lets clicks
        /// through to the window below. Clicks on the buttons' spots are
        /// caught here and do what the buttons would.
        private func watchFullScreenClicks() {
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                let handled = MainActor.assumeIsolated { self?.handleFullScreenClick() ?? false }
                return handled ? nil : event
            }
        }

        private func handleFullScreenClick() -> Bool {
            guard isFullScreen, let window else { return false }
            let point = NSEvent.mouseLocation
            for button in buttons where !button.isHidden && button.isEnabled {
                guard let host = button.window, host.isVisible, host.alphaValue > 0.01,
                      let screen = host.screen ?? window.screen else { continue }
                let rect = host.convertToScreen(button.convert(button.bounds, to: nil))
                // Hidden (slid up past the screen's top) until the menu bar is revealed.
                guard rect.contains(point), screen.frame.contains(rect) else { continue }
                if button == window.standardWindowButton(.closeButton) {
                    window.performClose(nil)
                } else if button == window.standardWindowButton(.zoomButton) {
                    window.toggleFullScreen(nil)
                } else {
                    continue
                }
                return true
            }
            return false
        }

        private var isFullScreen: Bool {
            window?.styleMask.contains(.fullScreen) ?? false
        }

        private func attach() {
            guard let titlebar = window?.standardWindowButton(.closeButton)?.superview,
                  let container = titlebar.superview else { return }
            self.titlebar = titlebar
            self.container = container
            observations = [
                container.observe(\.isHidden, options: [.initial, .new]) { [weak self] _, _ in
                    DispatchQueue.main.async { self?.enforce() }
                },
                titlebar.observe(\.alphaValue, options: [.initial, .new]) { [weak self] _, _ in
                    DispatchQueue.main.async { self?.enforce() }
                },
            ]
            // AppKit puts the buttons back on every titlebar layout (resize,
            // focus, full screen, `isMovable` flipping while tabs are dragged):
            // move them again right away. Deferred, they showed at AppKit's
            // spot for a frame and jumped up and down.
            buttonObservers.forEach(NotificationCenter.default.removeObserver)
            buttonObservers = buttons.map { button in
                button.postsFrameChangedNotifications = true
                return NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: button, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.shiftButtons()
                        // AppKit may still set the frame it was in the middle of.
                        DispatchQueue.main.async { self?.shiftButtons() }
                    }
                }
            }
            // While the window is dragged, AppKit re-places the zoom button on
            // every step but posts its frame change only after drawing: it showed
            // at AppKit's spot for the whole drag. Its layer moves synchronously,
            // so the layer is put right before the frame catches up.
            layerObservations = buttons.compactMap { button in
                button.layer?.observe(\.position) { [weak self, weak button] _, _ in
                    MainActor.assumeIsolated {
                        guard let self, let button else { return }
                        self.alignLayer(of: button)
                    }
                }
            }
            shiftButtons()
        }

        private var buttons: [NSButton] {
            [.closeButton, .miniaturizeButton, .zoomButton].compactMap { window?.standardWindowButton($0) }
        }

        /// A fixed distance below AppKit's spot for the button. Absolute, so
        /// applying it again (our own move posts a frame change too) is a no-op,
        /// and a button can't end up moved twice or not at all.
        private func target(for button: NSButton) -> CGFloat {
            let baseline: CGFloat
            if let stored = objc_getAssociatedObject(button, &Self.baselineKey) as? CGFloat {
                baseline = stored
            } else {
                baseline = button.frame.origin.y
                objc_setAssociatedObject(button, &Self.baselineKey, baseline, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
            return (button.superview?.isFlipped ?? false) ? baseline + Self.trafficLightsDrop : baseline - Self.trafficLightsDrop
        }

        private func shiftButtons() {
            guard !isFullScreen else { return }
            for button in buttons {
                let target = target(for: button)
                if button.frame.origin.y != target {
                    button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: target))
                }
            }
        }

        /// Moves only the layer of a button AppKit has just placed (its frame
        /// still at AppKit's spot); the frame follows in `shiftButtons`.
        private func alignLayer(of button: NSButton) {
            guard !isAligningLayer, !isFullScreen, let layer = button.layer else { return }
            let delta = target(for: button) - button.frame.origin.y
            guard delta != 0 else { return }
            isAligningLayer = true
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.position.y += delta
            CATransaction.commit()
            isAligningLayer = false
        }

        /// Only writes on a real change: window chrome touched mid-layout
        /// sends AppKit into a constraint loop.
        private func enforce() {
            guard let container, let titlebar else { return }
            if isFullScreen {
                if container.isHidden { container.isHidden = false }
                if let toolbarWindow = container.window, toolbarWindow !== window, toolbarWindow.isOpaque {
                    toolbarWindow.isOpaque = false
                    toolbarWindow.backgroundColor = .clear
                }
            } else {
                if container.isHidden { container.isHidden = false }
                if titlebar.alphaValue < 1 { titlebar.alphaValue = 1 }
                shiftButtons()
            }
        }

        isolated deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
            buttonObservers.forEach(NotificationCenter.default.removeObserver)
            clickMonitor.map(NSEvent.removeMonitor)
        }
    }
}

/// Alone in full screen on the built-in ProMotion display (its title bar
/// hidden), the window is flipped straight to the display and scrolling
/// drops to ~60 fps; with anything over it (the revealed title bar, Xcode's
/// always-visible toolbar) it's composited and smooth. A 1-pt, all but
/// transparent child window keeps it composited.
private struct FullScreenCompositingGuard: NSViewRepresentable {
    func makeNSView(context: Context) -> GuardView { GuardView() }
    func updateNSView(_ view: GuardView, context: Context) {}

    final class GuardView: NSView {
        private var observers: [NSObjectProtocol] = []
        private var overlay: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            remove()
            guard let window else { return }
            let names: [Notification.Name] = [
                NSWindow.didEnterFullScreenNotification, NSWindow.willExitFullScreenNotification,
                NSWindow.didChangeScreenNotification, NSWindow.didResizeNotification,
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    let exiting = note.name == NSWindow.willExitFullScreenNotification
                    MainActor.assumeIsolated { self?.update(exiting: exiting) }
                }
            }
            DispatchQueue.main.async { [weak self] in self?.update(exiting: false) }
        }

        private func update(exiting: Bool) {
            guard let window, !exiting, window.styleMask.contains(.fullScreen) else {
                remove()
                return
            }
            let frame = NSRect(x: window.frame.minX, y: window.frame.minY, width: 1, height: 1)
            if let overlay {
                if overlay.frame != frame { overlay.setFrame(frame, display: false) }
                return
            }
            let overlay = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            overlay.isReleasedWhenClosed = false
            overlay.isOpaque = false
            overlay.hasShadow = false
            overlay.ignoresMouseEvents = true
            // Fully clear windows are skipped by the compositor; this one must count.
            overlay.backgroundColor = NSColor.black.withAlphaComponent(0.01)
            overlay.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
            window.addChildWindow(overlay, ordered: .above)
            self.overlay = overlay
        }

        private func remove() {
            guard let overlay else { return }
            overlay.parent?.removeChildWindow(overlay)
            overlay.orderOut(nil)
            self.overlay = nil
        }

        isolated deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
            overlay?.orderOut(nil)
        }
    }
}

/// Whether the hosting window is full screen (no traffic lights then).
private struct FullScreenObserver: NSViewRepresentable {
    @Binding var isFullScreen: Bool

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onChange = { isFullScreen = $0 }
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {}

    final class ObserverView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let names: [Notification.Name] = [
                NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification,
                NSWindow.willExitFullScreenNotification, NSWindow.didExitFullScreenNotification,
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    let entering = note.name == NSWindow.willEnterFullScreenNotification
                        || note.name == NSWindow.didEnterFullScreenNotification
                    MainActor.assumeIsolated { self?.report(entering) }
                }
            }
            // Outside the current SwiftUI update.
            let isFull = window.styleMask.contains(.fullScreen)
            DispatchQueue.main.async { [weak self] in self?.report(isFull) }
        }

        private func report(_ isFull: Bool) { onChange?(isFull) }

        isolated deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

struct TabBar: View {
    let workspace: Workspace
    let group: EditorGroup
    @State private var frames: [EditorTab.ID: CGRect] = [:]
    @State private var insertion: Int?
    @Environment(TabDrag.self) private var drag

    var body: some View {
        // In a split, the side without focus is quieter.
        let isFocused = !workspace.isSplit || workspace.groups[workspace.focusedGroup].id == group.id
        // The row's width from outside the scroll view: measured on it, the
        // tabs' min width fed back into its size and the layout never settled.
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    row(isFocused: isFocused, width: geometry.size.width)
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { drag.rows[group.id] = $0 }
                .onDisappear {
                    drag.rows[group.id] = nil
                    drag.tabFrames[group.id] = nil
                }
                .modifier(TabRowFade())
                .scrollsToActiveTab(group.activeTabID, in: proxy)
                // A drop that ends elsewhere (or a move that re-lays the row) never calls dropExited here.
                .onChange(of: group.tabs) { insertion = nil }
                .onChange(of: workspace.allTabs.count) { insertion = nil }
            }
        }
    }

    private var rowSpace: String { "tabRow-\(group.id)" }

    private func row(isFocused: Bool, width: CGFloat) -> some View {
        HStack(spacing: 2) {
            ForEach(group.tabs) { tab in
                item(tab)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        // Tabs slide into place on open, close and a dropped reorder. Only the
        // id order is animated, never the live drag: TabDrag draws its own chip
        // and line from the frames the tabs report (D91).
        .animation(.snappy(duration: 0.22), value: group.tabs.map(\.id))
        .opacity(isFocused ? 1 : 0.65)
        .padding(.horizontal, 8)
        // The free space after the tabs is title bar: it drags the window.
        .frame(minWidth: width, maxHeight: .infinity, alignment: .leading)
        .background {
            Color.clear
                .contentShape(.rect)
                .gesture(WindowDragGesture())
        }
        .overlay(alignment: .topLeading) { insertionMark }
        .coordinateSpace(.named(rowSpace))
        .onDrop(of: [.fileURL], delegate: TabRowDropDelegate(workspace: workspace, group: group, frames: frames, insertion: $insertion))
    }

    /// A tab, reporting where it is: in the row (file drops) and the window (tab drags).
    private func item(_ tab: EditorTab) -> some View {
        let space = rowSpace, groupID = group.id, drag = drag
        return TabItem(tab: tab, group: group, workspace: workspace)
            .id(tab.id)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(space)) } action: { frames[tab.id] = $0 }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                drag.tabFrames[groupID, default: [:]][tab.id] = $0
            }
    }

    /// Where a dropped tab will land: a line between two tabs.
    @ViewBuilder private var insertionMark: some View {
        if let insertion {
            let tabs = group.tabs.compactMap { frames[$0.id] }
            let x = insertion < tabs.count ? tabs[insertion].minX - 1 : (tabs.last?.maxX ?? 8) + 1
            Capsule()
                .fill(Theme.accent)
                .frame(width: 2, height: 18)
                .offset(x: x - 1, y: ((tabs.first?.midY ?? 13) - 9))
                .allowsHitTesting(false)
        }
    }
}

struct TabItem: View {
    let tab: EditorTab
    let group: EditorGroup
    let workspace: Workspace

    var body: some View {
        let isDirty = tab.url.flatMap { workspace.documents.existingDocument(for: $0) }?.isDirty == true
            && tab.kind == EditorTab.fileKind
        TabChip(tab.title, isActive: group.activeTabID == tab.id, isDirty: isDirty, isPreview: group.previewTabID == tab.id) {
            workspace.activate(tab.id, in: group.id)
        } onClose: {
            workspace.requestClose(tab.id, in: group.id)
        } icon: {
            Group {
                if tab.kind == EditorTab.fileKind, let url = tab.url {
                    FileIconView(url: url, size: 13)
                } else {
                    Image(systemName: tab.systemImage)
                }
            }
            .foregroundStyle(tab.kind == EditorTab.fileKind ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
        }
        .help(tab.url.map(workspace.relativePath) ?? tab.title)
        // A preview tab stays once it's double-clicked or edited (D94).
        .simultaneousGesture(TapGesture(count: 2).onEnded { workspace.pin(tab.id) })
        .onChange(of: isDirty) { _, dirty in if dirty { workspace.pin(tab.id) } }
        .modifier(TabDragGesture(tab: tab, group: group.id, workspace: workspace))
        .modifier(KeepsWindowStillWhileHovered())
        .contextMenu {
            if group.previewTabID == tab.id {
                Button("Keep Open") { workspace.pin(tab.id) }
                Divider()
            }
            Button("Close") { workspace.requestClose(tab.id, in: group.id) }
            Button("Close Others") {
                for other in group.tabs where other.id != tab.id { workspace.requestClose(other.id, in: group.id) }
            }
            Divider()
            Button(workspace.isSplit ? "Move to Other Side" : "Move to the Right") {
                workspace.activate(tab.id, in: group.id)
                workspace.moveActiveTabToOtherGroup()
            }
            .disabled(!workspace.isSplit && group.tabs.count < 2)
            Button("Open to the Side") {
                workspace.activate(tab.id, in: group.id)
                workspace.splitEditor()
            }
            if let url = tab.url {
                Divider()
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }
}

/// The bottom area's top row: a tab per panel (with its count), then on the
/// trailing side the shown panel's own controls (New Terminal) and Hide.
struct BottomPanelHeader: View {
    let ui: UIRegistry
    let current: PanelContribution

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ui.bottomPanels) { panel in
                BottomPanelTab(panel: panel, isSelected: panel.id == current.id) {
                    ui.revealBottomPanel(panel.id)
                }
            }
            Spacer(minLength: 0)
            if let accessory = current.makeAccessory {
                accessory()
                    .foregroundStyle(.secondary)
            }
            IconButton("chevron.down", help: "Hide Panel") {
                ui.isBottomPanelVisible = false
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
    }
}

private struct BottomPanelTab: View {
    let panel: PanelContribution
    let isSelected: Bool
    let select: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 5) {
                Image(systemName: panel.systemImage)
                    .orbitFont(.micro)
                Text(panel.title)
                    .orbitFont(.caption, weight: isSelected ? .medium : .regular)
                if let badge = panel.badge?() {
                    PanelBadgeView(badge: badge)
                }
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(isSelected ? Theme.activeFill : isHovered ? Theme.hoverFill : .clear, in: .rect(cornerRadius: Theme.smallCorner))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(panelHelp(panel))
    }
}

struct PanelBadgeView: View {
    let badge: PanelBadge

    var body: some View {
        Badge(count: badge.count, tint: tint)
    }

    private var tint: Color? {
        switch badge.style {
        case .plain: nil
        case .error: .red
        case .warning: .orange
        }
    }
}

/// The status bar's leading end, as quiet as Xcode's: one button that shows or
/// hides the bottom area (its tabs say what's in it), and the errors or
/// warnings a panel reports, which open that panel (D170).
private struct BottomPanelToggles: View {
    let ui: UIRegistry

    var body: some View {
        HStack(spacing: 10) {
            Button {
                ui.isBottomPanelVisible.toggle()
            } label: {
                Image(systemName: "rectangle.bottomthird.inset.filled")
                    .orbitFont(.caption)
                    .foregroundStyle(ui.isBottomPanelVisible ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(ui.isBottomPanelVisible ? "Hide Panel" : "Show Panel")
            .accessibilityLabel(ui.isBottomPanelVisible ? "Hide Panel" : "Show Panel")
            ForEach(ui.bottomPanels) { panel in
                if let badge = panel.badge?(), badge.style != .plain {
                    Button {
                        ui.revealBottomPanel(panel.id)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: badge.style == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(badge.style == .error ? .red : .yellow)
                            Text("\(badge.count)")
                                .monospacedDigit()
                                .contentTransition(.numericText(value: Double(badge.count)))
                                .foregroundStyle(.secondary)
                        }
                        .orbitFont(.caption)
                        .animation(.snappy, value: badge.count)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(panelHelp(panel))
                    .transition(.opacity)
                }
            }
        }
    }
}

struct StatusBar: View {
    let items: [StatusItem]
    let ui: UIRegistry
    let commands: CommandRegistry

    var body: some View {
        HStack(spacing: 14) {
            if !ui.bottomPanels.isEmpty {
                BottomPanelToggles(ui: ui)
            }
            ForEach(items.filter { $0.placement == .leading }) { $0.makeView() }
            Spacer()
            ForEach(items.filter { $0.placement == .trailing }) { $0.makeView() }
            CheatSheetButton(commands: commands, ui: ui)
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
        .nativeSurface(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// The editor area with nothing open, quiet like Xcode's "No Editor" (D166):
/// the project's name and a few shortcuts as plain text, no card.
struct WelcomeView: View {
    let host: PluginHost

    var body: some View {
        let workspace = host.workspace
        VStack(spacing: 26) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .padding(.bottom, 4)
                Text(workspace.root == nil ? "Orbit" : workspace.name)
                    .orbitFont(.large, weight: .semibold)
                Text(workspace.root == nil ? "Open a folder to start working with agents." : "Open a file or start an agent session.")
                    .orbitFont(.control)
                    .foregroundStyle(.secondary)
            }

            // Sized to its rows, so the block centers on its real width.
            Grid(horizontalSpacing: 14, verticalSpacing: 8) {
                if workspace.root == nil {
                    WelcomeActionRow(command: host.commands.all.first { $0.id == "workspace.openFolder" })
                }
                WelcomeActionRow(command: host.commands.all.first { $0.id == "agents.new" })
                WelcomeActionRow(command: host.commands.all.first { $0.id == "agents.focus" })
                if workspace.root != nil {
                    WelcomeActionRow(command: host.commands.all.first { $0.id == "search.quickOpen" })
                }
                WelcomeActionRow(title: "Command Palette", shortcut: "⇧⌘P") {
                    CommandPalette.toggle(in: host)
                }
            }
        }
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// "New Agent Session   ⇧⌘N": a row of `WelcomeView`'s grid, the name
/// right-aligned and its shortcut left-aligned, quiet until hovered.
struct WelcomeActionRow: View {
    let title: String
    let shortcut: String?
    let isEnabled: Bool
    let action: () -> Void
    @State private var isHovering = false

    init(title: String, shortcut: String?, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.shortcut = shortcut
        self.isEnabled = isEnabled
        self.action = action
    }

    init(command: OrbitCommand?) {
        self.init(
            title: command?.title ?? "",
            shortcut: command?.displayShortcut?.displayString,
            isEnabled: command?.isEnabled() ?? false,
            action: { command?.run() }
        )
    }

    var body: some View {
        GridRow {
            cell(Text(title))
                .gridColumnAlignment(.trailing)
            cell(Text(shortcut ?? "").tracking(1.5).foregroundStyle(isHovering && isEnabled ? .secondary : .tertiary))
                .gridColumnAlignment(.leading)
        }
        .orbitFont(.control)
        .foregroundStyle(isHovering && isEnabled ? .primary : .secondary)
        .opacity(isEnabled ? 1 : 0.45)
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    /// Either half of the row hovers and clicks as the whole row.
    private func cell(_ content: some View) -> some View {
        content
            .contentShape(.rect)
            .onHover { isHovering = $0 }
            .onTapGesture { if isEnabled { action() } }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(title)
    }
}

/// "⇧⌘P" rendered as individual key caps.
struct KeyCaps: View {
    let keys: [String]

    init(_ shortcut: String) {
        // Modifiers one cap each, the key ("Space", "↩", "K") one cap.
        let modifiers = shortcut.prefix { "⌃⌥⇧⌘".contains($0) }
        let key = shortcut.dropFirst(modifiers.count)
        keys = modifiers.map(String.init) + (key.isEmpty ? [] : [String(key)])
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .orbitFont(.caption, weight: .medium)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 18, minHeight: 18)
                    .padding(.horizontal, key.count > 1 ? 4 : 0)
                    .background(Theme.activeFill, in: .rect(cornerRadius: Theme.smallCorner))
            }
        }
    }
}
