import OrbitAPI
import OrbitUI
import SwiftUI

/// Read-only diff of one file, opened from the Source Control panel.
struct GitDiffView: View {
    let model: GitModel
    let url: URL
    let staged: Bool

    @State private var hunks: [DiffHunk] = []
    @State private var lineCount = 0
    @State private var isBinary = false
    @State private var isLoaded = false
    @State private var highlighting: DiffHighlighting?
    /// Which sides `highlighting` was made for; the view reloads every few seconds.
    @State private var highlightedSides: Int?

    var body: some View {
        let file = model.file(at: url)
        let hasChange = file.map { staged ? $0.staged != nil : $0.unstaged != nil } ?? false
        VStack(spacing: 0) {
            header(file: hasChange ? file : nil)
            Divider()
            if !hasChange {
                EmptyStateView("No Changes", systemImage: "checkmark.circle", message: staged ? "Nothing staged for this file." : "This file matches the index.")
            } else if isBinary {
                EmptyStateView("Binary File", systemImage: "doc", message: "Binary changes can't be shown as text.")
            } else if isLoaded, hunks.isEmpty {
                EmptyStateView("No Text Changes", systemImage: "doc.text", message: "Only file mode or line endings changed.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(hunks.enumerated()), id: \.element.id) { index, hunk in
                            GapRow(hidden: hiddenLines(before: index))
                            DiffHunkView(hunk: hunk, highlighting: highlighting)
                        }
                        GapRow(hidden: hiddenLinesAfterLast)
                    }
                    .textSelection(.enabled)
                }
            }
        }
        .background(.background)
        .task(id: file) { await load(file) }
        // Edits keep the same git status, so re-read the sides periodically too.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                model.refresh()
                await load(model.file(at: url))
            }
        }
    }

    private func header(file: GitFileStatus?) -> some View {
        let folder = (model.relativePath(url) as NSString).deletingLastPathComponent
        let added = hunks.reduce(0) { $0 + $1.added }
        let removed = hunks.reduce(0) { $0 + $1.removed }
        return HStack(spacing: 8) {
            Image(systemName: FileIcon.systemImage(for: url))
                .foregroundStyle(.secondary)
            Text(url.lastPathComponent)
                .font(.callout.weight(.medium))
            if !folder.isEmpty {
                Text(folder)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Text(staged ? "Staged" : "Working Tree")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.subtleFill, in: .capsule)
            if file != nil { DiffStatBadge(added: added, removed: removed) }
            Spacer()
            if let file {
                if staged {
                    Button("Unstage") { model.unstage([file]) }
                        .buttonStyle(.glass)
                } else {
                    Button("Discard") { model.discard([file]) }
                        .buttonStyle(.glass)
                    Button("Stage") { model.stage([file]) }
                        .buttonStyle(.glass)
                }
            }
            if FileManager.default.fileExists(atPath: url.path) {
                Button("Open File") { model.openFile(url) }
                    .buttonStyle(.glassProminent)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func load(_ file: GitFileStatus?) async {
        guard let file, let sides = await model.diffSides(of: file, staged: staged) else {
            hunks = []
            isLoaded = true
            return
        }
        guard case .text(let old) = sides.old, case .text(let new) = sides.new else {
            isBinary = true
            isLoaded = true
            return
        }
        let result = await Task.detached(priority: .userInitiated) {
            (LineDiff.hunks(old: old, new: new, context: 3), LineDiff.lines(new).count)
        }.value
        isBinary = false
        // Unchanged results keep the view (and any text selection) as is.
        if hunks != result.0 { hunks = result.0 }
        lineCount = result.1
        isLoaded = true
        var hasher = Hasher()
        hasher.combine(old)
        hasher.combine(new)
        let key = hasher.finalize()
        if key != highlightedSides {
            highlightedSides = key
            highlighting = await DiffHighlighting.make(old: old, new: new, url: url, hunks: result.0, with: model.highlighter)
        }
    }

    private func hiddenLines(before index: Int) -> Int {
        let start = hunks[index].newRange.lowerBound - contextBefore(hunks[index])
        guard index > 0 else { return start }
        let previous = hunks[index - 1]
        return start - (previous.newRange.upperBound + contextAfter(previous))
    }

    private var hiddenLinesAfterLast: Int {
        guard let last = hunks.last else { return 0 }
        return lineCount - (last.newRange.upperBound + contextAfter(last))
    }

    private func contextBefore(_ hunk: DiffHunk) -> Int {
        hunk.lines.prefix { $0.kind == .context }.count
    }

    private func contextAfter(_ hunk: DiffHunk) -> Int {
        hunk.lines.reversed().prefix { $0.kind == .context }.count
    }
}

/// "⋯ 42 unchanged lines" between hunks.
struct GapRow: View {
    let hidden: Int

    var body: some View {
        if hidden > 0 {
            Text("⋯  \(hidden) unchanged line\(hidden == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 96)
                .padding(.vertical, 4)
                .background(Theme.subtleFill)
        }
    }
}
