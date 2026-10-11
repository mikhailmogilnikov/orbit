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
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarHost(panels: ui.sidebarPanels, selection: $sidebarPanelID)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 420)
        } detail: {
            EditorArea(host: host)
                .inspector(isPresented: $showsInspector) {
                    InspectorHost(panels: ui.inspectorPanels, selection: $inspectorPanelID)
                        .inspectorColumnWidth(min: 340, ideal: 420, max: 720)
                }
        }
        .navigationTitle(workspace.name)
        .navigationSubtitle(workspace.activeTab?.url.map(workspace.relativePath) ?? "")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    CommandPalette.toggle(in: host)
                } label: {
                    Label("Command Palette", systemImage: "command")
                }
                .help("Command Palette (⇧⌘P)")

                Button {
                    showsInspector.toggle()
                } label: {
                    Label("Agents", systemImage: "sidebar.right")
                }
                .help("Toggle Agents")
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
        .onChange(of: ui.requestedInspectorPanel) { _, id in
            guard let id else { return }
            showsInspector = true
            inspectorPanelID = id
            ui.requestedInspectorPanel = nil
        }
        .onChange(of: ui.requestedSidebarPanel) { _, id in
            guard let id else { return }
            columnVisibility = .all
            sidebarPanelID = id
            ui.requestedSidebarPanel = nil
        }
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

    var body: some View {
        let workspace = host.workspace
        VStack(spacing: 0) {
            if !workspace.tabs.isEmpty {
                TabBar(workspace: workspace)
                Divider()
            }
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
        // Switching tabs swaps the editor view; its min size must not reach the
        // split view (constraint-loop crash, same as InspectorHost).
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .background(.background)
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
        .background(.background)
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

struct TabBar: View {
    let workspace: Workspace

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
            }
            .frame(height: 34)
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
            Image(systemName: tab.systemImage)
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
        .background(.bar)
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
