import OrbitKit
import SwiftUI

/// Settings fill the window, like a page: sections on the left (plugins add
/// their own), the selected one on the right. ⌘, or the gear opens it, Esc closes.
struct SettingsScreen: View {
    let host: PluginHost
    @State private var query = ""

    private var ui: UIRegistry { host.ui }

    private var panes: [SettingsPane] {
        let host = host
        let shell = [
            SettingsPane(id: "general", title: "General", systemImage: "gearshape", order: 0, keywords: ["appearance", "theme", "dark", "light", "version"]) {
                GeneralSettings(host: host)
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
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                SettingsSearchField(text: $query)
                    .padding(.horizontal, 10)
                    .padding(.top, 12)
                List(selection: Binding(get: { current?.id }, set: { ui.selectedSettingsPane = $0 })) {
                    ForEach(visible) { pane in
                        Label(pane.title, systemImage: pane.systemImage)
                            .tag(pane.id)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
            .frame(width: 230)
            .background(Theme.subtleFill)

            Divider()

            VStack(spacing: 0) {
                HStack {
                    Text(current?.title ?? "Settings")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button {
                        ui.isSettingsVisible = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .keyboardShortcut(.cancelAction)
                    .help("Close Settings (Esc)")
                }
                .frame(maxWidth: 720)
                .padding(.horizontal, 28)
                .padding(.top, 18)
                if let current {
                    current.makeView()
                        .frame(maxWidth: 720, maxHeight: .infinity, alignment: .top)
                        .padding(.horizontal, 8)
                        .id(current.id)
                } else {
                    EmptyStateView("No Matches", systemImage: "magnifyingglass", message: "No settings match “\(query)”.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.background)
    }
}

private struct SettingsSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Theme.subtleFill.opacity(2), in: .rect(cornerRadius: 8))
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
            Section("Appearance") {
                Picker("Theme", selection: $preferences.appearance) {
                    Text("System").tag(Preferences.Appearance.system)
                    Text("Light").tag(Preferences.Appearance.light)
                    Text("Dark").tag(Preferences.Appearance.dark)
                }
                .pickerStyle(.segmented)
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
