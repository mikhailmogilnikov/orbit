import Foundation
@testable import OrbitAgents
import OrbitAPI
import Testing

@Suite struct ReviewCommentTests {
    let url = URL(fileURLWithPath: "/project/Sources/App.swift")

    @Test func findsItsLinesAfterEditsAbove() {
        let comment = ReviewComment(url: url, lines: 2...3, code: "let b = 2\nlet c = 3")
        #expect(comment.located(in: ["a", "b", "let b = 2", "let c = 3"]) == 2...3)
        // Two lines inserted above.
        #expect(comment.located(in: ["x", "y", "a", "b", "let b = 2", "let c = 3"]) == 4...5)
        // Of two copies, the nearer one.
        #expect(comment.located(in: ["let b = 2", "let c = 3", "a", "let b = 2", "let c = 3"]) == 3...4)
        // The code is gone: the old place, clamped to the file.
        #expect(comment.located(in: ["only"]) == 0...0)
    }

    @MainActor @Test func storeSavesReplacesAndDropsEmptyNotes() {
        let store = ReviewCommentStore()
        var comment = ReviewComment(url: url, lines: 0...0, code: "a", text: "  fix this  ")
        store.save(comment)
        #expect(store.comments.map(\.text) == ["fix this"])
        comment.text = "rename it"
        store.save(comment)
        #expect(store.comments.map(\.text) == ["rename it"])
        comment.text = " "
        store.save(comment)
        #expect(store.comments.isEmpty)
    }

    @Test func promptQuotesCurrentCodeAndRemovedLines() {
        let root = URL(fileURLWithPath: "/project")
        let notes = [
            ReviewComment(url: url, lines: 1...1, code: "let total = a + b", removed: "let total = a - b", text: "Why plus?"),
            ReviewComment(url: url, lines: 0...0, code: "import Foundation", text: "Not needed"),
        ]
        let text = ReviewCommentPrompt.text(for: notes, root: root) { _ in "// header\nimport Foundation\nlet total = a + b" }
        #expect(text == """
        Review comments on the code. Please address each one:

        1. `Sources/App.swift` line 2:
        ```swift
        import Foundation
        ```
        Not needed

        2. `Sources/App.swift` line 3:
        ```swift
        let total = a + b
        ```
        Lines removed here:
        ```swift
        let total = a - b
        ```
        Why plus?
        """)
    }
}
