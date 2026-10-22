import OrbitAPI
import OrbitUI
import SwiftUI

/// Pending agent edits above the composer, like Cursor: a summary row with
/// Undo All / Keep All that expands into the changed files. The review itself
/// stays inline in the editor (D7); this is the way into it.
struct AgentChangesBar: View {
    let changes: ChangeTracking
    let store: AgentStore

    var body: some View {
        let files = changes.changedFiles
        let stats = files.map { changes.stats(for: $0) }
        VStack(spacing: 0) {
            // A sidebar-style section header (D212): one prominent action, the rest quiet icons.
            HStack(spacing: 6) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { store.isChangesExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        DisclosureChevron(isExpanded: store.isChangesExpanded)
                        Text("Changed Files")
                            .orbitFont(.caption, weight: .semibold)
                        Badge(count: files.count)
                        DiffStatBadge(added: stats.reduce(0) { $0 + $1.added }, removed: stats.reduce(0) { $0 + $1.removed })
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(store.isChangesExpanded ? "Hide changed files" : "Show changed files")
                Spacer(minLength: 4)
                HStack(spacing: 0) {
                    IconButton("chevron.up", help: store.commands.help("editor.previousChange")) {
                        store.commands.run("editor.previousChange", teaching: true)
                    }
                    IconButton("chevron.down", help: store.commands.help("editor.nextChange")) {
                        store.commands.run("editor.nextChange", teaching: true)
                    }
                    IconButton("arrow.uturn.backward", help: store.commands.help("review.rejectAll", "Undo All")) {
                        changes.rejectAll()
                    }
                }
                .foregroundStyle(.secondary)
                Button("Keep All") { changes.acceptAll() }
                    .buttonStyle(.glassProminent)
                    .help(store.commands.help("review.acceptAll", "Keep All"))
            }
            .controlSize(.small)
            .padding(.horizontal, 14)
            // The composer below brings its own margin.
            .padding(.top, 4)
            if store.isChangesExpanded {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(files.enumerated()), id: \.element) { index, url in
                            ChangedFileRow(url: url, stats: stats[index], changes: changes, author: store.author(of: url)) {
                                if let author = store.author(of: url) { store.selectedID = author.id }
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
                // About six rows, then it scrolls; the transcript keeps the space.
                .frame(maxHeight: 156)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
            }
        }
        .overlay(alignment: .top) { Divider() }
    }
}

private struct ChangedFileRow: View {
    let url: URL
    let stats: (added: Int, removed: Int)
    let changes: ChangeTracking
    /// The chat that changed it, shown when several are open.
    let author: AgentSession?
    let showAuthor: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            FileIconView(url: url, size: 13)
            Text(url.lastPathComponent)
                .orbitFont(.body)
                .lineLimit(1)
            Text(url.deletingLastPathComponent().lastPathComponent)
                .orbitFont(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)
            if let author {
                Button(action: showAuthor) {
                    AgentIcon(provider: author.provider, size: 12)
                        .foregroundStyle(.secondary)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Changed in “\(author.title)”")
            }
            if isHovering {
                IconButton("arrow.uturn.backward", help: "Undo this file's changes") { changes.reject(url) }
                IconButton("checkmark", help: "Keep this file's changes") { changes.accept(url) }
            } else {
                DiffStatBadge(added: stats.added, removed: stats.removed)
            }
        }
        .frame(height: 24)
        .padding(.horizontal, 8)
        .background(isHovering ? Theme.hoverFill : .clear, in: .capsule)
        .contentShape(.rect)
        .onTapGesture { changes.openReview(for: url) }
        .onHover { isHovering = $0 }
        .help(url.path)
        .contextMenu {
            Button("Open") { changes.openReview(for: url) }
            Divider()
            Button("Keep File") { changes.accept(url) }
            Button("Undo File", role: .destructive) { changes.reject(url) }
        }
    }
}

/// "N to review" in the status bar; clicking opens the list in the chat.
struct PendingChangesStatus: View {
    let store: AgentStore
    let action: () -> Void

    var body: some View {
        let count = store.changes?.changedFiles.count ?? 0
        if count > 0 {
            Button(action: action) {
                Label("\(count) to review", systemImage: "plusminus")
                    .contentTransition(.numericText(value: Double(count)))
                    .animation(.snappy, value: count)
                    .orbitFont(.micro)
                    .foregroundStyle(.orange)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Show the changed files")
        }
    }
}
