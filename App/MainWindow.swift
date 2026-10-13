import OrbitKit
import SwiftUI

struct MainWindow: View {
    let host: PluginHost
    @State private var sidebarPanelID: String?
    @State private var inspectorPanelID: String?
    @State private var showsInspector = true
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @Environment(\.openWindow) private var openWindow

    private var workspace: Workspace { host.workspace }
    private var ui: UIRegistry { host.ui }

    var body: some View {
        // Settings replace the workspace view while shown (see SettingsScreen).
        Group {
            if ui.isSettingsVisible {
                SettingsScreen(host: host)
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
        .onAppear {
            AppDelegate.reopenMainWindow = { openWindow(id: "main") }
            registerLayoutCommands()
        }
        // A theme being tried on brings its own mode (it only draws in that one).
        .onChange(of: appearance, initial: true) { _, appearance in
            NSApp.appearance = switch appearance {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
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
    }

    private var appearance: Preferences.Appearance {
        if let theme = Extensions.shared.preview?.colorTheme { return theme.isDark ? .dark : .light }
        return Preferences.shared.appearance
    }

    private var subtitle: String {
        workspace.activeTab?.url.map(workspace.relativePath) ?? ""
    }

    private var workspaceView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarHost(panels: ui.sidebarPanels, selection: $sidebarPanelID)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 420)
                .background(SidebarWidthLimit(min: 200, max: 420))
                // Our own toggle is in the tab row; the system one floated over the sidebar.
                .toolbar(removing: .sidebarToggle)
        } detail: {
            EditorArea(host: host, columnVisibility: $columnVisibility, showsInspector: $showsInspector)
                .inspector(isPresented: $showsInspector) {
                    InspectorHost(panels: ui.inspectorPanels, selection: $inspectorPanelID)
                        .inspectorColumnWidth(min: 340, ideal: 420, max: 720)
                }
        }
        .navigationTitle(workspace.name)
        .navigationSubtitle(subtitle)
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

struct PanelTabButton: View {
    let panel: PanelContribution
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: panel.systemImage)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(maxWidth: .infinity, minHeight: 26)
                .background(isSelected ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 7))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(panelHelp(panel))
    }
}

/// A panel button's tooltip: its name, and the shortcut of the command showing it.
@MainActor
func panelHelp(_ panel: PanelContribution, _ text: String? = nil) -> String {
    guard let id = panel.commandID, let commands = AppDelegate.host?.commands else { return text ?? panel.title }
    return commands.help(id, text ?? panel.title)
}

struct InspectorHost: View {
    let panels: [PanelContribution]
    @Binding var selection: String?

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

    var body: some View {
        let workspace = host.workspace
        VStack(spacing: 0) {
            WindowTopBar(host: host, columnVisibility: $columnVisibility, showsInspector: $showsInspector)
            Divider()
            Group {
                if let tab = workspace.activeTab {
                    if let provider = host.ui.provider(for: tab) {
                        provider.makeView(tab)
                    } else {
                        EmptyStateView("No Editor", systemImage: "questionmark.square.dashed", message: "No plugin can open \(tab.title).")
                    }
                } else {
                    WelcomeView(host: host)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) { TryOnBar(host: host) }
            // SwiftUI scroll views draw into the safe area under the floating glass
            // sidebar and inspector, which then pick up their colors (green diff rows).
            .clipped()
            if host.ui.isBottomPanelVisible, !host.ui.bottomPanels.isEmpty {
                BottomPanelHost(ui: host.ui)
            }
            let statusItems = host.ui.statusItems.filter { $0.isVisible() }
            if !statusItems.isEmpty || !host.ui.bottomPanels.isEmpty {
                StatusBar(items: statusItems, ui: host.ui)
            }
        }
        // Up into the hidden title bar, so the tab row lines up with the traffic lights.
        .ignoresSafeArea(.container, edges: .top)
        // Switching tabs swaps the editor view; its min size must not reach the
        // split view (constraint-loop crash, same as InspectorHost).
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .nativeSurface(.background)
    }
}

/// The area under the editor (terminal, …) with a draggable top edge.
struct BottomPanelHost: View {
    let ui: UIRegistry
    @AppStorage("orbit.bottomPanelHeight") private var height: Double = 260
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
            .onEnded { _ in dragStartHeight = nil }
    }
}

/// The window's top row in place of a toolbar: editor tabs, command palette
/// and agents. Empty space in it drags the window.
struct WindowTopBar: View {
    let host: PluginHost
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @Binding var showsInspector: Bool
    @State private var isFullScreen = false

    /// With the sidebar hidden, the traffic lights sit over the start of this
    /// row (not in full screen).
    private static let windowedInset: CGFloat = 76
    private static let fullScreenInset: CGFloat = 6

    var body: some View {
        let sidebarHidden = columnVisibility == .detailOnly
        HStack(spacing: 4) {
            TopBarButton("sidebar.left", help: host.commands.help("shell.toggleSidebar", sidebarHidden ? "Show Sidebar" : "Hide Sidebar")) {
                withAnimation { columnVisibility = sidebarHidden ? .all : .detailOnly }
            }
            if host.workspace.tabs.isEmpty {
                Spacer(minLength: 0)
            } else {
                TabBar(workspace: host.workspace)
            }
            TopBarButton("command", help: "Command Palette (⇧⌘P)") {
                CommandPalette.toggle(in: host)
            }
            TopBarButton("sidebar.right", help: host.commands.help("shell.toggleAgents", showsInspector ? "Hide Agents" : "Show Agents")) {
                showsInspector.toggle()
            }
        }
        .padding(.leading, sidebarHidden ? (isFullScreen ? Self.fullScreenInset : Self.windowedInset) : 6)
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
        private weak var container: NSView?
        private weak var titlebar: NSView?
        /// The y we last moved each button to; anything else is AppKit's own layout.
        private var shiftedY: [ObjectIdentifier: CGFloat] = [:]

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
            // focus, full screen): move them again after each one.
            buttonObservers.forEach(NotificationCenter.default.removeObserver)
            buttonObservers = buttons.map { button in
                button.postsFrameChangedNotifications = true
                return NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: button, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        DispatchQueue.main.async { self?.shiftButtons() }
                    }
                }
            }
            shiftButtons()
        }

        private var buttons: [NSButton] {
            [.closeButton, .miniaturizeButton, .zoomButton].compactMap { window?.standardWindowButton($0) }
        }

        /// Only moves a button AppKit has just laid out, so our own move
        /// (which posts a frame change too) doesn't feed back.
        private func shiftButtons() {
            guard !isFullScreen else { return }
            for button in buttons {
                let id = ObjectIdentifier(button)
                let y = button.frame.origin.y
                guard shiftedY[id] != y else { continue }
                let target = (button.superview?.isFlipped ?? false) ? y + Self.trafficLightsDrop : y - Self.trafficLightsDrop
                shiftedY[id] = target
                button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: target))
            }
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
    @State private var width: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(workspace.tabs) { tab in
                        TabItem(tab: tab, workspace: workspace)
                            .id(tab.id)
                    }
                }
                .padding(.horizontal, 8)
                // The free space after the tabs is title bar: it drags the window.
                .frame(minWidth: width, maxHeight: .infinity, alignment: .leading)
                .background {
                    Color.clear
                        .contentShape(.rect)
                        .gesture(WindowDragGesture())
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .modifier(TabRowFade())
            .scrollsToActiveTab(workspace.activeTabID, in: proxy)
        }
    }
}

struct TabItem: View {
    let tab: EditorTab
    let workspace: Workspace

    var body: some View {
        let isDirty = tab.url.flatMap { workspace.documents.existingDocument(for: $0) }?.isDirty == true
            && tab.kind == EditorTab.fileKind
        TabChip(tab.title, isActive: workspace.activeTabID == tab.id, isDirty: isDirty) {
            workspace.activeTabID = tab.id
        } onClose: {
            workspace.requestClose(tab.id)
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
        .contextMenu {
            Button("Close") { workspace.requestClose(tab.id) }
            Button("Close Others") {
                for other in workspace.tabs where other.id != tab.id { workspace.requestClose(other.id) }
            }
            if let url = tab.url {
                Divider()
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }
}

/// The bottom area's top row: a tab per panel (with its count), the shown
/// panel's own controls (terminal tabs), and Hide.
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
            if let accessory = current.makeAccessory {
                Divider()
                    .frame(height: 14)
                    .padding(.horizontal, 6)
                accessory()
            }
            Spacer(minLength: 0)
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
                    .font(.system(size: 10))
                Text(panel.title)
                    .font(.system(size: 11.5, weight: isSelected ? .medium : .regular))
                if let badge = panel.badge?() {
                    PanelBadgeView(badge: badge)
                }
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(isSelected ? Theme.subtleFill : isHovered ? Theme.subtleFill.opacity(0.6) : .clear, in: .rect(cornerRadius: Theme.smallCorner))
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
        Text(badge.count < 1000 ? "\(badge.count)" : "999+")
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color == .secondary ? AnyShapeStyle(Theme.subtleFill) : AnyShapeStyle(color.opacity(0.15)), in: .capsule)
    }

    private var color: Color {
        switch badge.style {
        case .plain: .secondary
        case .error: .red
        case .warning: .orange
        }
    }
}

/// Status-bar buttons that open or hide each bottom panel, like Xcode's
/// debug-area toggle; the shown one is tinted.
private struct BottomPanelToggles: View {
    let ui: UIRegistry

    var body: some View {
        HStack(spacing: 10) {
            ForEach(ui.bottomPanels) { panel in
                let isShown = ui.isBottomPanelVisible && (ui.selectedBottomPanel ?? ui.bottomPanels.first?.id) == panel.id
                Button {
                    ui.toggleBottomPanel(panel.id)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: panel.systemImage)
                        if let badge = panel.badge?() {
                            Text("\(badge.count)")
                                .monospacedDigit()
                                .foregroundStyle(badge.style == .error ? .red : badge.style == .warning ? .orange : .secondary)
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(isShown ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(panelHelp(panel, isShown ? "Hide \(panel.title)" : "Show \(panel.title)"))
            }
        }
    }
}

struct StatusBar: View {
    let items: [StatusItem]
    let ui: UIRegistry

    var body: some View {
        HStack(spacing: 14) {
            if !ui.bottomPanels.isEmpty {
                BottomPanelToggles(ui: ui)
                Divider().frame(height: 12)
            }
            ForEach(items.filter { $0.placement == .leading }) { $0.makeView() }
            Spacer()
            ForEach(items.filter { $0.placement == .trailing }) { $0.makeView() }
            if let commands = AppDelegate.host?.commands {
                CheatSheetButton(commands: commands)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
        .nativeSurface(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

struct WelcomeView: View {
    let host: PluginHost

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        let workspace = host.workspace
        VStack(spacing: 28) {
            VStack(spacing: 4) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 112, height: 112)
                    .padding(.bottom, 6)
                Text("Orbit")
                    .font(.system(size: 30, weight: .semibold))
                Text(workspace.root == nil ? "Open a folder to start working with agents." : workspace.name)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 2) {
                if workspace.root == nil {
                    WelcomeActionRow(command: host.commands.all.first { $0.id == "workspace.openFolder" })
                }
                WelcomeActionRow(command: host.commands.all.first { $0.id == "agents.new" })
                WelcomeActionRow(command: host.commands.all.first { $0.id == "agents.focus" })
                WelcomeActionRow(title: "Command Palette", systemImage: "command", shortcut: "⇧⌘P") {
                    CommandPalette.toggle(in: host)
                }
                if workspace.root != nil {
                    WelcomeActionRow(command: host.commands.all.first { $0.id == "search.quickOpen" })
                    WelcomeActionRow(command: host.commands.all.first { $0.id == "workspace.openFolder" })
                }
            }
            .padding(5)
            .frame(width: 320)
            .background(Theme.subtleFill, in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.hairline))

            Text("Version \(version)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct WelcomeActionRow: View {
    let title: String
    let systemImage: String
    let shortcut: String?
    let isEnabled: Bool
    let action: () -> Void
    @State private var isHovering = false

    init(title: String, systemImage: String, shortcut: String?, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.shortcut = shortcut
        self.isEnabled = isEnabled
        self.action = action
    }

    init(command: OrbitCommand?) {
        self.init(
            title: command?.title ?? "",
            systemImage: command?.systemImage ?? "command",
            shortcut: command?.shortcut?.displayString,
            isEnabled: command?.isEnabled() ?? false,
            action: { command?.run() }
        )
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(.tint)
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 13))
                Spacer(minLength: 8)
                if let shortcut {
                    KeyCaps(shortcut)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(isHovering && isEnabled ? AnyShapeStyle(Theme.subtleFill.opacity(2)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 9))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { isHovering = $0 }
    }
}

/// "⇧⌘P" rendered as individual key caps.
struct KeyCaps: View {
    let keys: [String]

    init(_ shortcut: String) {
        keys = shortcut.map(String.init)
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Theme.subtleFill.opacity(2), in: .rect(cornerRadius: 5))
            }
        }
    }
}
