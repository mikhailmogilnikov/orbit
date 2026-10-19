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
    /// Which sides `hunks` were made from.
    @State private var diffedSides: Int?

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
                            DiffGapRow(hidden: hiddenLines(before: index))
                            DiffHunkView(hunk: hunk, highlighting: highlighting)
                        }
                        DiffGapRow(hidden: hiddenLinesAfterLast)
                    }
                    .textSelection(.enabled)
                }
            }
        }
        .nativeSurface(.background)
        .task(id: file) { await load(file) }
        // Syntax colors are baked into the highlighting: redo it for another theme.
        .onChange(of: Extensions.shared.themeKey) { Task { await load(file) } }
        // Edits keep the same git status, so re-read the sides periodically too.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard NSApp.isActive else { continue }
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
            FileIconView(url: url)
                .foregroundStyle(.secondary)
            Text(url.lastPathComponent)
                .font(.orbit(.body, weight: .medium))
            if !folder.isEmpty {
                Text(folder)
                    .font(.orbit(.body))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Badge(staged ? "Staged" : "Working Tree")
            if file != nil { DiffStatBadge(added: added, removed: removed) }
            Spacer()
            DiffLayoutToggle()
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
            diffedSides = nil
            isLoaded = true
            return
        }
        guard case .text(let old) = sides.old, case .text(let new) = sides.new else {
            isBinary = true
            diffedSides = nil
            isLoaded = true
            return
        }
        var hasher = Hasher()
        hasher.combine(old)
        hasher.combine(new)
        let sidesKey = hasher.finalize()
        hasher.combine(Extensions.shared.themeKey)
        let key = hasher.finalize()
        // The periodic reload mostly finds the same sides: nothing to diff or color again.
        if isLoaded, !isBinary, sidesKey == diffedSides, key == highlightedSides { return }
        let result = await Task.detached(priority: .userInitiated) {
            (LineDiff.hunks(old: old, new: new, context: 3), LineDiff.lines(new).count)
        }.value
        isBinary = false
        // Unchanged results keep the view (and any text selection) as is.
        if hunks != result.0 { hunks = result.0 }
        lineCount = result.1
        isLoaded = true
        diffedSides = sidesKey
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

