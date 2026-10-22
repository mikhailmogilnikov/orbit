import AppKit
import OrbitAPI
import OrbitUI
import SwiftUI

/// What a rename would change, file by file, before it changes anything
/// (D199): ⇧↩ in the rename field, or by itself when files move too. Files
/// can be left out; the rest is applied as the server gave it.
struct RenamePreviewSheet: View {
    let preview: RenamePreview
    let apply: (WorkspaceEdit) -> Void
    let cancel: () -> Void
    @State private var excluded: Set<RenamePreview.Row.ID> = []
    @State private var expanded: Set<RenamePreview.Row.ID> = []
    private let highlighter = StaticHighlighter()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Rename “\(preview.oldName)” to “\(preview.newName)”")
                    .orbitFont(.title, weight: .semibold)
                Text(preview.summary)
                    .orbitFont(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(preview.rows) { row in
                        rowView(row)
                    }
                }
                .padding(4)
            }
            .frame(minHeight: 120, maxHeight: 420)
            .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.smallCorner))
            HStack(spacing: 8) {
                Text(excluded.isEmpty ? " " : "\(excluded.count) left out")
                    .orbitFont(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: cancel)
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { apply(preview.edit(excluding: excluded)) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(excluded.count == preview.rows.count)
            }
        }
        .padding(20)
        .frame(width: 640)
        .pillControls()
        .environment(\.syntaxHighlighter, highlighter)
        .onAppear {
            // One file: its changes are what there is to look at.
            if preview.rows.count == 1, let only = preview.rows.first { expanded = [only.id] }
        }
    }

    @ViewBuilder
    private func rowView(_ row: RenamePreview.Row) -> some View {
        let isOn = !excluded.contains(row.id)
        let isExpanded = expanded.contains(row.id)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Toggle(isOn: Binding(
                    get: { isOn },
                    set: { on in if on { excluded.remove(row.id) } else { excluded.insert(row.id) } }
                )) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                Button {
                    withAnimation(.snappy) {
                        if isExpanded { expanded.remove(row.id) } else { expanded.insert(row.id) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        DisclosureChevron(isExpanded: isExpanded)
                            .foregroundStyle(.secondary)
                            .opacity(row.diff == nil ? 0 : 1)
                        FileIconView(url: row.url)
                        Text(row.title)
                            .orbitFont(.body, weight: .medium)
                            .lineLimit(1)
                        Text(row.detail)
                            .orbitFont(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer(minLength: 8)
                        if let badge = row.badge {
                            Badge(badge, tint: row.diff == nil ? Theme.renamed : nil)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(row.diff == nil)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .opacity(isOn ? 1 : 0.5)
            if isExpanded, let diff = row.diff {
                CompactDiffView(old: diff.old, new: diff.new, url: row.url, maxLines: 200)
                    .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.tinyCorner))
                    .padding(.leading, 28)
                    .padding(.trailing, 6)
                    .padding(.bottom, 6)
                    .opacity(isOn ? 1 : 0.5)
            }
        }
    }
}

/// A rename's edit laid out for the preview: a row per edited file (its text
/// before and after) and per file created, renamed or deleted.
struct RenamePreview {
    struct Row: Identifiable {
        /// The step indexes it stands for.
        let id: Int
        let steps: [Int]
        let url: URL
        let title: String
        let detail: String
        let badge: String?
        let diff: (old: String, new: String)?
    }

    let oldName: String
    let newName: String
    let rows: [Row]
    private let steps: [WorkspaceEdit.Step]

    /// `text`: a file's current text (the editor's when open), nil when it doesn't exist.
    @MainActor init(edit: WorkspaceEdit, oldName: String, newName: String, root: URL?, text: (URL) -> String?) {
        self.oldName = oldName
        self.newName = newName
        steps = edit.steps
        // Steps run in order on simulated texts, so an edit after a rename
        // previews against the renamed file's text.
        var texts: [URL: String?] = [:]
        func current(_ url: URL) -> String? {
            if let known = texts[url] { return known }
            return text(url)
        }
        var edited: [URL: (steps: [Int], old: String, new: String)] = [:]
        var order: [URL] = []
        var rows: [Row] = []
        func relative(_ url: URL) -> String {
            guard let root, url.path.hasPrefix(root.path + "/") else { return url.deletingLastPathComponent().path }
            let folder = String(url.deletingLastPathComponent().path.dropFirst(root.path.count))
            return folder.isEmpty ? "" : String(folder.dropFirst())
        }
        for (index, step) in edit.steps.enumerated() {
            switch step {
            case .edit(let url, let edits):
                guard !edits.isEmpty else { continue }
                let old = current(url) ?? ""
                if edited[url] == nil {
                    edited[url] = ([], old, old)
                    order.append(url)
                }
                let new = SourceEdit.apply(edits, to: old)
                edited[url]?.steps.append(index)
                edited[url]?.new = new
                texts[url] = new
            case .create(let url, _, _):
                texts[url] = ""
                rows.append(Row(id: index, steps: [index], url: url, title: url.lastPathComponent,
                                detail: relative(url), badge: "New file", diff: nil))
            case .rename(let from, let to, _, _):
                texts[to] = current(from)
                texts[from] = .some(nil)
                rows.append(Row(id: index, steps: [index], url: to, title: "\(from.lastPathComponent) → \(to.lastPathComponent)",
                                detail: relative(to), badge: "Renamed", diff: nil))
            case .delete(let url, _, _):
                texts[url] = .some(nil)
                rows.append(Row(id: index, steps: [index], url: url, title: url.lastPathComponent,
                                detail: relative(url), badge: "Deleted", diff: nil))
            }
        }
        let editRows = order.compactMap { url -> Row? in
            guard let entry = edited[url], let first = entry.steps.first else { return nil }
            let new = entry.new
            let stats = CompactDiffView.stats(old: entry.old, new: new)
            let count = max(stats.added, stats.removed)
            return Row(id: first, steps: entry.steps, url: url, title: url.lastPathComponent, detail: relative(url),
                       badge: count == 1 ? "1 line" : "\(count) lines", diff: (entry.old, new))
        }
        self.rows = rows + editRows
    }

    var summary: String {
        let edited = rows.filter { $0.diff != nil }.count
        let moved = rows.count - edited
        var parts = [edited == 1 ? "Changes 1 file" : "Changes \(edited) files"]
        if moved > 0 { parts.append(moved == 1 ? "1 file is created, renamed or deleted" : "\(moved) files are created, renamed or deleted") }
        return parts.joined(separator: "; ") + ". Uncheck what to leave out."
    }

    func edit(excluding excluded: Set<Row.ID>) -> WorkspaceEdit {
        let skipped = Set(rows.filter { excluded.contains($0.id) }.flatMap(\.steps))
        return WorkspaceEdit(steps: steps.enumerated().filter { !skipped.contains($0.offset) }.map(\.element))
    }
}
