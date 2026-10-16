import OrbitAPI
import OrbitUI
import SwiftUI

/// Select for Compare, then Compare with Selected (VS Code's): a read-only diff
/// tab of two files, unsaved edits included, following both as they change.
enum CompareFiles {
    static let kind = "explorer.compare"

    static func tab(_ left: URL, _ right: URL) -> EditorTab {
        EditorTab(
            id: "\(kind):\(left.path)\n\(right.path)",
            kind: kind,
            title: "\(left.lastPathComponent) ↔ \(right.lastPathComponent)",
            systemImage: "arrow.left.arrow.right",
            url: right
        )
    }

    static func files(of tab: EditorTab) -> (URL, URL)? {
        let paths = tab.id.dropFirst(kind.count + 1).split(separator: "\n", omittingEmptySubsequences: false)
        guard paths.count == 2 else { return nil }
        return (URL(fileURLWithPath: String(paths[0])), URL(fileURLWithPath: String(paths[1])))
    }
}

struct CompareView: View {
    let workspace: Workspace
    let left: URL
    let right: URL
    let highlighter: SyntaxHighlighting?

    @State private var hunks: [DiffHunk] = []
    @State private var lineCount = 0
    @State private var highlighting: DiffHighlighting?
    @State private var failure: String?
    @State private var isLoaded = false

    var body: some View {
        let documents = workspace.documents
        // Edits in either buffer, and the disk, redo the diff.
        let key = [left, right].map { documents.existingDocument(for: $0)?.revision ?? 0 }
            + [workspace.fileSystemGeneration, Extensions.shared.themeKey.hashValue]
        VStack(spacing: 0) {
            header
            Divider()
            if let failure {
                EmptyStateView("Can't Compare", systemImage: "doc.questionmark", message: failure)
            } else if isLoaded, hunks.isEmpty {
                EmptyStateView("Identical Files", systemImage: "equal.circle", message: "The two files have the same text.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(hunks.enumerated()), id: \.element.id) { index, hunk in
                            DiffGapRow(hidden: hidden(before: index))
                            DiffHunkView(hunk: hunk, highlighting: highlighting)
                        }
                        DiffGapRow(hidden: hiddenAfterLast)
                    }
                    .textSelection(.enabled)
                }
            }
        }
        .nativeSurface(.background)
        .task(id: key) { await load() }
    }

    private var header: some View {
        let added = hunks.reduce(0) { $0 + $1.added }
        let removed = hunks.reduce(0) { $0 + $1.removed }
        return HStack(spacing: 8) {
            name(left)
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            name(right)
            DiffStatBadge(added: added, removed: removed)
            Spacer()
            DiffLayoutToggle()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func name(_ url: URL) -> some View {
        Button {
            workspace.openFile(url)
        } label: {
            HStack(spacing: 4) {
                FileIconView(url: url).foregroundStyle(.secondary)
                Text(url.lastPathComponent).font(.callout.weight(.medium))
            }
        }
        .buttonStyle(.plain)
        .help("Open \(relativePath(url))")
    }

    private func relativePath(_ url: URL) -> String {
        guard let root = workspace.root?.path, url.path.hasPrefix(root + "/") else { return url.path }
        return String(url.path.dropFirst(root.count + 1))
    }

    private func load() async {
        let documents = workspace.documents
        guard let old = documents.currentText(of: left), let new = documents.currentText(of: right) else {
            failure = "Both files must exist and be text."
            isLoaded = true
            return
        }
        failure = nil
        let (result, count) = await Task.detached(priority: .userInitiated) {
            (LineDiff.hunks(old: old, new: new, context: 3), LineDiff.lines(new).count)
        }.value
        if result != hunks { hunks = result }
        lineCount = count
        isLoaded = true
        highlighting = await DiffHighlighting.make(old: old, new: new, url: right, hunks: result, with: highlighter)
    }

    private func context(_ hunk: DiffHunk, after: Bool) -> Int {
        (after ? Array(hunk.lines.reversed()) : hunk.lines).prefix { $0.kind == .context }.count
    }

    private func hidden(before index: Int) -> Int {
        let start = hunks[index].newRange.lowerBound - context(hunks[index], after: false)
        guard index > 0 else { return start }
        return start - (hunks[index - 1].newRange.upperBound + context(hunks[index - 1], after: true))
    }

    private var hiddenAfterLast: Int {
        guard let last = hunks.last else { return 0 }
        return lineCount - (last.newRange.upperBound + context(last, after: true))
    }
}
