import AppKit
import OrbitAPI
import STTextView

/// Completion while typing (D56). One request per word: further typing
/// filters the list locally (FuzzyPattern) until the server said the list was
/// incomplete; superseded requests are cancelled. Only visible rows exist
/// (NSTableView), and details are resolved for the selected row only.
@MainActor
final class CompletionController: NSObject {
    private unowned let editor: CodeEditor.Coordinator

    private struct Candidate {
        var item: CompletionItem
        let filter: [UInt16]
    }

    /// Start of what's being completed (the word, or right after a `.`).
    private var anchor = 0
    private var isActive = false
    /// Opened by `.` and the like: deleting back to the anchor keeps it open.
    private var openedByCharacter = false
    private var isIncomplete = false
    private var candidates: [Candidate] = []
    private var shown: [Int] = []
    private var lastPattern: String?
    private var requestCaret = 0
    private var requestTask: Task<Void, Never>?
    private var resolveTask: Task<Void, Never>?
    /// Our own insertions shouldn't reopen the list.
    private(set) var isApplying = false

    private var panelStorage: CompletionPanel?
    private var panel: CompletionPanel {
        if let panelStorage { return panelStorage }
        let panel = CompletionPanel()
        panel.list.dataSource = self
        panel.list.delegate = self
        panel.list.target = self
        panel.list.doubleAction = #selector(acceptClicked)
        panelStorage = panel
        return panel
    }

    let signatures: SignatureHelpController
    private var snippet: SnippetSession?

    init(editor: CodeEditor.Coordinator) {
        self.editor = editor
        signatures = SignatureHelpController(editor: editor)
    }

    var isVisible: Bool { isActive && panelStorage?.isVisible == true }

    private var textView: STTextView? { editor.textView }
    private var text: NSString? { editor.diagnosticsController.string }
    private var caret: Int { textView?.textSelection.location ?? 0 }

    // MARK: Following the text

    /// After every edit, with what replaced what.
    func textDidChange(location: Int, oldLength: Int, replacement: String) {
        guard !isApplying else { return }
        let length = replacement.utf16.count
        snippet = snippet?.adjusted(location: location, oldLength: oldLength, newLength: length)
        // The view may not have moved its caret yet when this arrives.
        let caret = location + length
        guard let textView, let languages = editor.languages,
              textView.undoManager?.isUndoing != true, textView.undoManager?.isRedoing != true,
              !textView.hasMarkedText() else {
            close()
            signatures.close()
            return
        }
        let triggers = languages.triggers(for: editor.document.url)

        if replacement.isEmpty {
            if isActive {
                if caret < anchor || (caret == anchor && !openedByCharacter) {
                    close()
                } else {
                    refilter(caret: caret)
                    if isIncomplete { request(.incomplete, at: caret) }
                }
            }
            signatures.refresh(trigger: nil, caret: caret)
            return
        }
        guard length == 1, let unit = replacement.utf16.first else {
            close()
            signatures.close()
            return
        }

        if Self.isWordCharacter(unit) {
            if isActive {
                refilter(caret: caret)
                if isIncomplete { request(.incomplete, at: caret) }
            } else if let start = wordStart(before: caret), let text, !Self.isDigit(text.character(at: start)) {
                open(anchor: start, trigger: .invoked, at: caret)
            }
        } else if triggers.completion.contains(replacement), replacement != " " {
            open(anchor: caret, trigger: .character(replacement), at: caret)
        } else {
            close()
        }

        if triggers.signatureHelp.contains(replacement) {
            signatures.request(trigger: replacement, isRetrigger: signatures.isVisible, caret: caret)
        } else {
            signatures.refresh(trigger: triggers.signatureHelpRetrigger.contains(replacement) ? replacement : nil, caret: caret)
        }
    }

    /// The caret moved without typing (click, arrows): the list follows or closes.
    func selectionDidChange() {
        guard !isApplying else { return }
        // Typing also moves the caret, possibly before the text-change call:
        // judge once both have arrived.
        DispatchQueue.main.async { [weak self] in
            guard let self, !isApplying, let selection = textView?.textSelection else { return }
            if isActive, selection.length > 0 || selection.location < anchor || selection.location > (wordEnd(after: anchor) ?? anchor) {
                close()
            }
            if snippet?.contains(selection) == false { snippet = nil }
            signatures.caretMoved()
        }
    }

    /// The view scrolled (typing at the bottom does): the list moves with its word.
    func reposition() {
        guard isVisible else { return }
        guard let rect = editor.screenRect(at: anchor) else {
            close()
            return
        }
        panel.show(below: rect, in: textView?.window)
    }

    /// ⌃Space: whatever fits here, even with nothing typed.
    func invoke() {
        guard editor.languages != nil else {
            NSSound.beep()
            return
        }
        open(anchor: wordStart(before: caret) ?? caret, trigger: .invoked, at: caret)
    }

    // MARK: Keys

    /// Keys the list (or a snippet, or signature help) takes over; false lets the text view have them.
    func handle(_ selector: Selector) -> Bool {
        let command = NSStringFromSelector(selector)
        if isVisible {
            switch command {
            case "moveDown:": move(by: 1); return true
            case "moveUp:": move(by: -1); return true
            case "pageDown:", "scrollPageDown:": move(by: CompletionPanel.maxRows); return true
            case "pageUp:", "scrollPageUp:": move(by: -CompletionPanel.maxRows); return true
            case "insertNewline:", "insertTab:": acceptSelected(); return true
            case "cancelOperation:": close(); return true
            default: break
            }
        }
        switch command {
        case "complete:":
            invoke()
            return true
        case "insertTab:" where snippet != nil:
            advanceSnippet(by: 1)
            return true
        case "insertBacktab:" where snippet != nil:
            advanceSnippet(by: -1)
            return true
        case "cancelOperation:":
            if signatures.isVisible {
                signatures.close()
                return true
            }
            if snippet != nil {
                snippet = nil
                return true
            }
            return false
        default:
            return false
        }
    }

    // MARK: Session

    private func open(anchor: Int, trigger: CompletionTrigger, at caret: Int) {
        self.anchor = anchor
        isActive = true
        if case .character = trigger { openedByCharacter = true } else { openedByCharacter = false }
        isIncomplete = false
        candidates = []
        shown = []
        lastPattern = nil
        request(trigger, at: caret)
    }

    func close() {
        requestTask?.cancel()
        resolveTask?.cancel()
        requestTask = nil
        isActive = false
        candidates = []
        shown = []
        panelStorage?.hide()
    }

    /// Incomplete lists are asked again after a short pause, not on every keystroke.
    private func request(_ trigger: CompletionTrigger, at caret: Int) {
        guard let languages = editor.languages else { return }
        requestTask?.cancel()
        requestCaret = caret
        let position = SourcePosition(offset: requestCaret, in: editor.diagnosticsController.lineStarts)
        let url = editor.document.url
        requestTask = Task { [weak self] in
            if trigger == .incomplete {
                try? await Task.sleep(for: .milliseconds(40))
                guard !Task.isCancelled else { return }
            }
            let list = await languages.completions(at: position, in: url, trigger: trigger)
            guard !Task.isCancelled, let self, isActive else { return }
            guard let list else {
                close()
                return
            }
            receive(list)
        }
    }

    private func receive(_ list: CompletionList) {
        isIncomplete = list.isIncomplete
        candidates = list.items.map { Candidate(item: $0, filter: Array($0.filterText.utf16)) }
        lastPattern = nil
        refilter(caret: caret)
    }

    private func refilter(caret: Int) {
        guard isActive, let text else { return }
        guard caret >= anchor, caret <= text.length else {
            close()
            return
        }
        guard !candidates.isEmpty else { return }
        let typed = text.substring(with: NSRange(location: anchor, length: caret - anchor))
        let pattern = FuzzyPattern(typed)
        // A longer pattern only narrows what the shorter one matched.
        let pool: [Int] = if let lastPattern, typed.hasPrefix(lastPattern) { shown } else { Array(candidates.indices) }
        var scored: [(index: Int, score: Int)] = []
        scored.reserveCapacity(pool.count)
        for index in pool {
            if let score = pattern.score(candidates[index].filter) { scored.append((index, score)) }
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let left = candidates[lhs.index].item, right = candidates[rhs.index].item
            if left.sortText != right.sortText { return left.sortText < right.sortText }
            return left.label.utf16.count < right.label.utf16.count
        }
        shown = scored.map(\.index)
        lastPattern = typed

        // Nothing fits: hidden, but the session stays until the word ends, so
        // typing a new name doesn't ask the server on every key.
        guard !shown.isEmpty else {
            panelStorage?.hide()
            return
        }
        let preselected = typed.isEmpty ? shown.firstIndex { candidates[$0].item.isPreselected } : nil
        show(pattern: pattern, selecting: preselected ?? 0)
    }

    private func show(pattern: FuzzyPattern, selecting row: Int) {
        guard let textView, let rect = editor.screenRect(at: anchor) else {
            close()
            return
        }
        panel.pattern = pattern
        panel.font = textView.font
        panel.reload(rows: shown.count, widthHint: widthHint())
        panel.select(row: row)
        panel.show(below: rect, in: textView.window)
        scheduleResolve()
    }

    /// Wide enough for the longest of the first rows, by character count (measuring text costs).
    private func widthHint() -> (label: Int, detail: Int) {
        var label = 0, detail = 0
        for index in shown.prefix(40) {
            let item = candidates[index].item
            label = max(label, item.label.count)
            detail = max(detail, item.detail?.count ?? 0)
        }
        return (label, detail)
    }

    private func move(by delta: Int) {
        guard !shown.isEmpty else { return }
        let current = panel.list.selectedRow
        var row = current + delta
        if abs(delta) == 1 {
            row = (row + shown.count) % shown.count
        } else {
            row = min(max(0, row), shown.count - 1)
        }
        panel.select(row: row)
        scheduleResolve()
    }

    /// Documentation for the selected row only, after the selection rests.
    private func scheduleResolve() {
        resolveTask?.cancel()
        let row = panel.list.selectedRow
        guard shown.indices.contains(row), let languages = editor.languages else { return }
        let index = shown[row]
        panel.showDetails(of: candidates[index].item)
        guard candidates[index].item.needsResolve else { return }
        let url = editor.document.url
        let item = candidates[index].item
        resolveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            let resolved = await languages.resolve(item, in: url)
            guard !Task.isCancelled, let self, candidates.indices.contains(index), candidates[index].item.token == item.token else { return }
            candidates[index].item = resolved
            if panel.list.selectedRow == row { panel.showDetails(of: resolved) }
        }
    }

    @objc private func acceptClicked() {
        acceptSelected()
    }

    private func acceptSelected() {
        let row = panel.list.selectedRow
        guard shown.indices.contains(row) else {
            close()
            return
        }
        let item = candidates[shown[row]].item
        close()
        accept(item)
    }

    // MARK: Inserting

    private func accept(_ item: CompletionItem) {
        guard let textView, let text else { return }
        let caret = caret
        let starts = editor.diagnosticsController.lineStarts
        var start = anchor, end = caret
        if let range = item.range {
            start = min(range.start.offset(in: starts, length: text.length), caret)
            end = max(range.end.offset(in: starts, length: text.length), caret)
        }
        let snippet = item.isSnippet ? Snippet(item.insertText) : nil
        let inserted = snippet?.text ?? item.insertText

        isApplying = true
        textView.breakUndoCoalescing()
        textView.insertText(inserted, replacementRange: NSRange(location: start, length: end - start))
        textView.breakUndoCoalescing()
        isApplying = false

        if let snippet, !snippet.tabStops.isEmpty {
            self.snippet = SnippetSession(snippet: snippet, at: start)
            advanceSnippet(by: 1)
        } else {
            // Completing inside a placeholder keeps the snippet going.
            self.snippet = self.snippet?.adjusted(location: start, oldLength: end - start, newLength: inserted.utf16.count)
            textView.textSelection = NSRange(location: start + inserted.utf16.count, length: 0)
        }

        applyAdditionalEdits(of: item, before: start)
        if inserted.hasSuffix("("), editor.languages?.triggers(for: editor.document.url).signatureHelp.contains("(") == true {
            signatures.request(trigger: "(", isRetrigger: false)
        }
    }

    /// Auto-imports: often only known after resolving, so they may land a moment later.
    private func applyAdditionalEdits(of item: CompletionItem, before mainStart: Int) {
        guard let languages = editor.languages else { return }
        let url = editor.document.url
        Task { [weak self] in
            let edits = item.needsResolve ? await languages.resolve(item, in: url).additionalEdits : item.additionalEdits
            self?.apply(edits, before: mainStart)
        }
    }

    private func apply(_ edits: [SourceEdit], before mainStart: Int) {
        guard !edits.isEmpty, let textView, let text else { return }
        let starts = SourcePosition.lineStarts(of: text)
        let ranges = edits.compactMap { edit -> (NSRange, String)? in
            let range = edit.range.nsRange(in: starts, length: text.length)
            return NSMaxRange(range) <= mainStart ? (range, edit.newText) : nil
        }.sorted { $0.0.location > $1.0.location }
        guard !ranges.isEmpty else { return }
        var selection = textView.textSelection
        isApplying = true
        textView.breakUndoCoalescing()
        for (range, newText) in ranges {
            textView.insertText(newText, replacementRange: range)
            let delta = newText.utf16.count - range.length
            if range.location <= selection.location { selection.location += delta }
            snippet = snippet?.shifted(from: range.location, by: delta)
        }
        textView.breakUndoCoalescing()
        isApplying = false
        textView.textSelection = selection
    }

    private func advanceSnippet(by step: Int) {
        guard var session = snippet, let textView else { return }
        guard let range = session.advance(by: step) else {
            snippet = nil
            return
        }
        snippet = session.isFinished ? nil : session
        isApplying = true
        textView.textSelection = range
        isApplying = false
    }

    // MARK: Words

    private func wordStart(before offset: Int) -> Int? {
        guard let text else { return nil }
        var start = min(offset, text.length)
        while start > 0, Self.isWordCharacter(text.character(at: start - 1)) { start -= 1 }
        return start < offset ? start : nil
    }

    private func wordEnd(after offset: Int) -> Int? {
        guard let text else { return nil }
        var end = offset
        while end < text.length, Self.isWordCharacter(text.character(at: end)) { end += 1 }
        return end
    }

    static func isWordCharacter(_ unit: unichar) -> Bool {
        if unit == 0x5F || unit == 0x24 { return true } // _ $
        if unit < 0x80 {
            return (unit >= 0x30 && unit <= 0x39) || (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A)
        }
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return scalar.properties.isAlphabetic
    }

    static func isDigit(_ unit: unichar) -> Bool { unit >= 0x30 && unit <= 0x39 }
}

extension CompletionController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard shown.indices.contains(row) else { return nil }
        return panel.cell(for: candidates[shown[row]].item, in: tableView)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        CompletionRowView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard isActive else { return }
        scheduleResolve()
    }
}

// MARK: Snippet placeholders

/// Tab stops of an inserted snippet, kept in step with edits: Tab and ⇧Tab
/// walk them, typing inside one grows it, an edit elsewhere ends it.
struct SnippetSession {
    private var stops: [NSRange]
    private var current = -1
    private(set) var isFinished = false

    init(snippet: Snippet, at start: Int) {
        stops = snippet.tabStops.map { NSRange(location: start + $0.range.location, length: $0.range.length) }
        // Without `$0` the caret ends after the snippet.
        if snippet.tabStops.last?.index != 0 {
            stops.append(NSRange(location: start + snippet.text.utf16.count, length: 0))
        }
    }

    mutating func advance(by step: Int) -> NSRange? {
        let next = current + step
        guard stops.indices.contains(next) else { return step < 0 ? stops.first : nil }
        current = next
        if current == stops.count - 1 { isFinished = true }
        return stops[current]
    }

    func contains(_ selection: NSRange) -> Bool {
        guard stops.indices.contains(current) else { return true }
        let stop = stops[current]
        return selection.location >= stop.location && NSMaxRange(selection) <= NSMaxRange(stop)
    }

    /// nil when the edit isn't inside the current placeholder.
    func adjusted(location: Int, oldLength: Int, newLength: Int) -> SnippetSession? {
        guard stops.indices.contains(current) else { return self }
        let stop = stops[current]
        guard location >= stop.location, location + oldLength <= NSMaxRange(stop) else { return nil }
        var copy = self
        let delta = newLength - oldLength
        copy.stops[current].length += delta
        for index in copy.stops.indices where index != current && copy.stops[index].location >= NSMaxRange(stop) {
            copy.stops[index].location += delta
        }
        return copy
    }

    func shifted(from location: Int, by delta: Int) -> SnippetSession {
        var copy = self
        for index in copy.stops.indices where copy.stops[index].location >= location {
            copy.stops[index].location += delta
        }
        return copy
    }
}

// MARK: Signature help

/// The call being typed, above the line: parameters, the current one in bold.
@MainActor
final class SignatureHelpController {
    private unowned let editor: CodeEditor.Coordinator
    private var task: Task<Void, Never>?
    private var openedAt = 0
    private var panelStorage: SignaturePanel?
    private var panel: SignaturePanel {
        if let panelStorage { return panelStorage }
        let panel = SignaturePanel()
        panelStorage = panel
        return panel
    }

    init(editor: CodeEditor.Coordinator) {
        self.editor = editor
    }

    var isVisible: Bool { panelStorage?.isVisible == true }

    /// `caret` when the view may not have moved its own yet (right after an edit).
    func request(trigger: String?, isRetrigger: Bool, caret: Int? = nil) {
        guard let languages = editor.languages, let textView = editor.textView else { return }
        task?.cancel()
        let caret = caret ?? textView.textSelection.location
        if !isVisible { openedAt = caret }
        let position = SourcePosition(offset: caret, in: editor.diagnosticsController.lineStarts)
        let url = editor.document.url
        task = Task { [weak self] in
            if isRetrigger { try? await Task.sleep(for: .milliseconds(60)) }
            guard !Task.isCancelled else { return }
            let help = await languages.signatureHelp(at: position, in: url, trigger: trigger, isRetrigger: isRetrigger)
            guard !Task.isCancelled, let self else { return }
            guard let help, let rect = editor.screenRect(at: caret) else {
                close()
                return
            }
            panel.show(help, font: editor.textView?.font, above: rect, in: editor.textView?.window)
        }
    }

    /// After an edit inside the call: the active parameter may have changed.
    func refresh(trigger: String?, caret: Int) {
        guard isVisible else { return }
        request(trigger: trigger, isRetrigger: true, caret: caret)
    }

    func caretMoved() {
        guard isVisible, let caret = editor.textView?.textSelection.location else { return }
        if caret < openedAt {
            close()
        } else {
            request(trigger: nil, isRetrigger: true)
        }
    }

    func close() {
        task?.cancel()
        panelStorage?.hide()
    }
}
