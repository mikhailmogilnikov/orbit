import AppKit
import OrbitAPI
import STTextView

/// Ranges that change together (D202): an HTML or JSX tag's name and its
/// closing tag's. With the caret in one, the server is asked for them; typing
/// there goes to all of them as one edit (`OrbitTextView.linkedEdit`).
@MainActor
final class LinkedEditingController {
    weak var textView: OrbitTextView?
    let geometry: DiagnosticsController
    weak var languages: LanguageIntelligence?
    var url: URL?
    private var request: Task<Void, Never>?

    init(geometry: DiagnosticsController) {
        self.geometry = geometry
    }

    /// Typing inside the ranges keeps them; elsewhere they go and the new spot is asked about.
    func caretMoved() {
        // After the edit that moved the caret has updated the ranges.
        DispatchQueue.main.async { [weak self] in self?.check() }
    }

    private func check() {
        guard let textView, !textView.hasMultipleSelections, textView.textSelection.length == 0 else {
            textView?.linkedRanges = []
            return
        }
        let caret = textView.textSelection.location
        if textView.linkedRanges.contains(where: { $0.location <= caret && caret <= NSMaxRange($0) }) { return }
        textView.linkedRanges = []
        request?.cancel()
        guard let languages, let url else { return }
        let length = geometry.length
        let position = SourcePosition(offset: caret, in: geometry.lineStarts)
        request = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let found = await languages.linkedEditingRanges(at: position, in: url),
                  !Task.isCancelled, let self, let textView = self.textView, geometry.length == length,
                  textView.textSelection.location == caret else { return }
            let starts = geometry.lineStarts
            textView.linkedRanges = found.map { $0.nsRange(in: starts, length: length) }.sorted { $0.location < $1.location }
        }
    }

    /// An edit that didn't go through the linked ranges moved them: they go.
    func textDidChange() {
        guard let textView, !textView.isLinkedEditing else { return }
        textView.linkedRanges = []
    }
}

extension OrbitTextView {
    /// Typing or deleting at the caret inside a linked range, done in every
    /// range; false when it isn't one (the caret's elsewhere, or the typed text
    /// isn't part of a name, which ends linked editing).
    func linkedEdit(_ typed: String, deleting: Bool) -> Bool {
        guard !linkedRanges.isEmpty, !hasMultipleSelections, !hasMarkedText() else { return false }
        let selection = textSelection
        guard let source = linkedRanges.first(where: { $0.location <= selection.location && NSMaxRange(selection) <= NSMaxRange($0) }) else {
            return false
        }
        guard typed.allSatisfy({ $0.isLetter || $0.isNumber || "-_.:$".contains($0) }) else {
            linkedRanges = []
            return false
        }
        var offset = selection.location - source.location
        var length = selection.length
        if deleting, length == 0 {
            // Backspace at a name's start deletes outside it: not linked.
            guard offset > 0 else {
                linkedRanges = []
                return false
            }
            let previous = documentText.rangeOfComposedCharacterSequence(at: selection.location - 1)
            offset -= previous.length
            length = previous.length
        }
        let ranges = linkedRanges
        // The caret's own range last: its selection is the one kept.
        let ordered = ranges.filter { $0 != source } + [source]
        let changes = ordered.map { range in
            CaretEditing.Change(range: NSRange(location: range.location + offset, length: length), text: typed,
                                selection: NSRange(location: (typed as NSString).length, length: 0))
        }
        guard let edit = CaretEditing.combine(changes, in: documentText), edit.selections.count == ranges.count,
              let caret = edit.selections.last else {
            linkedRanges = []
            return false
        }
        isLinkedEditing = true
        apply(edit)
        selectionRanges = [caret]
        isLinkedEditing = false
        let delta = (typed as NSString).length - length
        var shift = 0
        linkedRanges = ranges.map { range in
            let moved = NSRange(location: range.location + shift, length: max(0, range.length + delta))
            shift += delta
            return moved
        }
        return true
    }
}
