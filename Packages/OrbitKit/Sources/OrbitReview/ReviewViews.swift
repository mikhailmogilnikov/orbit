import OrbitAPI
import OrbitUI
import SwiftUI

struct ChangesListView: View {
    let tracker: ChangeTracker

    var body: some View {
        let files = tracker.changedFiles
        VStack(spacing: 0) {
            if files.isEmpty {
                EmptyStateView("No Pending Changes", systemImage: "checkmark.seal", message: "Edits made by agents show up here for review.")
            } else {
                List {
                    Section("\(files.count) file\(files.count == 1 ? "" : "s") changed") {
                        ForEach(files, id: \.self) { url in
                            ChangedFileRow(url: url, tracker: tracker)
                        }
                    }
                }
                .listStyle(.sidebar)
                HStack(spacing: 8) {
                    Button("Reject All", role: .destructive) { tracker.rejectAll() }
                        .buttonStyle(.glass)
                    Button("Accept All") { tracker.acceptAll() }
                        .buttonStyle(.glassProminent)
                }
                .controlSize(.regular)
                .padding(10)
            }
        }
    }
}

struct ChangedFileRow: View {
    let url: URL
    let tracker: ChangeTracker

    var body: some View {
        let stats = tracker.stats(for: url)
        Button {
            tracker.openReview(for: url)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tracker.baseline(for: url) == nil ? "doc.badge.plus" : FileIcon.systemImage(for: url))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent)
                        .lineLimit(1)
                    Text(url.deletingLastPathComponent().lastPathComponent)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                DiffStatBadge(added: stats.added, removed: stats.removed)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Accept File") { tracker.accept(url) }
            Button("Reject File", role: .destructive) { tracker.reject(url) }
        }
    }
}

struct PendingChangesStatus: View {
    let tracker: ChangeTracker

    var body: some View {
        let count = tracker.changedFiles.count
        if count > 0 {
            Label("\(count) to review", systemImage: "plusminus")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}
