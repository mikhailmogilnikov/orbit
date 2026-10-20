import OrbitAPI
import OrbitUI
import SwiftUI

/// Read-only diff of one file in a commit, opened from History; or of the
/// file against a branch or commit ("Compare with…", D189).
struct GitCommitDiffView: View {
    let model: GitModel
    let tab: EditorTab

    @State private var commit: GitCommit?
    /// What a compare tab shows the file against.
    @State private var revision: String?
    @State private var file: GitCommitFile?
    @State private var hunks: [DiffHunk] = []
    @State private var lineCount = 0
    @State private var isBinary = false
    @State private var isLoaded = false
    @State private var highlighting: DiffHighlighting?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !isLoaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isBinary {
                EmptyStateView("Binary File", systemImage: "doc", message: "Binary changes can't be shown as text.")
            } else if hunks.isEmpty {
                EmptyStateView(
                    revision == nil ? "No Text Changes" : "No Differences", systemImage: "doc.text",
                    message: revision.map { "The file is the same as on \(Self.short($0))." } ?? "Only file mode changed."
                )
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
        // Again for another theme: syntax colors are baked into the highlighting.
        .task(id: Extensions.shared.themeKey) { await load() }
    }

    private var header: some View {
        let url = tab.url ?? URL(fileURLWithPath: tab.title)
        let added = hunks.reduce(0) { $0 + $1.added }
        let removed = hunks.reduce(0) { $0 + $1.removed }
        return HStack(spacing: 8) {
            FileIconView(url: url)
                .foregroundStyle(.secondary)
            Text(url.lastPathComponent)
                .orbitFont(.body, weight: .medium)
            if let old = file?.oldPath {
                Text("from \(old)")
                    .orbitFont(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if let revision {
                Text("compared with")
                    .orbitFont(.body)
                    .foregroundStyle(.secondary)
                Badge { Text(Self.short(revision)).monospaced() }
            }
            if let commit {
                Badge { Text(commit.shortHash).monospaced() }
                Text(commit.subject)
                    .orbitFont(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("\(commit.subject)\n\(commit.author), \(commit.date.formatted(date: .abbreviated, time: .shortened))")
            }
            if isLoaded, !isBinary { DiffStatBadge(added: added, removed: removed) }
            Spacer()
            DiffLayoutToggle()
            if let url = tab.url, FileManager.default.fileExists(atPath: url.path) {
                Button("Open File") { model.openFile(url) }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private static func short(_ revision: String) -> String {
        revision.count == 40 && revision.allSatisfy(\.isHexDigit) ? String(revision.prefix(7)) : revision
    }

    private func load() async {
        let sides: (old: GitRepository.Side, new: GitRepository.Side)
        if tab.kind == GitModel.compareKind {
            guard let result = await model.compareDiff(for: tab) else {
                isLoaded = true
                return
            }
            revision = result.revision
            sides = result.sides
        } else {
            guard let result = await model.commitDiff(for: tab) else {
                isLoaded = true
                return
            }
            commit = result.commit
            file = result.file
            sides = result.sides
        }
        guard case .text(let old) = sides.old, case .text(let new) = sides.new else {
            isBinary = true
            isLoaded = true
            return
        }
        let diff = await Task.detached(priority: .userInitiated) {
            (LineDiff.hunks(old: old, new: new, context: 3), LineDiff.lines(new).count)
        }.value
        hunks = diff.0
        lineCount = diff.1
        isLoaded = true
        if let url = tab.url {
            highlighting = await DiffHighlighting.make(old: old, new: new, url: url, hunks: diff.0, with: model.highlighter)
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
