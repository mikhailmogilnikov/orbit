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
