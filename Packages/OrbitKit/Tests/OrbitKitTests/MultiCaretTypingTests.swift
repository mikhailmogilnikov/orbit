import AppKit
@testable import OrbitEditor
import STTextView
import Testing

/// STTextView left one caret, at the top, after typing at several (D215).
@MainActor
@Suite struct MultiCaretTypingTests {
    private func editor(_ text: String, _ selections: [NSRange]) -> OrbitTextView {
        let textView = OrbitTextView.scrollableTextView().documentView as! OrbitTextView
        textView.text = text
        textView.selectionRanges = selections
        return textView
    }

    @Test func typingKeepsEveryCaret() {
        let textView = editor("foo\nfoo\nfoo\n", [NSRange(location: 0, length: 3), NSRange(location: 4, length: 3), NSRange(location: 8, length: 3)])
        textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.insertText("y", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(textView.text == "xy\nxy\nxy\n")
        #expect(textView.selectionRanges == [NSRange(location: 2, length: 0), NSRange(location: 5, length: 0), NSRange(location: 8, length: 0)])
    }

    /// Typing at several carets is one undo step, as at one, and undo puts the carets back.
    @Test func typingAtCaretsUndoesAtOnce() async {
        let scrollView = OrbitTextView.scrollableTextView()
        let textView = scrollView.documentView as! OrbitTextView
        // Key events need a window: STTextView coalesces typing only while handling one.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scrollView
        window.makeFirstResponder(textView)
        textView.text = "a\nb\n"
        let carets = [NSRange(location: 1, length: 0), NSRange(location: 3, length: 0)]
        textView.selectionRanges = carets
        for character in "xyz" {
            let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                       context: nil, characters: String(character), charactersIgnoringModifiers: String(character), isARepeat: false, keyCode: 0)!
            textView.keyDown(with: key)
        }
        #expect(textView.text == "axyz\nbxyz\n")
        textView.undoManager?.undo()
        await Task.yield()
        #expect(textView.text == "a\nb\n")
        #expect(textView.selectionRanges == carets)
        textView.undoManager?.redo()
        await Task.yield()
        #expect(textView.text == "axyz\nbxyz\n")
        #expect(textView.selectionRanges == [NSRange(location: 4, length: 0), NSRange(location: 9, length: 0)])
    }

    @Test func backspaceKeepsEveryCaret() {
        let textView = editor("ab\nab\n", [NSRange(location: 2, length: 0), NSRange(location: 5, length: 0)])
        textView.deleteBackward(nil)
        #expect(textView.text == "a\na\n")
        #expect(textView.selectionRanges == [NSRange(location: 1, length: 0), NSRange(location: 3, length: 0)])
    }

    /// ⌘⌫ deletes to the line's start, then joins the line to the one above (D217).
    @Test func deleteToLineStartGoesOnToThePreviousLine() {
        let textView = editor("one\ntwo", [NSRange(location: 7, length: 0)])
        textView.deleteToBeginningOfLine(nil)
        #expect(textView.text == "one\n")
        #expect(textView.selectionRanges == [NSRange(location: 4, length: 0)])
        textView.deleteToBeginningOfLine(nil)
        #expect(textView.text == "one")
        #expect(textView.selectionRanges == [NSRange(location: 3, length: 0)])
    }
}
