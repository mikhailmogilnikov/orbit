import AppKit
import OrbitAPI
import OrbitUI
import SwiftUI

/// One `<<<<<<< … ======= … >>>>>>>` block a merge, rebase or stash pop left
/// in a file (D134). Lines are 0-based.
struct MergeConflict: Equatable {
    var start: Int
    /// "Current": what the branch you're on has (HEAD).
    var current: Range<Int>
    /// diff3's common ancestor (`||||||| base`), when git wrote it.
    var base: Range<Int>?
    var separator: Int
    /// "Incoming": what's being merged in.
    var incoming: Range<Int>
    var end: Int
    var currentLabel: String
    var incomingLabel: String

    var lines: ClosedRange<Int> { start...end }
}

enum MergeConflicts {
    enum Choice { case current, incoming, both }

    static func hasMarkers(_ text: String) -> Bool { text.contains("<<<<<<<") }

    static func find(in lines: [String]) -> [MergeConflict] {
        func marker(_ line: String, _ character: Character) -> String? {
            let prefix = String(repeating: character, count: 7)
            guard line.hasPrefix(prefix) else { return nil }
            let rest = line.dropFirst(7)
            guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
            return rest.trimmingCharacters(in: .whitespaces)
        }
        var result: [MergeConflict] = []
        var index = 0
        while index < lines.count {
            guard let currentLabel = marker(lines[index], "<") else {
                index += 1
                continue
            }
            let start = index
            var base: Int?, separator: Int?, end: Int?, incomingLabel = ""
            var cursor = start + 1
            while cursor < lines.count {
                let line = lines[cursor]
                if marker(line, "<") != nil { break }
                if separator == nil, base == nil, marker(line, "|") != nil {
                    base = cursor
                } else if separator == nil, line.trimmingCharacters(in: .whitespaces) == "=======" {
                    separator = cursor
                } else if separator != nil, let label = marker(line, ">") {
                    end = cursor
                    incomingLabel = label
                    break
                }
                cursor += 1
            }
            guard let separator, let end else {
                index = max(cursor, start + 1)
                continue
            }
            result.append(MergeConflict(
                start: start,
                current: (start + 1)..<(base ?? separator),
                base: base.map { ($0 + 1)..<separator },
                separator: separator,
                incoming: (separator + 1)..<end,
                end: end,
                currentLabel: currentLabel,
                incomingLabel: incomingLabel
            ))
            index = end + 1
        }
        return result
    }

    static func resolution(_ conflict: MergeConflict, _ choice: Choice, lines: [String]) -> [String] {
        switch choice {
        case .current: Array(lines[conflict.current])
        case .incoming: Array(lines[conflict.incoming])
        case .both: Array(lines[conflict.current]) + Array(lines[conflict.incoming])
        }
    }

    /// The replacement of the conflict's lines, markers and all, as one undoable edit.
    static func edit(_ text: NSString, conflict: MergeConflict, choice: Choice) -> LineEditing.Edit {
        let starts = LineStarts.of(text)
        let lines = LineDiff.lines(text as String)
        let chosen = resolution(conflict, choice, lines: lines)
        let from = starts[conflict.start]
        let hasNextLine = conflict.end + 1 < starts.count
        let to = hasNextLine ? starts[conflict.end + 1] : text.length
        var replacement = chosen.joined(separator: "\n")
        if hasNextLine, !chosen.isEmpty { replacement += "\n" }
        // Nothing chosen at the very end: drop the newline before the block too.
        let range = !hasNextLine && chosen.isEmpty && from > 0
            ? NSRange(location: from - 1, length: to - from + 1)
            : NSRange(location: from, length: to - from)
        return LineEditing.Edit(range: range, replacement: replacement, selections: [NSRange(location: range.location, length: 0)])
    }
}

// MARK: - In the editor

extension InlineDiffController {
    /// Blocks and action bars for the file's conflicts; called from `layoutOverlays`.
    func layoutConflicts(visible: CGRect, width: CGFloat, contentX: CGFloat) {
        guard let textView, !conflicts.isEmpty else { return }
        let incomingColor = NSColor.systemBlue
        func band(_ lines: Range<Int>, _ color: NSColor) -> CGRect? {
            guard !lines.isEmpty, let first = lineRect(lines.lowerBound), let last = lineRect(lines.upperBound - 1) else { return nil }
            let rect = CGRect(x: contentX, y: first.minY, width: width, height: last.maxY - first.minY)
            guard rect.intersects(visible) else { return rect }
            add(ChangeBackgroundView(frame: rect, color: color), below: true)
            return rect
        }
        for conflict in conflicts {
            guard let top = lineRect(conflict.start), let bottom = lineRect(conflict.end) else { continue }
            guard CGRect(x: contentX, y: top.minY, width: width, height: bottom.maxY - top.minY).intersects(visible) else { continue }
            for marker in [conflict.start, conflict.separator, conflict.end] + (conflict.base.map { [$0.lowerBound - 1] } ?? []) {
                _ = band(marker..<(marker + 1), .secondaryLabelColor)
            }
            _ = band(conflict.current, colors.added)
            if let base = conflict.base { _ = band(base, .systemGray) }
            _ = band(conflict.incoming, incomingColor)
            let actions = NSHostingView(rootView: ConflictActions(
                currentLabel: conflict.currentLabel, incomingLabel: conflict.incomingLabel
            ) { [weak self] choice in self?.onResolveConflict?(conflict, choice) })
            let size = actions.fittingSize
            actions.frame = CGRect(x: textView.visibleRect.maxX - size.width - 12, y: top.midY - size.height / 2, width: size.width, height: size.height)
            add(actions, below: false)
        }
    }
}

struct ConflictActions: View {
    let currentLabel: String
    let incomingLabel: String
    let resolve: (MergeConflicts.Choice) -> Void

    var body: some View {
        HStack(spacing: 1) {
            Button("Accept Current") { resolve(.current) }
                .help(currentLabel.isEmpty ? "Keep your side" : "Keep \(currentLabel)")
            Divider().frame(height: 12)
            Button("Accept Incoming") { resolve(.incoming) }
                .help(incomingLabel.isEmpty ? "Take the incoming side" : "Take \(incomingLabel)")
            Divider().frame(height: 12)
            Button("Accept Both") { resolve(.both) }
                .help("Keep both: current, then incoming")
        }
        .buttonStyle(HunkActionStyle())
        .font(.orbit(.micro, weight: .medium))
        .padding(.horizontal, 2)
        .background(.regularMaterial, in: .rect(cornerRadius: Theme.smallCorner))
        .overlay(RoundedRectangle(cornerRadius: Theme.smallCorner).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
    }
}

/// Above a file with conflict markers: how many, prev / next, accept all;
/// once none are left, Mark as Resolved for git.
struct ConflictBanner: View {
    let url: URL
    let count: Int
    let isConflictedInGit: Bool
    let resolver: ConflictResolving?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: count > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(count > 0 ? Theme.conflict : .green)
            Text(count > 0 ? "\(count) merge conflict\(count == 1 ? "" : "s")" : "No conflicts left")
                .font(.orbit(.body, weight: .medium))
            if count > 0 {
                HStack(spacing: 0) {
                    IconButton("chevron.up", help: "Previous conflict") { coordinator?.revealConflict(forward: false) }
                    IconButton("chevron.down", help: "Next conflict") { coordinator?.revealConflict(forward: true) }
                }
            }
            Spacer()
            if count > 0 {
                Menu("Accept All") {
                    Button("Accept All Current") { coordinator?.resolveAllConflicts(.current) }
                    Button("Accept All Incoming") { coordinator?.resolveAllConflicts(.incoming) }
                    Button("Accept All Both") { coordinator?.resolveAllConflicts(.both) }
                }
                .fixedSize()
            } else if isConflictedInGit, let resolver {
                Button("Mark as Resolved") { resolver.markResolved(url) }
                    .buttonStyle(.glassProminent)
                    .help("Stage the file (git add): its conflict is resolved")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.conflict.opacity(count > 0 ? 0.08 : 0.04))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var coordinator: CodeEditor.Coordinator? {
        OpenEditors.shared.coordinators.first { $0.document.url.standardizedFileURL == url.standardizedFileURL }
    }
}

extension CodeEditor.Coordinator {
    func resolveConflict(_ conflict: MergeConflict, _ choice: MergeConflicts.Choice) {
        guard let textView = textView as? OrbitTextView else { return }
        let text = (textView.text ?? "") as NSString
        // The block may have moved since the bar was drawn: find it again.
        let current = MergeConflicts.find(in: LineDiff.lines(text as String))
        guard let fresh = current.first(where: { $0.start == conflict.start }) ?? current.first(where: { $0.currentLabel == conflict.currentLabel && $0.incoming.count == conflict.incoming.count }) else { return }
        textView.apply(MergeConflicts.edit(text, conflict: fresh, choice: choice))
    }

    /// From the last block up, so the earlier ones keep their lines; one undo step each.
    func resolveAllConflicts(_ choice: MergeConflicts.Choice) {
        guard let textView = textView as? OrbitTextView else { return }
        let conflicts = MergeConflicts.find(in: LineDiff.lines(textView.text ?? ""))
        for conflict in conflicts.reversed() {
            textView.apply(MergeConflicts.edit((textView.text ?? "") as NSString, conflict: conflict, choice: choice))
        }
    }

    func revealConflict(forward: Bool) {
        let conflicts = inlineDiff.conflicts
        guard !conflicts.isEmpty else { return }
        let line = cursorLine
        let target = forward
            ? conflicts.first { $0.start > line } ?? conflicts.first
            : conflicts.last { $0.start < line } ?? conflicts.last
        if let target { reveal(line: target.start) }
    }
}
