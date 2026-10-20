import Foundation
@testable import OrbitAPI
@testable import OrbitEditor
import Testing

/// D202: the typing rules at every caret, as one edit.
@Suite struct CaretEditingTests {
    private let spaces = Indentation(size: 4, spaces: true)
    private let brackets = [SyntaxLanguage.Bracket(start: "(", end: ")"), SyntaxLanguage.Bracket(start: "\"", end: "\"")]

    /// The text and carets after applying each caret's change.
    private func run(_ text: String, _ carets: [NSRange], _ change: (NSString, NSRange) -> CaretEditing.Change?,
                     fallback: (NSString, NSRange) -> CaretEditing.Change) -> (String, [NSRange]) {
        let string = text as NSString
        let changes = carets.map { change(string, $0) ?? fallback(string, $0) }
        guard let edit = CaretEditing.combine(changes, in: string) else { return (text, carets) }
        return (string.replacingCharacters(in: edit.range, with: edit.replacement), edit.selections)
    }

    private func caret(_ location: Int) -> NSRange { NSRange(location: location, length: 0) }

    @Test func returnIndentsAtEveryCaret() {
        let text = "if a {}\n  if b {}\n"
        let (result, carets) = run(text, [caret(6), caret(16)], { CaretEditing.newline($0, at: $1, indentation: spaces) },
                                   fallback: { CaretEditing.plain("\n", at: $1) })
        #expect(result == "if a {\n    \n}\n  if b {\n      \n  }\n")
        #expect(carets == [caret(11), caret(29)])
    }

    @Test func bracketsCloseStepOverAndWrapAtEveryCaret() {
        func type(_ typed: String, _ text: String, _ carets: [NSRange]) -> (String, [NSRange]) {
            run(text, carets, { CaretEditing.typed(typed, in: $0, at: $1, brackets: brackets, autocloseBefore: nil) },
                fallback: { CaretEditing.plain(typed, at: $1) })
        }
        let (opened, inside) = type("(", "f\ng\n", [caret(1), caret(3)])
        #expect(opened == "f()\ng()\n" && inside == [caret(2), caret(6)])
        let (stepped, after) = type(")", opened, inside)
        #expect(stepped == opened && after == [caret(3), caret(7)])
        let (wrapped, selected) = type("\"", "ab cd", [NSRange(location: 0, length: 2), NSRange(location: 3, length: 2)])
        #expect(wrapped == "\"ab\" \"cd\"" && selected == [NSRange(location: 1, length: 2), NSRange(location: 6, length: 2)])
        // A quote after a word stays one character, at that caret only.
        let (mixed, _) = type("\"", "it \n", [caret(2), caret(3)])
        #expect(mixed == "it\" \"\"\n")
    }

    @Test func backspaceTakesPairsAndIndentStops() {
        let (pairs, carets) = run("a()\nb(x)\n", [caret(2), caret(7)], { CaretEditing.deletePair($0, at: $1, brackets: brackets) },
                                  fallback: CaretEditing.plainDelete)
        #expect(pairs == "a\nb()\n" && carets == [caret(1), caret(4)])
        let (indents, _) = run("      x\n  y\n", [caret(6), caret(10)], { CaretEditing.indentBackspace($0, at: $1, indentation: spaces) },
                               fallback: CaretEditing.plainDelete)
        #expect(indents == "    x\ny\n")
    }

    @Test func tabsAndShiftedLines() {
        let (tabbed, _) = run("a\n  b\n", [caret(0), caret(4)], { CaretEditing.tab($0, at: $1, indentation: spaces) },
                              fallback: { CaretEditing.plain("\t", at: $1) })
        #expect(tabbed == "    a\n    b\n")
        // Two selections over separate lines: every touched line once.
        let text = "one\ntwo\nthree\n" as NSString
        let shifted = CaretEditing.shiftLines(text, selections: [caret(1), NSRange(location: 4, length: 6)], indentation: spaces, outward: false)
        #expect(shifted.map { text.replacingCharacters(in: $0.range, with: $0.replacement) } == "    one\n    two\n    three\n")
        #expect(shifted?.selections == [caret(5), NSRange(location: 8, length: 17)])
        let back = CaretEditing.shiftLines("    one\n  two\n", selections: [caret(6), caret(10)], indentation: spaces, outward: true)
        #expect(back?.replacement == "one\ntwo")
        #expect(back?.selections == [caret(2), caret(4)])
    }

    @Test func overlappingChangesKeepTheFirst() {
        let edit = CaretEditing.combine([
            CaretEditing.Change(range: NSRange(location: 0, length: 2), text: "", selection: caret(0)),
            CaretEditing.Change(range: NSRange(location: 1, length: 1), text: "x", selection: caret(1)),
        ], in: "abc")
        #expect(edit?.replacement == "" && edit?.selections == [caret(0)])
    }

    /// D202: squiggles move with the text until the server answers.
    @Test func problemsMoveWithEdits() {
        let insertAbove = TextEdit(range: NSRange(location: 0, length: 0), newLength: 4)
        #expect(DiagnosticsController.moved(NSRange(location: 10, length: 3), by: insertAbove) == NSRange(location: 14, length: 3))
        let typeInside = TextEdit(range: NSRange(location: 11, length: 0), newLength: 2)
        #expect(DiagnosticsController.moved(NSRange(location: 10, length: 3), by: typeInside) == NSRange(location: 10, length: 5))
        let deleteAfter = TextEdit(range: NSRange(location: 20, length: 5), newLength: 0)
        #expect(DiagnosticsController.moved(NSRange(location: 10, length: 3), by: deleteAfter) == NSRange(location: 10, length: 3))
        let deleteAll = TextEdit(range: NSRange(location: 8, length: 10), newLength: 0)
        #expect(DiagnosticsController.moved(NSRange(location: 10, length: 3), by: deleteAll) == NSRange(location: 8, length: 0))
        // A missing `;` right where the user types: the squiggle covers what's typed.
        let typeAt = TextEdit(range: NSRange(location: 5, length: 0), newLength: 1)
        #expect(DiagnosticsController.moved(NSRange(location: 5, length: 0), by: typeAt) == NSRange(location: 5, length: 1))
    }

    /// D202: Expand Selection takes the narrowest syntax that grows it, else word, line, everything.
    @Test func expandSelectionSteps() {
        let text = "let total = price * count\nnext\n" as NSString
        let caret = NSRange(location: 13, length: 0)
        let word = CodeEditor.Coordinator.expanded(caret, candidates: [], in: text)
        #expect(word == NSRange(location: 12, length: 5))
        #expect(CodeEditor.Coordinator.expanded(word, candidates: [], in: text) == NSRange(location: 0, length: 25))
        let syntax = [NSRange(location: 12, length: 5), NSRange(location: 12, length: 13), NSRange(location: 0, length: 25)]
        #expect(CodeEditor.Coordinator.expanded(word, candidates: syntax, in: text) == NSRange(location: 12, length: 13))
    }

    /// D202: the placeholders still to fill are drawn; walked ones and the final caret aren't.
    @Test func snippetPlaceholdersLeftToFill() {
        var session = SnippetSession(snippet: Snippet("for ${1:item} in ${2:list} {$0}"), at: 10)
        #expect(session.placeholders == [NSRange(location: 14, length: 4), NSRange(location: 22, length: 4)])
        _ = session.advance(by: 1)
        _ = session.advance(by: 1)
        #expect(session.placeholders == [NSRange(location: 22, length: 4)])
        _ = session.advance(by: 1)
        #expect(session.placeholders.isEmpty)
    }
}
