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
        // Category dimmed, then the title; matches highlighted in both.
        let titleOffset = command.category.count + 2
        var title = FuzzyMatch.highlighted(command.category, positions: positions.filter { $0 < command.category.count })
        for run in title.runs where run.foregroundColor == nil {
            title[run.range].foregroundColor = .secondary
        }
        title += AttributedString("  ")
        title += FuzzyMatch.highlighted(command.title, positions: positions.filter { $0 >= titleOffset }.map { $0 - titleOffset })
        return QuickPickItem(
            id: command.id,
            title: title,
            systemImage: command.systemImage ?? "command",
            trailing: command.shortcut?.displayString
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
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(state.pick.placeholder, text: $state.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .focused($isFocused)
                        .onSubmit { run() }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)

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
                            .padding(6)
                        }
                        .frame(maxHeight: 340)
                        .onChange(of: state.selectedIndex) { _, index in proxy.scrollTo(index) }
                    }
                }
            }
            .frame(width: 580)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
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
            if let fileURL = item.fileURL {
                FileIconView(url: fileURL, size: 16)
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            } else if let systemImage = item.systemImage {
                Image(systemName: systemImage)
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            Text(item.title)
                .lineLimit(1)
                .layoutPriority(1)
            if let subtitle = item.subtitle {
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if let trailing = item.trailing {
                Text(trailing)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isSelected ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 9))
        .contentShape(.rect)
    }
}

