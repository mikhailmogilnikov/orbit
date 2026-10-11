import OrbitAPI
import SwiftUI

/// Syntax-colored lines for a diff, by 1-based line number in each side.
public struct DiffHighlighting: Sendable, Equatable {
    public var old: [Int: AttributedString] = [:]
    public var new: [Int: AttributedString] = [:]

    public init() {}

    public init(old: [Int: AttributedString], new: [Int: AttributedString]) {
        self.old = old
        self.new = new
    }

    /// Colors for the lines `hunks` show, in the editor's theme; nil without a highlighter
    /// or for an unknown language.
    @MainActor
    public static func make(old: String, new: String, url: URL, hunks: [DiffHunk], with highlighter: SyntaxHighlighting?) async -> DiffHighlighting? {
        guard let highlighter, !hunks.isEmpty else { return nil }
        // Whole texts, so a line inside a multi-line string or comment is colored right.
        let oldSpans = await highlighter.highlight(old, as: url)
        let newSpans = await highlighter.highlight(new, as: url)
        guard !oldSpans.isEmpty || !newSpans.isEmpty else { return nil }
        let oldNumbers = Set(hunks.flatMap { $0.lines.compactMap(\.oldNumber) })
        let newNumbers = Set(hunks.flatMap { $0.lines.compactMap(\.newNumber) })
        return await Task.detached(priority: .userInitiated) {
            DiffHighlighting(
                old: DiffHighlighting.lines(of: old, spans: oldSpans, numbers: oldNumbers),
                new: DiffHighlighting.lines(of: new, spans: newSpans, numbers: newNumbers)
            )
        }.value
    }

    func text(for line: DiffLine) -> AttributedString? {
        line.kind == .removed ? line.oldNumber.flatMap { old[$0] } : line.newNumber.flatMap { new[$0] }
    }

    /// Colored copies of the given lines of `text` (only those: a diff shows few).
    public static func lines(of text: String, spans: [SyntaxSpan], numbers: Set<Int>) -> [Int: AttributedString] {
        guard !spans.isEmpty, !numbers.isEmpty else { return [:] }
        let string = text as NSString
        var starts = [0]
        for index in 0..<string.length where string.character(at: index) == 0x0A { starts.append(index + 1) }
        func line(containing offset: Int) -> Int {
            var low = 0, high = starts.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if starts[mid] <= offset { low = mid } else { high = mid - 1 }
            }
            return low + 1
        }
        // Spans by the wanted lines they touch, keeping their order (later ones win).
        var spansByLine: [Int: [SyntaxSpan]] = [:]
        for span in spans where span.range.length > 0 {
            let first = line(containing: span.range.location)
            let last = line(containing: NSMaxRange(span.range) - 1)
            for number in first...last where numbers.contains(number) { spansByLine[number, default: []].append(span) }
        }
        var result: [Int: AttributedString] = [:]
        for number in numbers where number >= 1 && number <= starts.count {
            let start = starts[number - 1]
            var end = number < starts.count ? starts[number] - 1 : string.length
            if end > start, string.character(at: end - 1) == 0x0D { end -= 1 }
            let lineRange = NSRange(location: start, length: end - start)
            let lineText = string.substring(with: lineRange)
            var attributed = AttributedString(lineText)
            for span in spansByLine[number] ?? [] {
                let clipped = NSIntersectionRange(span.range, lineRange)
                guard clipped.length > 0,
                      let range = Range(NSRange(location: clipped.location - start, length: clipped.length), in: lineText),
                      let lower = AttributedString.Index(range.lowerBound, within: attributed),
                      let upper = AttributedString.Index(range.upperBound, within: attributed) else { continue }
                attributed[lower..<upper].foregroundColor = span.color
            }
            result[number] = attributed
        }
        return result
    }
}

/// Renders one hunk as unified-diff lines with a two-column gutter.
public struct DiffHunkView<Actions: View>: View {
    let hunk: DiffHunk
    let showsLineNumbers: Bool
    let highlighting: DiffHighlighting?
    let actions: Actions

    public init(hunk: DiffHunk, showsLineNumbers: Bool = true, highlighting: DiffHighlighting? = nil, @ViewBuilder actions: () -> Actions) {
        self.hunk = hunk
        self.showsLineNumbers = showsLineNumbers
        self.highlighting = highlighting
        self.actions = actions()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(hunk.lines) { line in
                DiffLineRow(line: line, showsLineNumbers: showsLineNumbers, highlighted: highlighting?.text(for: line))
            }
        }
        .overlay(alignment: .topTrailing) {
            actions.padding(6)
        }
    }
}

extension DiffHunkView where Actions == EmptyView {
    public init(hunk: DiffHunk, showsLineNumbers: Bool = true, highlighting: DiffHighlighting? = nil) {
        self.init(hunk: hunk, showsLineNumbers: showsLineNumbers, highlighting: highlighting) { EmptyView() }
    }
}

struct DiffLineRow: View {
    let line: DiffLine
    let showsLineNumbers: Bool
    var highlighted: AttributedString?

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
            Text(highlighted.flatMap { $0.characters.isEmpty ? nil : $0 } ?? AttributedString(line.text.isEmpty ? " " : line.text))
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

private struct SyntaxHighlighterKey: EnvironmentKey {
    static var defaultValue: (any SyntaxHighlighting)? { nil }
}

extension EnvironmentValues {
    /// Colors code in diffs below; set by plugins that resolved the service.
    public var syntaxHighlighter: (any SyntaxHighlighting)? {
        get { self[SyntaxHighlighterKey.self] }
        set { self[SyntaxHighlighterKey.self] = newValue }
    }
}

/// Compact old→new preview, used inside agent tool-call cards.
public struct CompactDiffView: View {
    let old: String
    let new: String
    let url: URL?
    let hunks: [DiffHunk]
    let maxLines: Int
    @Environment(\.syntaxHighlighter) private var highlighter
    @State private var highlighting: DiffHighlighting?

    /// `url` picks the language for syntax colors.
    public init(old: String, new: String, url: URL? = nil, maxLines: Int = 40) {
        self.old = old
        self.new = new
        self.url = url
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
                DiffHunkView(hunk: hunk, showsLineNumbers: false, highlighting: highlighting)
            }
            if truncatedLines > 0 {
                Text("\(truncatedLines) more lines…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
        }
        .task(id: [old, new]) {
            guard let url else { return }
            highlighting = await DiffHighlighting.make(old: old, new: new, url: url, hunks: hunks, with: highlighter)
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
