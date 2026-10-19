import OrbitKit
import SwiftUI

/// Settings take over the window (D36), laid out like System Settings (D158):
/// the project on top of the sidebar, panes in groups with colored tiles,
/// search, back and forward over the pane's page, which opens with a header
/// card. "Back to Project" (bottom of the sidebar), or Esc, returns.
struct SettingsScreen: View {
    let host: PluginHost
    @State private var query = ""
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var navigator = SettingsNavigator()

    private var ui: UIRegistry { host.ui }

    private var panes: [SettingsPane] {
        let host = host
        var shell = [
            SettingsPane(
                id: "general", title: "General", systemImage: "gearshape.fill", tint: .gray, group: .app, order: 0,
                summary: "Updates, the orbit command and the settings file every project shares.",
                keywords: ["version", "about", "update", "command line", "terminal", "settings.json", "global"]
            ) {
                GeneralSettings()
            },
            SettingsPane(
                id: "appearance", title: "Appearance", systemImage: "circle.lefthalf.filled", tint: Color(white: 0.16), group: .app, order: 1,
                summary: "Light or dark, the color theme for each, and file icons.",
                keywords: ["theme", "dark", "light", "colors", "icons", "file icons", "mode"]
            ) {
                AppearanceSettings(host: host)
            },
            SettingsPane(
                id: "shortcuts", title: "Keyboard Shortcuts", systemImage: "keyboard.fill", tint: .gray, group: .customization, order: 0,
                summary: "Every command's keys; click one to change it.",
                keywords: ["keys", "hotkeys", "commands", "bindings"]
            ) {
                ShortcutsSettings(host: host)
            },
            SettingsPane(
                id: "extensions", title: "Extensions", systemImage: "shippingbox.fill", tint: .pink, group: .customization, order: 10,
                summary: "Color themes and file icons from Zed's catalog.",
                keywords: ["themes", "icons", "install", "catalog", "zed"]
            ) {
                ExtensionsSettings()
            },
            SettingsPane(
                id: "plugins", title: "Plugins", systemImage: "puzzlepiece.extension.fill", tint: .green, group: .customization, order: 20,
                summary: "Everything in Orbit is a plugin, the editor and agents included.",
                keywords: ["enable", "disable", "features"]
            ) {
                PluginsSettings(host: host)
            },
        ]
        if let root = host.workspace.root {
            shell.append(SettingsPane(
                id: Self.projectPane, title: root.lastPathComponent, systemImage: "folder.fill", tint: .blue, group: .app, order: -1,
                summary: "Settings this project overrides, in .orbit/settings.json.",
                keywords: ["project", "folder", "settings.json", "per project", "override"]
            ) {
                ProjectSettingsPane(host: host, root: root)
            })
        }
        return (shell + ui.settingsPanes).sorted { ($0.group, $0.order) < ($1.group, $1.order) }
    }

    static let projectPane = "project"

    private var filtered: [SettingsPane] {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return panes }
        return panes.filter { pane in
            ([pane.title] + pane.keywords + [pane.summary ?? ""]).contains { $0.lowercased().contains(query) }
        }
    }

    var body: some View {
        let visible = filtered
        let current = visible.first { $0.id == navigator.pane } ?? visible.first
        let page = current?.id == navigator.pane ? navigator.page : nil
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar(visible, selection: current?.id)
        } detail: {
            GeometryReader { proxy in
                // System Settings keeps its forms narrow; a wide window centers them.
                let margin = max(0, (proxy.size.width - 720) / 2)
                Group {
                    if let current {
                        if let page {
                            navigator.pageView.id(page.id)
                        } else {
                            current.makeView()
                                .environment(\.settingsPaneInfo, SettingsPaneInfo(
                                    title: current.title, systemImage: current.systemImage,
                                    tint: current.tint, summary: current.summary
                                ))
                                .id(current.id)
                        }
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
                .contentMargins(.horizontal, margin, for: .scrollContent)
            }
            // The page scrolls under the bar and fades out there, as under System Settings' toolbar.
            .safeAreaBar(edge: .top, spacing: 0) {
                SettingsTopBar(navigator: navigator, title: page?.title ?? current?.title ?? "Settings")
            }
            .environment(navigator)
            .ignoresSafeArea(.container, edges: .top)
            .background(.background)
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search")
        .navigationTitle(current?.title ?? "Settings")
        .navigationSubtitle("Settings")
        .onChange(of: ui.selectedSettingsPane, initial: true) { _, id in
            navigator.show(id ?? "general")
        }
        .onChange(of: navigator.pane) { _, id in
            if let id, ui.selectedSettingsPane != id { ui.selectedSettingsPane = id }
        }
    }

    private func sidebar(_ visible: [SettingsPane], selection: String?) -> some View {
        let groups = Dictionary(grouping: visible.filter { $0.id != Self.projectPane }, by: \.group)
        return List(selection: Binding(get: { selection }, set: { if let id = $0 { navigator.show(id) } })) {
            if let project = visible.first(where: { $0.id == Self.projectPane }), let root = host.workspace.root {
                Section {
                    ProjectSidebarRow(pane: project, root: root)
                        .tag(project.id)
                }
            }
            ForEach(groups.keys.sorted(), id: \.self) { group in
                Section {
                    ForEach(groups[group] ?? []) { pane in
                        SettingsSidebarRow(pane: pane)
                            .tag(pane.id)
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
        // At the bottom of the sidebar, not in the top row: the hidden
        // title bar's area over the detail column hid the Done button there.
        .safeAreaInset(edge: .bottom) {
            Button {
                ui.isSettingsVisible = false
            } label: {
                Label("Back to Project", systemImage: "chevron.left")
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.cancelAction)
            .buttonStyle(.glass)
            // Plain glass: the window's tint (the theme's text color in Orbit's
            // own themes) made it a heavy black or white bar.
            .tint(nil)
            .controlSize(.large)
            .help("Back to the project (Esc)")
            .padding(12)
        }
    }
}

private struct SettingsSidebarRow: View {
    let pane: SettingsPane

    var body: some View {
        HStack(spacing: 8) {
            SettingsTile(pane.systemImage, tint: pane.tint, size: 20)
            Text(pane.title)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

/// The project at the top of the sidebar, like the Apple Account in System Settings.
private struct ProjectSidebarRow: View {
    let pane: SettingsPane
    let root: URL

    var body: some View {
        HStack(spacing: 10) {
            SettingsTile(pane.systemImage, tint: pane.tint, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(pane.title)
                    .font(.orbit(.control, weight: .semibold))
                    .lineLimit(1)
                Text("Project")
                    .font(.orbit(.caption))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
        .help(root.path)
    }
}

/// Back and forward in a glass capsule, then the page's title, as in System Settings.
private struct SettingsTopBar: View {
    let navigator: SettingsNavigator
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 0) {
                Button(action: navigator.back) {
                    Image(systemName: "chevron.left")
                        .frame(width: 34, height: 32)
                        .contentShape(.rect)
                }
                .disabled(!navigator.canGoBack)
                .keyboardShortcut("[", modifiers: .command)
                .help("Back (⌘[)")
                Divider()
                    .frame(height: 16)
                Button(action: navigator.forward) {
                    Image(systemName: "chevron.right")
                        .frame(width: 34, height: 32)
                        .contentShape(.rect)
                }
                .disabled(!navigator.canGoForward)
                .keyboardShortcut("]", modifiers: .command)
                .help("Forward (⌘])")
            }
            .buttonStyle(.plain)
            .font(.orbit(.control, weight: .medium))
            .padding(.horizontal, 2)
            .glassEffect(.regular.interactive(), in: .capsule)
            Text(title)
                .font(.orbit(.title, weight: .semibold))
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background {
            Color.clear
                .contentShape(.rect)
                .gesture(WindowDragGesture())
        }
    }
}

// MARK: - General

struct GeneralSettings: View {
    @State private var commandInstalled = CommandLineTool.isInstalled

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty || build == short ? short : "\(short) (\(build))"
    }

    var body: some View {
        SettingsForm {
            Section {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Orbit")
                            .font(.orbit(.control, weight: .semibold))
                        Text("Version \(version)")
                            .font(.orbit(.body))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button("Check for Updates…") { Updater.shared.checkForUpdates() }
                        .disabled(!Updater.isEnabled)
                }
                .padding(.vertical, 2)
            } header: {
                Text("Software Update")
            } footer: {
                if !Updater.isEnabled {
                    Text("Updates are off in development builds.")
                }
            }

            Section {
                LabeledContent {
                    if commandInstalled {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                    } else {
                        Button("Install…") {
                            CommandLineTool.install()
                            commandInstalled = CommandLineTool.isInstalled
                        }
                    }
                } label: {
                    Text("orbit command")
                    Text("Open folders and files from a terminal: orbit . or orbit src/main.swift")
                }
            } header: {
                Text("Command Line")
            }

            Section {
                LabeledContent {
                    Button("Open") { NSWorkspace.shared.open(Self.prepared(ProjectSettings.userFile)) }
                } label: {
                    Text("Global settings")
                    Text(ProjectSettings.userPath)
                        .font(.orbit(.caption, design: .monospaced))
                }
                LabeledContent {
                    Button("Show in Finder") {
                        let folder = ProjectSettings.userFile.deletingLastPathComponent()
                        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                } label: {
                    Text("Orbit folder")
                    Text("Agents, language servers, grammars and extensions Orbit downloads.")
                }
            } header: {
                Text("Files")
            } footer: {
                Text("~/.orbit/settings.json applies to every project; a project's .orbit/settings.json wins over it.")
            }
        }
        .onAppear { commandInstalled = CommandLineTool.isInstalled }
    }

    /// Makes the file (with empty sections) so there's something to open.
    static func prepared(_ url: URL) -> URL {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? ProjectSettings.template.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }
}

// MARK: - Appearance

struct AppearanceSettings: View {
    let host: PluginHost
    @Bindable private var preferences = Preferences.shared
    @Environment(SettingsNavigator.self) private var navigator: SettingsNavigator?

    var body: some View {
        SettingsForm {
            Section {
                HStack(spacing: 18) {
                    ForEach([Preferences.Appearance.system, .light, .dark], id: \.self) { mode in
                        AppearanceChoice(mode: mode, isSelected: preferences.appearance == mode) {
                            preferences.appearance = mode
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            } header: {
                Text("Mode")
            }

            Section {
                if preferences.appearance != .dark {
                    ThemePicker(title: preferences.appearance == .light ? "Theme" : "Light theme", dark: false)
                }
                if preferences.appearance != .light {
                    ThemePicker(title: preferences.appearance == .dark ? "Theme" : "Dark theme", dark: true)
                }
                LabeledContent {
                    Button("Browse Themes…") {
                        navigator?.push("Theme Catalog") { ExtensionCatalogPage() }
                    }
                } label: {
                    Text("More themes")
                    Text("Try on any of Zed's themes before installing it. ⌃⌘T switches themes from anywhere.")
                }
            } header: {
                Text("Color Theme")
            } footer: {
                Text("A theme colors the editor, the terminal and the window behind the sidebars, and sets the accent color.")
            }

            Section("File Icons") {
                if preferences.appearance != .dark {
                    IconThemePicker(title: preferences.appearance == .light ? "Icons" : "Light icons", dark: false)
                }
                if preferences.appearance != .light {
                    IconThemePicker(title: preferences.appearance == .dark ? "Icons" : "Dark icons", dark: true)
                }
            }
        }
    }
}

/// A small window in the mode's theme colors, like System Settings' Appearance.
private struct AppearanceChoice: View {
    let mode: Preferences.Appearance
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                thumbnail
                    .frame(width: 96, height: 62)
                    .clipShape(.rect(cornerRadius: Theme.smallCorner, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.smallCorner, style: .continuous)
                            .strokeBorder(Theme.hairline)
                    }
                    .padding(3)
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.smallCorner + 3, style: .continuous)
                            .strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 2.5)
                    }
                Text(title)
                    .font(.orbit(.body, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var title: String {
        switch mode {
        case .system: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    @ViewBuilder private var thumbnail: some View {
        switch mode {
        case .light: ModeThumbnail(dark: false)
        case .dark: ModeThumbnail(dark: true)
        case .system:
            // Light and dark halves split on the diagonal, like macOS's Auto.
            ModeThumbnail(dark: false)
                .overlay {
                    ModeThumbnail(dark: true).mask(DiagonalHalf())
                }
        }
    }
}

/// The lower right half of a rectangle, corner to corner.
private struct DiagonalHalf: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

/// The picked theme as a tiny window: sidebar, a tab, a few lines of code.
private struct ModeThumbnail: View {
    let dark: Bool

    var body: some View {
        let theme = Extensions.shared.pickedColorTheme(dark: dark)
        let background = theme.editorBackground?.color ?? (dark ? Color(white: 0.12) : .white)
        let text = theme.editorForeground?.color ?? (dark ? .white : .black)
        let accent = theme.accent?.color ?? text
        GeometryReader { proxy in
            let width = proxy.size.width
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(0..<4, id: \.self) { row in
                        Capsule().fill(text.opacity(row == 1 ? 0.5 : 0.2)).frame(width: width * 0.16, height: 2.5)
                    }
                    Spacer()
                }
                .padding(.top, 10)
                .padding(.leading, 6)
                .frame(width: width * 0.28, alignment: .leading)
                .frame(maxHeight: .infinity)
                .background(text.opacity(dark ? 0.06 : 0.05))
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array([0.55, 0.38, 0.62, 0.3, 0.48].enumerated()), id: \.offset) { index, length in
                        Capsule()
                            .fill(index == 2 ? accent.opacity(0.85) : text.opacity(0.32))
                            .frame(width: width * 0.72 * length, height: 2.5)
                            .padding(.leading, index == 1 || index == 2 ? 6 : 0)
                    }
                    Spacer()
                }
                .padding(.top, 10)
                .padding(.leading, 7)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .background(background)
    }
}

// MARK: - Project

struct ProjectSettingsPane: View {
    let host: PluginHost
    let root: URL

    private var settings: ProjectSettings { host.workspace.settings }
    private var file: URL { ProjectSettings.projectFile(root: root) }

    var body: some View {
        let values = settings.projectValues
        let exists = FileManager.default.fileExists(atPath: file.path)
        SettingsForm {
            Section {
                LabeledContent {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([root]) }
                } label: {
                    Text("Location")
                    Text((root.path as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(root.path)
                }
            }

            Section {
                ForEach(settings.problems, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if values.isEmpty {
                    Text(exists ? "The file sets nothing Settings shows yet." : "This project uses your settings as they are.")
                        .foregroundStyle(.secondary)
                }
                ForEach(values, id: \.key) { entry in
                    LabeledContent {
                        Text(Self.display(entry.value))
                            .font(.orbit(.body, design: .monospaced))
                    } label: {
                        Text(entry.key)
                            .font(.orbit(.body, design: .monospaced))
                    }
                }
                LabeledContent {
                    Button(exists ? "Open" : "Create") {
                        host.commands.run("editor.openProjectSettings")
                        host.ui.isSettingsVisible = false
                    }
                } label: {
                    Text("Project settings")
                    Text(ProjectSettings.projectPath)
                        .font(.orbit(.caption, design: .monospaced))
                }
            } header: {
                Text("Overrides")
            } footer: {
                Text("""
                What a project sets wins over Settings, for everyone who opens it: "editor": { "wordWrap": true }, \
                "agents": { "default": "codex" }, formatters, language servers and MCP servers. \
                Options it decides show “Set by .orbit/settings.json” and can't be changed here.
                """)
            }
        }
    }

    private static func display(_ value: ProjectSettings.Value) -> String {
        switch value {
        case .bool(let value): value ? "true" : "false"
        case .number(let value): value.formatted()
        case .string(let value): "\"\(value)\""
        }
    }
}
