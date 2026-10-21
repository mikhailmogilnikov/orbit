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
