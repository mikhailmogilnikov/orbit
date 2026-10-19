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
            HStack(spacing: 8) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { store.isChangesExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        DisclosureChevron(isExpanded: store.isChangesExpanded)
                            .foregroundStyle(.secondary)
                        Text("\(files.count) file\(files.count == 1 ? "" : "s") changed")
                            .font(.orbit(.caption, weight: .medium))
                        DiffStatBadge(added: stats.reduce(0) { $0 + $1.added }, removed: stats.reduce(0) { $0 + $1.removed })
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(store.isChangesExpanded ? "Hide changed files" : "Show changed files")
                Spacer(minLength: 4)
                IconButton("chevron.down.2", help: "Review next change (⌥⌘↓)") {
                    store.commands.run("editor.nextChange", teaching: true)
                }
                Button("Undo All") { changes.rejectAll() }
                    .buttonStyle(.glass)
                    .help("Undo every agent change (⇧⌘⌫)")
                Button("Keep All") { changes.acceptAll() }
                    .buttonStyle(.glassProminent)
                    .help("Keep every agent change (⇧⌘↩)")
            }
            .controlSize(.small)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
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
                .font(.orbit(.body))
                .lineLimit(1)
            Text(url.deletingLastPathComponent().lastPathComponent)
                .font(.orbit(.caption))
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
        .background(isHovering ? Theme.hoverFill : .clear, in: .rect(cornerRadius: Theme.smallCorner))
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
                    .font(.orbit(.micro))
                    .foregroundStyle(.orange)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Show the changed files")
        }
    }
}
