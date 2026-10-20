import OrbitKit
import SwiftUI

/// The command palette is the shell's own quick pick over the command registry.
@MainActor
enum CommandPalette {
    static func toggle(in host: PluginHost) {
        let commands = host.commands
        host.ui.toggleQuickPick(QuickPick(id: "shell.commands", placeholder: "Search commands") { query in
            commands.all
                .filter { $0.isEnabled() }
                .compactMap { command -> (QuickPickItem, Int)? in
                    let label = "\(command.category): \(command.title)"
                    guard let match = FuzzyMatch.match(query, in: label) else { return nil }
                    return (item(for: command, label: label, positions: match.positions, commands: commands), match.score)
                }
                .sorted { query.isEmpty ? String($0.0.title.characters) < String($1.0.title.characters) : $0.1 > $1.1 }
                .map(\.0)
        })
    }

    private static func item(for command: OrbitCommand, label: String, positions: [Int], commands: CommandRegistry) -> QuickPickItem {
        // The title with its matches highlighted, the category under it (D161).
        let titleOffset = command.category.count + 2
        let title = FuzzyMatch.highlighted(command.title, positions: positions.filter { $0 >= titleOffset }.map { $0 - titleOffset })
        return QuickPickItem(
            id: command.id,
            title: title,
            subtitle: command.category,
            systemImage: command.systemImage ?? "command",
            trailing: command.displayShortcut?.displayString
        ) {
            commands.teach(command)
            command.run()
        }
    }
}

/// Recomputes results only when the query or the data the pick reads changes
/// (e.g. a file index finishing to load), not on every arrow key.
@MainActor
@Observable
final class QuickPickState {
    /// Rows are lazy, so a long list (the theme selector with the catalog) only costs what is visible.
    private static let maxRows = 400

    let pick: QuickPick
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            selectedIndex = 0
            recompute()
        }
    }
    var selectedIndex = 0 {
        didSet { reportHighlight() }
    }
    private(set) var results: [QuickPickItem] = []
    /// Set once a row runs, so closing doesn't count as a cancel.
    var didRun = false
    @ObservationIgnored private var highlightedID: String?
    @ObservationIgnored private var appliedInitialSelection = false

    init(pick: QuickPick) {
        self.pick = pick
    }

    func recompute() {
        results = withObservationTracking {
            Array(pick.items(query).prefix(Self.maxRows))
        } onChange: { [weak self] in
            Task { @MainActor in self?.recompute() }
        }
        if !appliedInitialSelection {
            appliedInitialSelection = true
            if let initial = pick.initialSelection, let index = results.firstIndex(where: { $0.id == initial }) {
                selectedIndex = index
            }
        }
        selectedIndex = min(selectedIndex, max(0, results.count - 1))
        reportHighlight()
    }

    private func reportHighlight() {
        guard let onHighlight = pick.onHighlight, let selected, selected.id != highlightedID else { return }
        highlightedID = selected.id
        onHighlight(selected)
    }

    func move(_ delta: Int) {
        selectedIndex = min(max(selectedIndex + delta, 0), max(0, results.count - 1))
    }

    var selected: QuickPickItem? {
        results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }
}

struct QuickPickOverlay: View {
    let dismiss: () -> Void
    @State private var state: QuickPickState
    @FocusState private var isFocused: Bool

    init(pick: QuickPick, dismiss: @escaping () -> Void) {
        self.dismiss = dismiss
        _state = State(initialValue: QuickPickState(pick: pick))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: 0) {
                // A large query field like Spotlight's (D161).
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .orbitFont(.large, weight: .medium)
                        .foregroundStyle(.secondary)
                    TextField(state.pick.placeholder, text: $state.query)
                        .textFieldStyle(.plain)
                        .orbitFont(.large)
                        .focused($isFocused)
                        .onSubmit { run() }
                }
                .padding(.horizontal, 18)
                .frame(height: 54)

                if !state.results.isEmpty {
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(state.results.enumerated()), id: \.element.id) { index, item in
                                    QuickPickRow(item: item, isSelected: index == state.selectedIndex)
                                        .id(index)
                                        .onTapGesture {
                                            state.selectedIndex = index
                                            run()
                                        }
                                }
                            }
                            .padding(8)
                        }
                        // As tall as its rows, up to a limit: a scroll view alone takes all it's offered.
                        .frame(height: min(400, CGFloat(state.results.count) * 46 + 16))
                        .onChange(of: state.selectedIndex) { _, index in proxy.scrollTo(index) }
                    }
                }
            }
            .frame(width: 640)
            .glassEffect(.regular, in: .rect(cornerRadius: Theme.panelCorner))
            .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
            .padding(.top, 70)
        }
        .onAppear {
            state.recompute()
            isFocused = true
        }
        .onKeyPress(.downArrow) {
            state.move(1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            state.move(-1)
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .onDisappear {
            if !state.didRun { state.pick.onCancel?() }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
    }

    private func run() {
        guard let item = state.selected else { return }
        state.didRun = true
        dismiss()
        // Let the overlay dismiss before actions that present panels or move focus.
        DispatchQueue.main.async { item.run() }
    }
}

struct QuickPickRow: View {
    let item: QuickPickItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let fileURL = item.fileURL {
                    FileIconView(url: fileURL, size: 20)
                } else if let systemImage = item.systemImage {
                    Image(systemName: systemImage)
                        .orbitFont(.control, weight: .medium)
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .frame(width: 28, height: 28)
                        .background(Theme.activeFill, in: .rect(cornerRadius: Theme.smallCorner, style: .continuous))
                }
            }
            .frame(width: 28, height: 28)
            // Title over the dimmed detail (category, folder), like a Spotlight result.
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .orbitFont(.control, weight: .medium)
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .orbitFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if let trailing = item.trailing {
                if trailing.first.map({ "⌃⌥⇧⌘".contains($0) }) == true {
                    KeyCaps(trailing)
                } else {
                    Text(trailing)
                        .orbitFont(.body)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 44)
        .background(isSelected ? Theme.selectedFill : .clear, in: .rect(cornerRadius: Theme.corner, style: .continuous))
        .contentShape(.rect)
    }
}
