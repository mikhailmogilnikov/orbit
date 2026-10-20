import AppKit
import OrbitAPI
import OrbitUI
import SwiftUI

/// A file as a commit left it, with each run of lines' author and age beside
/// it, as GitLens's revision view (D204). A run's menu opens what its commit
/// changed, or the file as it was just before that commit: walking a line's
/// history back one change at a time.
struct GitRevisionView: View {
    let model: GitModel
    let tab: EditorTab

    @State private var loaded: (hash: String, path: String, commit: GitCommit?, text: String?, blame: [GitBlameLine])?
    @State private var lines: [AttributedString] = []
    @State private var isLoaded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !isLoaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if loaded?.text == nil {
                EmptyStateView("Not in This Commit", systemImage: "doc", message: "The file doesn't exist at this revision, or it's binary.")
            } else {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lines.indices, id: \.self) { index in
                            row(index)
                        }
                    }
                    .padding(.vertical, 4)
                    .textSelection(.enabled)
                }
            }
        }
        .nativeSurface(.background)
        .task(id: Extensions.shared.themeKey) { await load() }
    }

    private var header: some View {
        let url = tab.url ?? URL(fileURLWithPath: tab.title)
        return HStack(spacing: 8) {
            FileIconView(url: url)
                .foregroundStyle(.secondary)
            Text(url.lastPathComponent)
                .orbitFont(.body, weight: .medium)
            if let loaded {
                Text("at")
                    .orbitFont(.body)
                    .foregroundStyle(.secondary)
                Badge { Text(GitModel.shortRevision(loaded.hash)).monospaced() }
                if let commit = loaded.commit {
                    Text(commit.subject)
                        .orbitFont(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help("\(commit.subject)\n\(commit.author), \(commit.date.formatted(date: .abbreviated, time: .shortened))")
                }
            }
            Spacer()
            if let url = tab.url, FileManager.default.fileExists(atPath: url.path) {
                Button("Open File") { model.openFile(url) }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func row(_ index: Int) -> some View {
        let blame = loaded?.blame ?? []
        let line = index < blame.count ? blame[index] : nil
        // The author only where a run of the same commit starts, as Xcode's Authors.
        let startsRun = index == 0 || (index - 1 < blame.count && blame[index - 1].hash != line?.hash)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Group {
                if let line, startsRun {
                    Text("\(line.author) · \(CommitRow.age(line.date))")
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help("\(line.summary)\n\(line.author), \(line.date.formatted(date: .abbreviated, time: .shortened))")
                } else {
                    Text(" ")
                }
            }
            .orbitFont(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 150, alignment: .leading)
            Text("\(index + 1)")
                .font(.orbit(.caption).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(minWidth: 32, alignment: .trailing)
            Text(lines[index])
                .orbitFont(.code)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.top, startsRun && index > 0 ? 3 : 0)
        .overlay(alignment: .top) {
            if startsRun, index > 0 {
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }
        }
        .contentShape(.rect)
        .contextMenu {
            if let line, line.isCommitted, let loaded {
                Button("Show Changes of \(String(line.hash.prefix(7)))") {
                    model.openDiff(GitCommitFile(status: .modified, path: loaded.path, oldPath: nil),
                                   in: GitCommit(hash: line.hash, shortHash: String(line.hash.prefix(7)), author: line.author, date: line.date, subject: line.summary))
                }
                Button("Open File Before \(String(line.hash.prefix(7)))") {
                    model.openRevision(path: loaded.path, at: line.hash + "^")
                }
                Button("Copy Commit Hash") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(line.hash, forType: .string)
                }
            }
        }
    }

    private func load() async {
        guard let result = await model.revision(for: tab) else {
            isLoaded = true
            return
        }
        loaded = result
        guard let text = result.text, let url = tab.url else {
            isLoaded = true
            return
        }
        var plain = LineDiff.lines(text)
        if plain.last == "" { plain.removeLast() }
        lines = plain.map { AttributedString($0) }
        isLoaded = true
        guard let highlighter = model.highlighter else { return }
        let spans = await highlighter.highlight(text, as: url)
        lines = Self.colored(plain, spans: spans)
    }

    /// The whole text's colored spans cut into its lines.
    static func colored(_ lines: [String], spans: [SyntaxSpan]) -> [AttributedString] {
        var starts: [Int] = []
        var offset = 0
        for line in lines {
            starts.append(offset)
            offset += line.utf16.count + 1
        }
        var result = lines.map { AttributedString($0) }
        for span in spans {
            var line = max(0, (starts.lastIndex { $0 <= span.range.location }) ?? 0)
            var location = span.range.location
            let end = NSMaxRange(span.range)
            while line < lines.count, location < end {
                let lineEnd = starts[line] + lines[line].utf16.count
                let from = location - starts[line], to = min(end, lineEnd) - starts[line]
                let text = lines[line]
                if from < to, let lower = text.utf16.index(text.utf16.startIndex, offsetBy: from, limitedBy: text.utf16.endIndex),
                   let upper = text.utf16.index(text.utf16.startIndex, offsetBy: to, limitedBy: text.utf16.endIndex),
                   let a = AttributedString.Index(lower, within: result[line]), let b = AttributedString.Index(upper, within: result[line]) {
                    result[line][a..<b].foregroundColor = span.color
                }
                line += 1
                if line < starts.count { location = starts[line] }
            }
        }
        return result
    }
}
