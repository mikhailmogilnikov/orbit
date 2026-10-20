import AppKit
import OrbitKit
import SwiftUI

/// A command just run by mouse shows its shortcut for a moment at the bottom
/// of the window, so the shortcut gets learned (D67).
struct CommandHintOverlay: View {
    let commands: CommandRegistry
    @State private var shown: CommandHint?

    var body: some View {
        ZStack {
            if let shown {
                HStack(spacing: 8) {
                    Text(shown.title)
                        .orbitFont(.body, weight: .medium)
                        .foregroundStyle(.secondary)
                    KeyCaps(shown.shortcut.displayString)
                }
                .padding(.leading, 12)
                .padding(.trailing, 6)
                .padding(.vertical, 5)
                .glassEffect(.regular, in: .capsule)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: shown)
        .allowsHitTesting(false)
        .task(id: commands.hint) {
            guard let hint = commands.hint else { return }
            shown = hint
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            shown = nil
        }
    }
}

/// Every shortcut, from the keyboard button at the end of the status bar
/// (D67). Shared so the palette's command can open it too.
@MainActor
@Observable
final class CheatSheetState {
    static let shared = CheatSheetState()
    /// The window showing it, by its commands (D101).
    var shownFor: CommandRegistry?
}

/// The status bar's keyboard button and its popover.
struct CheatSheetButton: View {
    let commands: CommandRegistry
    let ui: UIRegistry
    @Bindable private var state = CheatSheetState.shared

    var body: some View {
        let isShown = Binding { state.shownFor === commands } set: { state.shownFor = $0 ? commands : nil }
        Button {
            isShown.wrappedValue.toggle()
        } label: {
            Image(systemName: "keyboard")
                .orbitFont(.caption)
                .foregroundStyle(isShown.wrappedValue ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Keyboard Shortcuts")
        .accessibilityLabel("Keyboard Shortcuts")
        .popover(isPresented: isShown, arrowEdge: .top) {
            ShortcutCheatSheet(commands: commands) {
                isShown.wrappedValue = false
                ui.showSettings("shortcuts")
            }
        }
    }
}

/// Every shortcut in a narrow searchable list (D175): a click on a key
/// records a new one right there, as in Settings; searching also lists
/// commands without a key, so one can be given.
struct ShortcutCheatSheet: View {
    let commands: CommandRegistry
    let openSettings: () -> Void
    @State private var query = ""
    @State private var recording: String?
    @State private var notice: (id: String, text: String)?
    @FocusState private var isSearchFocused: Bool

    private var sections: [(category: String, commands: [OrbitCommand])] {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        var result: [(String, [OrbitCommand])] = []
        for category in commands.categories {
            let matching = commands.all.filter { command in
                guard command.category == category else { return false }
                guard !query.isEmpty else { return command.displayShortcut != nil }
                return command.title.lowercased().contains(query) || category.lowercased().contains(query)
                    || (command.displayShortcut?.displayString.lowercased().contains(query) ?? false)
            }
            if !matching.isEmpty { result.append((category, matching)) }
        }
        return result
    }

    /// Keys that aren't commands: the shell's own and the mouse.
    private static let extras: [(title: String, keys: String)] = [
        ("Command Palette", "⇧⌘P"),
        ("Settings", "⌘,"),
        ("Go to Definition", "⌘-click"),
        ("Completion", "⌃Space"),
        ("Actions Here", "Right-click"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            SettingsSearchField("Search shortcuts", text: $query)
                .focused($isSearchFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            Divider()
            List {
                ForEach(sections, id: \.category) { section in
                    Section(section.category) {
                        ForEach(section.commands) { row($0) }
                    }
                }
                let extras = Self.extras.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
                if !extras.isEmpty {
                    Section("More") {
                        ForEach(extras, id: \.title) { extra in
                            HStack {
                                Text(extra.title)
                                Spacer(minLength: 8)
                                Text(extra.keys)
                                    .orbitFont(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            Divider()
            HStack {
                Text("Click a key to change it")
                    .orbitFont(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Keyboard Settings…", action: openSettings)
                    .buttonStyle(.link)
                    .orbitFont(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .orbitFont(.body)
        .frame(width: 360, height: 460)
        .onAppear { isSearchFocused = true }
        .onDisappear { recording = nil }
    }

    private func row(_ command: OrbitCommand) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(command.title)
                    .lineLimit(1)
                if let notice, notice.id == command.id {
                    Text(notice.text)
                        .orbitFont(.micro)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            ShortcutRecorder(
                shortcut: command.displayShortcut,
                isRecording: recording == command.id,
                start: {
                    recording = command.id
                    notice = nil
                },
                finish: { result in
                    recording = nil
                    if let result {
                        notice = ShortcutsSettings.assign(result, to: command, in: commands).map { (command.id, $0) }
                    }
                }
            )
        }
    }
}
