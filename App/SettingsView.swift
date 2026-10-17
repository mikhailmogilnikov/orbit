import OrbitKit
import SwiftUI

/// Settings take over the window, laid out like System Settings: sections in
/// the sidebar (plugins add their own) with search, the section's form as the
/// detail. "Back to Project" (bottom of the sidebar), or Esc, goes back to the
/// workspace.
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
            SettingsPane(id: "extensions", title: "Extensions", systemImage: "shippingbox", order: 85, keywords: ["themes", "icons", "install", "catalog", "zed"]) {
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
                .controlSize(.large)
                .help("Back to the project (Esc)")
                .padding(12)
            }
        } detail: {
            VStack(spacing: 0) {
                // The window has no toolbar (D42): the title lives here.
                HStack {
                    Text(current?.title ?? "Settings")
                        .font(.orbit(.title, weight: .semibold))
                    Spacer()
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
                HStack {
                    Text("More themes and icons come from extensions.")
                    Spacer()
                    Button("Browse Themes…") {
                        UserDefaults.standard.set(ExtensionsSettings.Tab.catalog.rawValue, forKey: ExtensionsSettings.tabKey)
                        host.ui.showSettings("extensions")
                    }
                }
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
        let current = Extensions.shared.pickedColorTheme(dark: dark).id
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

struct ShortcutsSettings: View {
    let host: PluginHost
    @State private var filter = ""
    @State private var recording: String?
    /// What the last recorded key took from another command, shown under its row.
    @State private var notice: (id: String, text: String)?

    /// Keys the shell handles itself, not commands: they can't be reassigned.
    private static let fixed: [(title: String, systemImage: String, keys: KeyboardShortcut)] = [
        ("Command Palette", "command", KeyboardShortcut("p", modifiers: [.command, .shift])),
        ("Settings", "gearshape", KeyboardShortcut(",", modifiers: .command)),
    ]

    private var commands: [OrbitCommand] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return host.commands.all.filter {
            query.isEmpty || $0.title.lowercased().contains(query) || $0.category.lowercased().contains(query)
                || ($0.displayShortcut?.displayString ?? "").lowercased().contains(query)
        }
    }

    var body: some View {
        let commands = commands
        var categories: [String] = []
        for command in commands where !categories.contains(command.category) { categories.append(command.category) }
        let bindings = KeyBindings.shared
        return Form {
            Section {
                TextField("Filter commands", text: $filter)
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Click a shortcut and press new keys; ⌫ removes it, Esc cancels. Every command is also in the Command Palette (⇧⌘P).")
                    Spacer()
                    if bindings.hasCustomizations {
                        Button("Reset All") {
                            bindings.resetAll()
                            notice = nil
                        }
                    }
                }
            }
            if filter.isEmpty {
                Section("General") {
                    ForEach(Self.fixed, id: \.title) { entry in
                        LabeledContent {
                            KeyCaps(entry.keys.displayString)
                        } label: {
                            Label(entry.title, systemImage: entry.systemImage)
                        }
                    }
                }
            }
            ForEach(categories, id: \.self) { category in
                Section(category) {
                    ForEach(commands.filter { $0.category == category }) { command in
                        row(command)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { recording = nil }
    }

    private func row(_ command: OrbitCommand) -> some View {
        let bindings = KeyBindings.shared
        return LabeledContent {
            HStack(spacing: 6) {
                if bindings.isCustomized(command.id) {
                    Button {
                        bindings.reset(command.id)
                        notice = nil
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(command.defaultDisplayShortcut.map { "Reset to \($0.displayString)" } ?? "Reset to no shortcut")
                }
                ShortcutRecorder(
                    shortcut: command.displayShortcut,
                    isRecording: recording == command.id,
                    start: {
                        recording = command.id
                        notice = nil
                    },
                    finish: { result in
                        recording = nil
                        if let result { assign(result, to: command) }
                    }
                )
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Label(command.title, systemImage: command.systemImage ?? "command")
                if let notice, notice.id == command.id {
                    Text(notice.text)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    /// `.some(nil)` removes the key. A key another command had moves here.
    private func assign(_ result: KeyboardShortcut?, to command: OrbitCommand) {
        let bindings = KeyBindings.shared
        guard let shortcut = result else {
            bindings.set(nil, for: command.id)
            return
        }
        if let fixed = Self.fixed.first(where: { $0.keys == shortcut }) {
            NSSound.beep()
            notice = (command.id, "\(shortcut.displayString) opens \(fixed.title) and can't be reassigned.")
            return
        }
        let others = host.commands.all.filter { $0.id != command.id && ($0.shortcut == shortcut || $0.editorShortcut == shortcut) }
        for other in others { bindings.set(nil, for: other.id) }
        if shortcut == command.defaultDisplayShortcut { bindings.reset(command.id) } else { bindings.set(shortcut, for: command.id) }
        if !others.isEmpty {
            let names = others.map { "“\($0.title)”" }.joined(separator: ", ")
            notice = (command.id, "Taken from \(names), which has no shortcut now.")
        }
    }
}

/// The shortcut as key caps; clicked, it records the next key press.
struct ShortcutRecorder: View {
    let shortcut: KeyboardShortcut?
    let isRecording: Bool
    let start: () -> Void
    /// nil: cancelled; `.some(nil)`: the key removed.
    let finish: (KeyboardShortcut??) -> Void
    @State private var monitors: [Any] = []

    var body: some View {
        Button(action: { isRecording ? finish(nil) : start() }) {
            Group {
                if isRecording {
                    Text("Press keys…")
                        .font(.orbit(.caption, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(minHeight: 18)
                        .padding(.horizontal, 6)
                        .background(Theme.accent.opacity(0.12), in: .rect(cornerRadius: 5))
                } else if let shortcut {
                    KeyCaps(shortcut.displayString)
                } else {
                    Text("—").foregroundStyle(.tertiary).frame(minWidth: 18, minHeight: 18)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(isRecording ? "Press the new shortcut; ⌫ removes it, Esc cancels" : "Click to change")
        .onChange(of: isRecording, initial: true) { _, recording in
            recording ? listen() : stopListening()
        }
        .onDisappear(perform: stopListening)
    }

    private func listen() {
        stopListening()
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            switch event.keyCode {
            case 53 where modifiers.isEmpty: finish(nil)
            case 51 where modifiers.isEmpty, 117 where modifiers.isEmpty: finish(.some(nil))
            default:
                // A key without ⌘, ⌃ or ⌥ would stop typing that character anywhere.
                guard !modifiers.subtracting(.shift).isEmpty,
                      let key = KeyPositions.key(keyCode: event.keyCode, characters: event.characters(byApplyingModifiers: [])) else {
                    NSSound.beep()
                    return nil
                }
                var eventModifiers: EventModifiers = []
                if modifiers.contains(.command) { eventModifiers.insert(.command) }
                if modifiers.contains(.control) { eventModifiers.insert(.control) }
                if modifiers.contains(.option) { eventModifiers.insert(.option) }
                if modifiers.contains(.shift) { eventModifiers.insert(.shift) }
                finish(.some(KeyboardShortcut(key, modifiers: eventModifiers)))
            }
            return nil
        }
        // A click anywhere else cancels.
        let clicks = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            DispatchQueue.main.async { if isRecording { finish(nil) } }
            return event
        }
        monitors = [keys, clicks].compactMap { $0 }
    }

    private func stopListening() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
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
