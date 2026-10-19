import OrbitKit
import SwiftUI

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
        return SettingsForm {
            Section {
                SettingsSearchField("Filter commands or keys", text: $filter)
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
                        .font(.orbit(.micro))
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
                        .background(Theme.selectedFill, in: .rect(cornerRadius: Theme.smallCorner))
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
        SettingsForm {
            if host.needsRestart {
                Section {
                    LabeledContent {
                        Button("Quit Orbit") { NSApp.terminate(nil) }
                    } label: {
                        Label("Restart Orbit to apply plugin changes.", systemImage: "arrow.clockwise.circle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            Section {
                ForEach(host.entries) { entry in
                    Toggle(isOn: Binding(
                        get: { entry.isEnabled },
                        set: { host.setEnabled($0, pluginID: entry.id) }
                    )) {
                        SettingsLabel(entry.manifest.name, subtitle: entry.manifest.summary, systemImage: entry.manifest.systemImage, tint: Self.tint(for: entry.id))
                    }
                }
            } header: {
                Text("Built In")
            } footer: {
                Text("A plugin that's off isn't loaded at all; turning one on or off takes effect after a restart.")
            }
        }
    }

    /// Steady per plugin, varied across the list, like System Settings' icons.
    private static func tint(for id: String) -> Color {
        let palette: [Color] = [.blue, .purple, .orange, .teal, .indigo, .pink, .green, .cyan, .red, .mint]
        let sum = id.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[sum % palette.count]
    }
}
