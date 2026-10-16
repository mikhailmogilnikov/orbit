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
                        .font(.system(size: 12, weight: .medium))
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
    @Bindable private var state = CheatSheetState.shared

    var body: some View {
        let isShown = Binding { state.shownFor === commands } set: { state.shownFor = $0 ? commands : nil }
        Button {
            isShown.wrappedValue.toggle()
        } label: {
            Image(systemName: "keyboard")
                .font(.system(size: 11))
                .foregroundStyle(isShown.wrappedValue ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Keyboard Shortcuts")
        .popover(isPresented: isShown, arrowEdge: .top) {
            ShortcutCheatSheet(commands: commands)
        }
    }
}

struct ShortcutCheatSheet: View {
    let commands: CommandRegistry

    private struct Entry: Identifiable {
        var id: String
        var title: String
        var keys: String
    }

    private var groups: [(category: String, entries: [Entry])] {
        var result: [(String, [Entry])] = [("General", [
            Entry(id: "shell.palette", title: "Command Palette", keys: "⇧⌘P"),
            Entry(id: "shell.settings", title: "Settings", keys: "⌘,"),
        ])]
        for category in commands.categories {
            let entries = commands.all
                .filter { $0.category == category }
                .compactMap { command in command.displayShortcut.map { Entry(id: command.id, title: command.title, keys: $0.displayString) } }
            if entries.isEmpty { continue }
            if let index = result.firstIndex(where: { $0.0 == category }) {
                result[index].1 += entries
            } else {
                result.append((category, entries))
            }
        }
        return result
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 300), spacing: 28, alignment: .top)], alignment: .leading, spacing: 18) {
                    ForEach(groups, id: \.category) { group in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(group.category)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.bottom, 2)
                            ForEach(group.entries) { entry in
                                HStack(spacing: 8) {
                                    Text(entry.title)
                                        .font(.system(size: 12))
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    KeyCaps(entry.keys)
                                }
                            }
                        }
                    }
                }
                Divider()
                HStack(spacing: 18) {
                    Text("⌘-click  go to definition")
                    Text("⌥Esc or ⌃Space  completion")
                    Text("Right-click  actions here")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .frame(width: 900)
        .frame(maxHeight: 620)
    }
}
