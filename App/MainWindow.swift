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
        .onAppear {
            AppDelegate.reopenMainWindow = { openWindow(id: "main") }
        }
        .onChange(of: Preferences.shared.appearance, initial: true) { _, appearance in
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
        .help(panel.title)
    }
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
            // SwiftUI scroll views draw into the safe area under the floating glass
            // sidebar and inspector, which then pick up their colors (green diff rows).
            .clipped()
            if host.ui.isBottomPanelVisible, !host.ui.bottomPanels.isEmpty {
                BottomPanelHost(ui: host.ui)
            }
            let statusItems = host.ui.statusItems.filter { $0.isVisible() }
            if !statusItems.isEmpty {
                StatusBar(items: statusItems)
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

    // Centered on the traffic lights and the floating sidebar toggle (~26–28 pt down).
    private static let height: CGFloat = 52
    /// With the sidebar hidden, the traffic lights sit over the start of this
    /// row (not in full screen).
    private static let windowedInset: CGFloat = 76
    private static let fullScreenInset: CGFloat = 6

    var body: some View {
        let sidebarHidden = columnVisibility == .detailOnly
        HStack(spacing: 4) {
            TopBarButton("sidebar.left", help: sidebarHidden ? "Show Sidebar" : "Hide Sidebar") {
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
            TopBarButton("sidebar.right", help: "Toggle Agents") {
                showsInspector.toggle()
            }
        }
        .padding(.leading, sidebarHidden ? (isFullScreen ? Self.fullScreenInset : Self.windowedInset) : 6)
        .padding(.trailing, 8)
        .frame(height: Self.height)
        .background {
            Color.clear
                .contentShape(.rect)
                .gesture(WindowDragGesture())
        }
        .background(FullScreenObserver(isFullScreen: $isFullScreen))
    }
}

/// Hiding the window toolbar also hides the title bar container, and the
/// traffic lights with it. The container is transparent anyway (hidden title
/// bar), so it is shown again, and again whenever AppKit hides it.
/// Not in full screen: there the container moves into a separate toolbar
/// window with an opaque background (a grey plate over the tab row), and
/// there are no traffic lights to keep anyway.
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

private struct TrafficLightsKeeper: NSViewRepresentable {
    func makeNSView(context: Context) -> KeeperView { KeeperView() }
    func updateNSView(_ view: KeeperView, context: Context) {}

    final class KeeperView: NSView {
        private var observations: [NSKeyValueObservation] = []
        private var observers: [NSObjectProtocol] = []
        private weak var container: NSView?
        private weak var titlebar: NSView?

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
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.debugDump() }
            } else {
                if container.isHidden { container.isHidden = false }
                if titlebar.alphaValue < 1 { titlebar.alphaValue = 1 }
            }
        }

        func debugDump() {
            func dump(_ v: NSView, _ d: Int) {
                print(String(repeating: "  ", count: d) + "\(type(of: v)) \(v.frame) hidden=\(v.isHidden) a=\(v.alphaValue) bg=\(String(describing: v.layer?.backgroundColor))")
                for c in v.subviews { dump(c, d + 1) }
            }
            for win in NSApp.windows where win !== window {
                print("WINDOW \(type(of: win)) \(win.frame) opaque=\(win.isOpaque) bg=\(win.backgroundColor)")
                if let root = win.contentView?.superview { dump(root, 0) }
            }
            fflush(stdout)
        }

        isolated deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
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

private struct TopBarButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    init(_ systemImage: String, help: String, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .help(help)
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
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 10)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 10)
                }
            }
            .onChange(of: workspace.activeTabID) { _, id in
                // A just-opened tab isn't laid out yet; scroll on the next runloop pass.
                DispatchQueue.main.async {
                    withAnimation(.snappy) { proxy.scrollTo(id) }
                }
            }
        }
    }
}

struct TabItem: View {
    let tab: EditorTab
    let workspace: Workspace
    @State private var isHovering = false

    var body: some View {
        let isActive = workspace.activeTabID == tab.id
        let isDirty = tab.url.flatMap { workspace.documents.existingDocument(for: $0) }?.isDirty == true
            && tab.kind == EditorTab.fileKind
        HStack(spacing: 6) {
            Group {
                if tab.kind == EditorTab.fileKind, let url = tab.url {
                    FileIconView(url: url, size: 13)
                } else {
                    Image(systemName: tab.systemImage)
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(tab.kind == EditorTab.fileKind ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            Text(tab.title)
                .font(.system(size: 12, weight: isActive ? .medium : .regular))
                .foregroundStyle(isActive ? .primary : .secondary)
                .lineLimit(1)
            ZStack {
                if isHovering || (isActive && !isDirty) {
                    Button {
                        workspace.requestClose(tab.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, height: 14)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                } else if isDirty {
                    Circle().fill(.secondary).frame(width: 6, height: 6)
                }
            }
            .frame(width: 14)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 26)
        .background(isActive ? AnyShapeStyle(Theme.subtleFill.opacity(2)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 7))
        .contentShape(.rect)
        .help(tab.url.map(workspace.relativePath) ?? tab.title)
        .onTapGesture { workspace.activeTabID = tab.id }
        .onHover { isHovering = $0 }
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

struct StatusBar: View {
    let items: [StatusItem]

    var body: some View {
        HStack(spacing: 14) {
            ForEach(items.filter { $0.placement == .leading }) { $0.makeView() }
            Spacer()
            ForEach(items.filter { $0.placement == .trailing }) { $0.makeView() }
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
