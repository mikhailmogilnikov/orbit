import AppKit
import OrbitAPI
import OrbitUI
import SwiftUI

/// Shown when the file changed on disk (usually an agent) on the same lines as
/// unsaved edits. Non-overlapping changes are merged silently and never get here.
struct DiskConflictBanner: View {
    let document: TextDocument
    @Binding var isComparing: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Changed on disk")
                .orbitFont(.body, weight: .medium)
            Text("It conflicts with your unsaved edits.")
                .orbitFont(.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button("Compare…") { isComparing = true }
                .buttonStyle(.glass)
            Button("Use Disk Version") { document.useDiskVersion() }
                .buttonStyle(.glass)
                .help("Discard your unsaved edits")
            Button("Keep Mine") { keepMine() }
                .buttonStyle(.glassProminent)
                .help("Save your version over the one on disk")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func keepMine() {
        do {
            try document.keepMine()
        } catch {
            NSAlert(error: error).runSheetModal()
        }
    }
}

/// The open file is gone from disk (an agent, git or another app removed or moved it).
struct DiskDeletedBanner: View {
    let document: TextDocument
    let workspace: Workspace

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "trash")
                .foregroundStyle(.orange)
            Text("Deleted on disk")
                .orbitFont(.body, weight: .medium)
            Text("Save to keep this file.")
                .orbitFont(.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button("Close") { workspace.requestClose(EditorTab.file(document.url).id) }
                .buttonStyle(.glass)
            Button("Save") {
                do { try document.save() } catch { NSAlert(error: error).runSheetModal() }
            }
            .buttonStyle(.glassProminent)
            .help("Write this text back to disk")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Your buffer against the disk version, with each differing block takeable on its own.
struct DiskConflictComparison: View {
    let document: TextDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let hunks = document.diskConflict.map { LineDiff.hunks(old: document.text, new: $0) } ?? []
        VStack(spacing: 0) {
            header(hunks)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(hunks) { hunk in
                        DiffHunkView(hunk: hunk) {
                            Button("Use Disk") { document.takeFromDisk(hunk) }
                                .buttonStyle(.glass)
                                .controlSize(.small)
                                .help("Replace these lines of yours with the disk version")
                        }
                        Divider()
                    }
                }
                .textSelection(.enabled)
            }
            .background(.background)
            Divider()
            HStack {
                Button("Use Disk Version") { document.useDiskVersion() }
                    .buttonStyle(.glass)
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button("Keep Mine") {
                    do { try document.keepMine() } catch { NSAlert(error: error).runSheetModal() }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 680, idealWidth: 820, minHeight: 420, idealHeight: 580)
    }

    private func header(_ hunks: [DiffHunk]) -> some View {
        HStack(spacing: 8) {
            FileIconView(url: document.url)
                .foregroundStyle(.secondary)
            Text(document.url.lastPathComponent)
                .orbitFont(.body, weight: .medium)
            Text("yours → on disk")
                .orbitFont(.body)
                .foregroundStyle(.secondary)
            DiffStatBadge(added: hunks.reduce(0) { $0 + $1.added }, removed: hunks.reduce(0) { $0 + $1.removed })
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
