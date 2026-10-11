import OrbitAPI
import SwiftUI

/// Renders one hunk as unified-diff lines with a two-column gutter.
public struct DiffHunkView<Actions: View>: View {
    let hunk: DiffHunk
    let showsLineNumbers: Bool
    let actions: Actions

    public init(hunk: DiffHunk, showsLineNumbers: Bool = true, @ViewBuilder actions: () -> Actions) {
        self.hunk = hunk
        self.showsLineNumbers = showsLineNumbers
        self.actions = actions()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(hunk.lines) { line in
                DiffLineRow(line: line, showsLineNumbers: showsLineNumbers)
            }
        }
        .overlay(alignment: .topTrailing) {
            actions.padding(6)
        }
    }
}

extension DiffHunkView where Actions == EmptyView {
    public init(hunk: DiffHunk, showsLineNumbers: Bool = true) {
        self.init(hunk: hunk, showsLineNumbers: showsLineNumbers) { EmptyView() }
    }
}

struct DiffLineRow: View {
    let line: DiffLine
    let showsLineNumbers: Bool

    var body: some View {
        // Top-aligned, and no empty Texts: an empty Text has no baseline, and
        // baseline alignment padded every row with space below the text.
        HStack(alignment: .top, spacing: 0) {
            if showsLineNumbers {
                Text(line.oldNumber.map(String.init) ?? " ")
                    .frame(width: 38, alignment: .trailing)
                Text(line.newNumber.map(String.init) ?? " ")
                    .frame(width: 38, alignment: .trailing)
                    .padding(.trailing, 6)
            }
            Text(marker)
                .frame(width: 14)
                .foregroundStyle(markerColor)
            // Long lines wrap so every row's background spans the full width.
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .foregroundStyle(.tertiary)
        .padding(.vertical, 1)
        .background(background)
    }

    private var marker: String {
        switch line.kind {
        case .added: "+"
        case .removed: "−"
        case .context: " "
        }
    }

    private var markerColor: Color {
        switch line.kind {
        case .added: Theme.added
        case .removed: Theme.removed
        case .context: .clear
        }
    }

    private var background: Color {
        switch line.kind {
        case .added: Theme.addedBackground
        case .removed: Theme.removedBackground
        case .context: .clear
        }
    }
}

/// Compact old→new preview, used inside agent tool-call cards.
public struct CompactDiffView: View {
    let hunks: [DiffHunk]
    let maxLines: Int

    public init(old: String, new: String, maxLines: Int = 40) {
        hunks = LineDiff.hunks(old: old, new: new, context: 2)
        self.maxLines = maxLines
    }

    public var body: some View {
        let visible = visibleHunks
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(visible.enumerated()), id: \.offset) { index, hunk in
                if index > 0 {
                    Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 2)
                }
                DiffHunkView(hunk: hunk, showsLineNumbers: false)
            }
            if truncatedLines > 0 {
                Text("\(truncatedLines) more lines…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
        }
    }

    private var visibleHunks: [DiffHunk] {
        var budget = maxLines
        var result: [DiffHunk] = []
        for var hunk in hunks where budget > 0 {
            if hunk.lines.count > budget { hunk.lines = Array(hunk.lines.prefix(budget)) }
            budget -= hunk.lines.count
            result.append(hunk)
        }
        return result
    }

    private var truncatedLines: Int {
        max(0, hunks.reduce(0) { $0 + $1.lines.count } - maxLines)
    }
}
