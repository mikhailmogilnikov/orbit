import OrbitKit
import SwiftUI

/// Settings take over the window, laid out like System Settings: sections in
/// the sidebar (plugins add their own) with search, the section's form as the
/// detail. Done, or Esc, goes back to the workspace.
struct SettingsScreen: View {
    let host: PluginHost
    @State private var query = ""
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    private var ui: UIRegistry { host.ui }

    private var panes: [SettingsPane] {
        let host = host
        let shell = [
            SettingsPane(id: "general", title: "General", systemImage: "gearshape", order: 0, keywords: ["appearance", "theme", "dark", "light", "colors", "icons", "version"]) {
                GeneralSettings(host: host)
            },
            SettingsPane(id: "extensions", title: "Extensions", systemImage: "shippingbox", order: 85, keywords: ["themes", "icons", "install"]) {
                ExtensionsSettings()
            },
            SettingsPane(id: "shortcuts", title: "Keyboard Shortcuts", systemImage: "keyboard", order: 80, keywords: ["keys", "hotkeys", "commands"]) {
                ShortcutsSettings(host: host)
            },
            SettingsPane(id: "plugins", title: "Plugins", systemImage: "puzzlepiece.extension", order: 90, keywords: ["extensions", "enable", "disable"]) {
                PluginsSettings(host: host)
            },
        ]
        return (shell + ui.settingsPanes).sorted { $0.order < $1.order }
    }

    private var filtered: [SettingsPane] {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return panes }
        return panes.filter { pane in
            ([pane.title] + pane.keywords).contains { $0.lowercased().contains(query) }
        }
    }

    var body: some View {
        let visible = filtered
        let current = visible.first { $0.id == ui.selectedSettingsPane } ?? visible.first
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: Binding(get: { current?.id }, set: { ui.selectedSettingsPane = $0 })) {
                ForEach(visible) { pane in
                    Label(pane.title, systemImage: pane.systemImage)
                        .tag(pane.id)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            VStack(spacing: 0) {
                // The window has no toolbar (D42): title and Done live here.
                HStack {
                    Text(current?.title ?? "Settings")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button("Done") { ui.isSettingsVisible = false }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(.glass)
                        .help("Back to the project (Esc)")
                }
                .padding(.horizontal, 20)
                .frame(height: 52)
                .background {
                    Color.clear
                        .contentShape(.rect)
                        .gesture(WindowDragGesture())
                }
                Group {
                    if let current {
                        current.makeView()
                            .id(current.id)
                    } else {
                        EmptyStateView("No Results", systemImage: "magnifyingglass", message: "No settings match “\(query)”.")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .ignoresSafeArea(.container, edges: .top)
            .background(.background)
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search")
        .navigationTitle(current?.title ?? "Settings")
        .navigationSubtitle("Settings")

    }
}

// MARK: - Panes

struct GeneralSettings: View {
    let host: PluginHost
    @Bindable private var preferences = Preferences.shared

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty || build == short ? short : "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $preferences.appearance) {
                    Text("System").tag(Preferences.Appearance.system)
                    Text("Light").tag(Preferences.Appearance.light)
                    Text("Dark").tag(Preferences.Appearance.dark)
                }
                .pickerStyle(.segmented)
                if preferences.appearance != .dark {
                    ThemePicker(title: preferences.appearance == .light ? "Theme" : "Light Theme", dark: false)
                }
                if preferences.appearance != .light {
                    ThemePicker(title: preferences.appearance == .dark ? "Theme" : "Dark Theme", dark: true)
                }
                if preferences.appearance != .dark {
                    IconThemePicker(title: preferences.appearance == .light ? "File Icons" : "Light File Icons", dark: false)
                }
                if preferences.appearance != .light {
                    IconThemePicker(title: preferences.appearance == .dark ? "File Icons" : "Dark File Icons", dark: true)
                }
            } header: {
                Text("Appearance")
            } footer: {
                Text("More themes and icons come from extensions.")
            }
            if let root = host.workspace.root {
                Section("Project") {
                    LabeledContent("Folder") {
                        HStack(spacing: 8) {
                            Text(root.path)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([root]) }
                        }
                    }
                }
            }
            Section("About") {
                LabeledContent("Version", value: version)
            }
        }
        .formStyle(.grouped)
    }
}

/// Light and dark are picked separately, so "System" switches between two themes.
struct ThemePicker: View {
    let title: String
    let dark: Bool
    @Bindable private var preferences = Preferences.shared

    var body: some View {
        let themes = Extensions.shared.colorThemes.filter { $0.isDark == dark }
        let selection = dark ? $preferences.darkThemeID : $preferences.lightThemeID
        let current = Extensions.shared.colorTheme(dark: dark).id
        Picker(title, selection: Binding(get: { current }, set: { selection.wrappedValue = $0 })) {
            ForEach(themes) { theme in
                Text(theme.name).tag(theme.id)
            }
        }
    }
}

/// Every icon theme is offered in both modes (an icon set marked dark often reads
/// fine on light), but each mode's own variants come first.
struct IconThemePicker: View {
    let title: String
    let dark: Bool
    @Bindable private var preferences = Preferences.shared

    var body: some View {
        let themes = Extensions.shared.iconThemes
        let matching = themes.filter { $0.isDark == dark }
        let others = themes.filter { $0.isDark != dark }
        Picker(title, selection: dark ? $preferences.darkIconThemeID : $preferences.lightIconThemeID) {
            Text("Orbit").tag(String?.none)
            if !matching.isEmpty {
                Divider()
                ForEach(matching) { Text($0.name).tag(Optional($0.id)) }
            }
            if !others.isEmpty {
                Divider()
                ForEach(others) { Text($0.name).tag(Optional($0.id)) }
            }
        }
    }
}

struct ExtensionsSettings: View {
    private var extensions: Extensions { .shared }

    var body: some View {
        Form {
            Section {
                ForEach(extensions.installed) { item in
                    LabeledContent {
                        Text(item.isBuiltin ? "Built-in" : item.manifest.version)
                            .foregroundStyle(.secondary)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.manifest.name)
                                Text(Self.summary(of: item))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: item.iconThemeCount > 0 && item.themeCount == 0 ? "doc.richtext" : "paintpalette")
                        }
                    }
                    .contextMenu {
                        if !item.isBuiltin {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.directory]) }
                        }
                    }
                }
            } header: {
                Text("Installed")
            } footer: {
                HStack {
                    Text("Drop an extension folder into ~/.orbit/extensions — it loads right away. Zed theme and icon extensions work as they are.")
                    Spacer()
                    Button("Open Folder") { NSWorkspace.shared.open(Extensions.userDirectory) }
                }
            }
            if !extensions.problems.isEmpty {
                Section("Problems") {
                    ForEach(extensions.problems) { problem in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(problem.location.lastPathComponent)
                                Text(problem.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private static func summary(of item: InstalledExtension) -> String {
        var parts: [String] = []
        if let description = item.manifest.description, !description.isEmpty { parts.append(description) }
        if item.themeCount > 0 { parts.append(item.themeCount == 1 ? "1 theme" : "\(item.themeCount) themes") }
        if item.iconThemeCount > 0 { parts.append(item.iconThemeCount == 1 ? "1 icon theme" : "\(item.iconThemeCount) icon themes") }
        return parts.joined(separator: " · ")
    }
}

struct ShortcutsSettings: View {
    let host: PluginHost
    @State private var filter = ""

    private struct Row: Identifiable {
        var id: String
        var title: String
        var systemImage: String
        var category: String
        var shortcut: String?
    }

    private var rows: [Row] {
        let shell = [
            Row(id: "shell.palette", title: "Command Palette", systemImage: "command", category: "General", shortcut: "⇧⌘P"),
            Row(id: "shell.settings", title: "Settings", systemImage: "gearshape", category: "General", shortcut: "⌘,"),
        ]
        let commands = host.commands.all.map {
            Row(id: $0.id, title: $0.title, systemImage: $0.systemImage ?? "command", category: $0.category, shortcut: $0.shortcut?.displayString)
        }
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return (shell + commands).filter {
            query.isEmpty || $0.title.lowercased().contains(query) || $0.category.lowercased().contains(query)
                || ($0.shortcut ?? "").lowercased().contains(query)
        }
    }

    var body: some View {
        let rows = rows
        var categories: [String] = []
        for row in rows where !categories.contains(row.category) { categories.append(row.category) }
        return Form {
            Section {
                TextField("Filter commands", text: $filter)
            } footer: {
                Text("Every command is also in the Command Palette (⇧⌘P).")
            }
            ForEach(categories, id: \.self) { category in
                Section(category) {
                    ForEach(rows.filter { $0.category == category }) { row in
                        LabeledContent {
                            if let shortcut = row.shortcut {
                                KeyCaps(shortcut)
                            } else {
                                Text("—").foregroundStyle(.tertiary)
                            }
                        } label: {
                            Label(row.title, systemImage: row.systemImage)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct PluginsSettings: View {
    let host: PluginHost

    var body: some View {
        Form {
            Section {
                ForEach(host.entries) { entry in
                    Toggle(isOn: Binding(
                        get: { entry.isEnabled },
                        set: { host.setEnabled($0, pluginID: entry.id) }
                    )) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.manifest.name)
                                Text(entry.manifest.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: entry.manifest.systemImage)
                        }
                    }
                }
            } footer: {
                if host.needsRestart {
                    Text("Restart Orbit to apply plugin changes.")
                        .foregroundStyle(.orange)
                } else {
                    Text("Everything in Orbit is a plugin, including the editor and agents.")
                }
            }
        }
        .formStyle(.grouped)
    }
}
