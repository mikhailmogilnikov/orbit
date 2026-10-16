import Foundation
@testable import OrbitAPI
import Testing
@testable import OrbitEditor

@MainActor
@Suite struct LineEditingTests {
    private func applied(_ text: String, _ edit: LineEditing.Edit?) -> String? {
        guard let edit else { return nil }
        return (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    @Test func moveLineUpAndDownKeepsTheCaretOnIt() throws {
        let text = "a\nbb\nccc"
        let caret = NSRange(location: 3, length: 0) // "b|b"
        let up = try #require(LineEditing.moveLines(text as NSString, selections: [caret], up: true))
        #expect(applied(text, up) == "bb\na\nccc")
        #expect(up.selections == [NSRange(location: 1, length: 0)])
        let down = try #require(LineEditing.moveLines(text as NSString, selections: [caret], up: false))
        #expect(applied(text, down) == "a\nccc\nbb")
        #expect(down.selections == [NSRange(location: 7, length: 0)])
    }

    @Test func movingPastTheEdgeDoesNothing() {
        #expect(LineEditing.moveLines("a\nb" as NSString, selections: [NSRange(location: 0, length: 0)], up: true) == nil)
        #expect(LineEditing.moveLines("a\nb" as NSString, selections: [NSRange(location: 2, length: 0)], up: false) == nil)
    }

    @Test func aSelectionEndingAtALineStartMovesOnlyItsLines() throws {
        let text = "a\nb\nc\n"
        // "a\nb\n" selected: lines 0–1, not line 2.
        let edit = try #require(LineEditing.moveLines(text as NSString, selections: [NSRange(location: 0, length: 4)], up: false))
        #expect(applied(text, edit) == "c\na\nb\n")
        #expect(edit.selections == [NSRange(location: 2, length: 4)])
    }

    @Test func severalCaretsMoveTheirOwnLines() throws {
        let text = "1\n2\n3\n4"
        let edit = try #require(LineEditing.moveLines(text as NSString, selections: [NSRange(location: 2, length: 0), NSRange(location: 6, length: 0)], up: true))
        #expect(applied(text, edit) == "2\n1\n4\n3")
        #expect(edit.selections == [NSRange(location: 0, length: 0), NSRange(location: 4, length: 0)])
    }

    @Test func copyLinesDownMovesTheCaretToTheCopy() throws {
        let text = "x\ny"
        let down = try #require(LineEditing.copyLines(text as NSString, selections: [NSRange(location: 3, length: 0)], down: true))
        #expect(applied(text, down) == "x\ny\ny")
        #expect(down.selections == [NSRange(location: 5, length: 0)])
        let up = try #require(LineEditing.copyLines(text as NSString, selections: [NSRange(location: 0, length: 1)], down: false))
        #expect(applied(text, up) == "x\nx\ny")
        #expect(up.selections == [NSRange(location: 0, length: 1)])
    }

    @Test func nextOccurrenceSelectsTheWordThenItsMatches() throws {
        let text = "foo bar foo foo" as NSString
        let word = try #require(LineEditing.addNextOccurrence(text, selections: [NSRange(location: 1, length: 0)]))
        #expect(word == [NSRange(location: 0, length: 3)])
        let two = try #require(LineEditing.addNextOccurrence(text, selections: word))
        #expect(two == [NSRange(location: 0, length: 3), NSRange(location: 8, length: 3)])
        let three = try #require(LineEditing.addNextOccurrence(text, selections: two))
        #expect(three.last == NSRange(location: 12, length: 3))
        #expect(LineEditing.addNextOccurrence(text, selections: three) == nil)
    }

    @Test func allOccurrencesKeepTheCaretsMatchPrimary() throws {
        let all = try #require(LineEditing.allOccurrences("ab ab ab" as NSString, selections: [NSRange(location: 4, length: 0)]))
        #expect(all == [NSRange(location: 0, length: 2), NSRange(location: 6, length: 2), NSRange(location: 3, length: 2)])
    }

    @Test func caretBelowClampsToTheShorterLine() throws {
        let carets = try #require(LineEditing.addCaret("hello\nhi\nworld" as NSString, selections: [NSRange(location: 4, length: 0)], up: false))
        #expect(carets == [NSRange(location: 4, length: 0), NSRange(location: 8, length: 0)])
        #expect(LineEditing.addCaret("a" as NSString, selections: [NSRange(location: 0, length: 0)], up: true) == nil)
    }

    @Test func goToLineParsesLineAndColumn() {
        #expect(LineEditing.lineAndColumn("12")! == (11, nil))
        #expect(LineEditing.lineAndColumn(" 3:5 ")! == (2, 4))
        #expect(LineEditing.lineAndColumn("0") == nil)
        #expect(LineEditing.lineAndColumn("x") == nil)
    }

    @Test func bracketMatchFindsTheNestedPartner() {
        let pairs = [SyntaxLanguage.Bracket(start: "(", end: ")"), SyntaxLanguage.Bracket(start: "{", end: "}")]
        let text = "f(a, (b)) {}" as NSString
        #expect(BracketMatchController.match(around: 1, in: text, pairs: pairs)! == (1, 8))
        #expect(BracketMatchController.match(around: 9, in: text, pairs: pairs)! == (1, 8)) // after ")"
        #expect(BracketMatchController.match(around: 10, in: text, pairs: pairs)! == (10, 11))
        #expect(BracketMatchController.match(around: 3, in: text, pairs: pairs) == nil)
        #expect(BracketMatchController.match(around: 1, in: "f(a" as NSString, pairs: pairs) == nil)
    }
}
