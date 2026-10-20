import AppKit
import OrbitAPI
import OrbitUI
import SwiftUI

extension CodeEditor.Coordinator {
    private func edit(_ make: (NSString, [NSRange]) -> LineEditing.Edit?) {
        guard let textView, let edit = make(textView.documentText, textView.selectionRanges) else {
            NSSound.beep()
            return
        }
        closePopups()
        textView.apply(edit)
    }

    private func select(_ make: (NSString, [NSRange]) -> [NSRange]?) {
        guard let textView, let ranges = make(textView.documentText, textView.selectionRanges) else {
            NSSound.beep()
            return
        }
        closePopups()
        textView.selectionRanges = ranges
        textView.scrollToPrimarySelection()
    }

    func moveLines(up: Bool) { edit { LineEditing.moveLines($0, selections: $1, up: up) } }
    func copyLines(down: Bool) { edit { LineEditing.copyLines($0, selections: $1, down: down) } }
    func addNextOccurrence() { select(LineEditing.addNextOccurrence) }
    func selectAllOccurrences() { select(LineEditing.allOccurrences) }
    func addCaret(up: Bool) { select { LineEditing.addCaret($0, selections: $1, up: up) } }

    /// ⌃⇧⌘→: each selection grows to the syntax around it, as the language
    /// server sees it; without one, to its word, its line, then everything (D202).
    func expandSelection() {
        guard let textView else { return NSSound.beep() }
        let current = textView.selectionRanges
        if expandedTo != current { expandedFrom = [] }
        let text = textView.documentText
        let starts = diagnosticsController.lineStarts, length = diagnosticsController.length
        let url = document.url
        Task { [weak self] in
            let chains = await self?.languages?.selectionRanges(at: current.map { SourcePosition(offset: $0.location, in: starts) }, in: url)
            guard let self, let textView = self.textView, textView.selectionRanges == current, length == diagnosticsController.length else { return }
            let grown = current.enumerated().map { index, selection -> NSRange in
                let candidates = (chains?.indices.contains(index) == true ? chains![index] : []).map { $0.nsRange(in: starts, length: length) }
                return Self.expanded(selection, candidates: candidates, in: text)
            }
            guard grown != current else { return NSSound.beep() }
            expandedFrom.append(current)
            expandedTo = grown
            textView.selectionRanges = grown
            textView.scrollToPrimarySelection()
        }
    }

    /// ⌃⇧⌘←: back to the selection before the last Expand Selection.
    func shrinkSelection() {
        guard let textView, expandedTo == textView.selectionRanges, let previous = expandedFrom.popLast() else { return NSSound.beep() }
        expandedTo = previous
        textView.selectionRanges = previous
    }

    /// The narrowest candidate holding more than `selection`; else its word, its line, everything.
    nonisolated static func expanded(_ selection: NSRange, candidates: [NSRange], in text: NSString) -> NSRange {
        func grows(_ range: NSRange) -> Bool {
            range.location <= selection.location && NSMaxRange(selection) <= NSMaxRange(range) && range.length > selection.length
        }
        if let found = candidates.filter(grows).min(by: { $0.length < $1.length }) { return found }
        if let word = LineEditing.word(at: selection.location, in: text), grows(word) { return word }
        var line = text.lineRange(for: selection)
        if NSMaxRange(line) > line.location, NSMaxRange(line) <= text.length, text.character(at: NSMaxRange(line) - 1) == 0x0A { line.length -= 1 }
        if grows(line) { return line }
        return NSRange(location: 0, length: text.length)
    }

    /// ⌃G: a field over the top of the editor, as Xcode's.
    func showGoToLine() {
        guard let textView else {
            NSSound.beep()
            return
        }
        let lines = diagnosticsController.lineStarts.count
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        let field = GoToLineField(lines: lines, current: cursorLine + 1) { [weak self, weak popover] line, column in
            popover?.close()
            self?.reveal(line: min(line, lines - 1), column: column)
        } cancel: { [weak popover, weak textView] in
            popover?.close()
            textView?.window?.makeFirstResponder(textView)
        }
        let host = NSHostingController(rootView: field)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        closePopups()
        closeHover()
        let visible = textView.visibleRect
        popover.show(relativeTo: NSRect(x: visible.midX, y: visible.minY, width: 1, height: 1), of: textView, preferredEdge: .maxY)
    }
}

struct GoToLineField: View {
    let lines: Int
    let current: Int
    let commit: (Int, Int?) -> Void
    let cancel: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let target = LineEditing.lineAndColumn(text)
        VStack(alignment: .leading, spacing: 6) {
            Text("Line 1–\(lines), or line:column")
                .orbitFont(.micro)
                .foregroundStyle(.secondary)
            TextField("\(current)", text: $text)
                .textFieldStyle(.roundedBorder)
                .orbitFont(.control, design: .monospaced)
                .frame(width: 220)
                .focused($focused)
                .onSubmit {
                    if let target { commit(target.line, target.column) } else if text.isEmpty { cancel() } else { NSSound.beep() }
                }
                .onExitCommand(perform: cancel)
        }
        .padding(10)
        .onAppear { focused = true }
    }
}

/// Matches a key press to a command's `editorShortcut`.
enum EditorKeys {
    static func matches(_ event: NSEvent, _ shortcut: KeyboardShortcut) -> Bool {
        var modifiers: NSEvent.ModifierFlags = []
        if shortcut.modifiers.contains(.command) { modifiers.insert(.command) }
        if shortcut.modifiers.contains(.control) { modifiers.insert(.control) }
        if shortcut.modifiers.contains(.option) { modifiers.insert(.option) }
        if shortcut.modifiers.contains(.shift) { modifiers.insert(.shift) }
        // Arrow keys carry .function and .numericPad; only these four count.
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]) == modifiers else { return false }
        return KeyPositions.key(keyCode: event.keyCode, characters: event.characters(byApplyingModifiers: [])) == shortcut.key
    }
}
