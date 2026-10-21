import AppKit
@testable import OrbitEditor
import STTextView
import Testing

/// The keys code editors share, where AppKit's text rules differ (D217, D218).
@MainActor
@Suite struct EditorKeysTests {
    private func editor(_ text: String, _ selections: [NSRange]) -> OrbitTextView {
        let textView = OrbitTextView.scrollableTextView().documentView as! OrbitTextView
        textView.text = text
        textView.selectionRanges = selections
        textView.linesPasteboard = NSPasteboard(name: NSPasteboard.Name("orbit-tests-\(UUID().uuidString)"))
        return textView
    }

    private func caret(_ location: Int) -> NSRange { NSRange(location: location, length: 0) }

    @Test func wordsStopAtPunctuationAndLineBreaks() {
        let text = "foo.bar  baz\n    qux" as NSString
        #expect(CaretMotion.wordLeft(text, from: 7) == 4)
        #expect(CaretMotion.wordLeft(text, from: 4) == 3)
        #expect(CaretMotion.wordLeft(text, from: 3) == 0)
        #expect(CaretMotion.wordLeft(text, from: 9) == 4)
        #expect(CaretMotion.wordRight(text, from: 0) == 3)
        #expect(CaretMotion.wordRight(text, from: 7) == 12)
        // A line break alone; indentation alone.
        #expect(CaretMotion.wordRight(text, from: 12) == 13)
        #expect(CaretMotion.wordLeft(text, from: 13) == 12)
        #expect(CaretMotion.wordLeft(text, from: 17) == 13)
    }

    @Test func homeGoesToTheCodeThenToTheLineStart() {
        let text = "x\n    foo" as NSString
        #expect(CaretMotion.home(text, from: 9) == 6)
        #expect(CaretMotion.home(text, from: 6) == 2)
        #expect(CaretMotion.home(text, from: 2) == 6)
        #expect(CaretMotion.home(text, from: 4) == 6)
    }

    @Test func lineEndDeletesTakeOnlyTheLineBreak() {
        let textView = editor("one\ntwo\nsix", [caret(3)])
        textView.deleteToEndOfLine(nil)
        #expect(textView.text == "onetwo\nsix")
        #expect(textView.selectionRanges == [caret(3)])
        textView.selectionRanges = [caret(6)]
        textView.deleteToEndOfParagraph(nil)
        #expect(textView.text == "onetwosix")
    }

    @Test func wordDeletesJoinLinesAtTheirEdges() {
        let textView = editor("one\ntwo", [caret(4)])
        textView.deleteWordBackward(nil)
        #expect(textView.text == "onetwo")
        #expect(textView.selectionRanges == [caret(3)])
        textView.text = "one\ntwo"
        textView.selectionRanges = [caret(3)]
        textView.deleteWordForward(nil)
        #expect(textView.text == "onetwo")
        textView.text = "a.bar"
        textView.selectionRanges = [caret(5)]
        textView.deleteWordBackward(nil)
        #expect(textView.text == "a.")
    }

    @Test func extendingByWordsKeepsTheAnchor() {
        let textView = editor("foo.bar", [caret(7)])
        textView.moveWordLeftAndModifySelection(nil)
        textView.moveWordLeftAndModifySelection(nil)
        #expect(textView.selectionRanges == [NSRange(location: 3, length: 4)])
        textView.moveWordRightAndModifySelection(nil)
        #expect(textView.selectionRanges == [NSRange(location: 4, length: 3)])
        textView.moveWordLeft(nil)
        #expect(textView.selectionRanges == [caret(3)])
    }

    @Test func commandLeftStopsAtTheCode() {
        let textView = editor("foo\n    bar", [caret(11)])
        textView.moveToLeftEndOfLine(nil)
        #expect(textView.selectionRanges == [caret(8)])
        textView.moveToLeftEndOfLine(nil)
        #expect(textView.selectionRanges == [caret(4)])
        textView.selectionRanges = [caret(11)]
        textView.moveToLeftEndOfLineAndModifySelection(nil)
        #expect(textView.selectionRanges == [NSRange(location: 8, length: 3)])
    }

    @Test func controlReturnBreaksTheLineLikeReturn() {
        let textView = editor("    foo", [caret(7)])
        textView.insertLineBreak(nil)
        #expect(textView.text == "    foo\n    ")
    }

    @Test func copyAndCutWithoutASelectionTakeTheLine() {
        let textView = editor("a\nbc\nd", [caret(3)])
        textView.copy(nil)
        #expect(textView.linesPasteboard.string(forType: .string) == "bc\n")
        textView.selectionRanges = [caret(6)]
        textView.paste(nil)
        #expect(textView.text == "a\nbc\nbc\nd")
        #expect(textView.selectionRanges == [caret(9)])
        textView.selectionRanges = [caret(0)]
        textView.cut(nil)
        #expect(textView.text == "bc\nbc\nd")
        #expect(textView.linesPasteboard.string(forType: .string) == "a\n")
    }

    @Test func deleteLineKeepsTheColumn() {
        let textView = editor("a\nbc\nd", [caret(3)])
        textView.deleteLines()
        #expect(textView.text == "a\nd")
        #expect(textView.selectionRanges == [caret(3)])
        textView.text = "a\nbc"
        textView.selectionRanges = [caret(4)]
        textView.deleteLines()
        #expect(textView.text == "a")
        #expect(textView.selectionRanges == [caret(1)])
    }
}
