@testable import OrbitEditor
import Testing

@Suite struct InlineEditTests {
    let file = ["func a() {", "    return 1", "}", "", "func b() {}"]

    @Test func targetsSelectionBlankLineOrNewLineAfterCaret() {
        #expect(InlineEdit.target(fileLines: file, selected: 0...2, hasSelection: true) == .init(lines: 0..<3, original: Array(file[0...2])))
        #expect(InlineEdit.target(fileLines: file, selected: 3...3, hasSelection: false) == .init(lines: 3..<4, original: [""]))
        #expect(InlineEdit.target(fileLines: file, selected: 1...1, hasSelection: false) == .init(lines: 2..<2, original: []))
    }

    @Test func takesTheFirstFencedBlock() {
        #expect(InlineEdit.code(fromReply: "Here:\n```swift\n    return 2\n```\nDone.") == "    return 2")
        #expect(InlineEdit.code(fromReply: "````\nlet s = \"```\"\n````") == "let s = \"```\"")
        #expect(InlineEdit.code(fromReply: "\n    return 3\n") == "    return 3")
    }

    @Test func replacesOrInsertsLines() {
        let replaced = InlineEdit.apply("    return 2\n    // two", to: file, target: .init(lines: 1..<2, original: ["    return 1"]))
        #expect(replaced == ["func a() {", "    return 2", "    // two", "}", "", "func b() {}"])
        let inserted = InlineEdit.apply("// note", to: file, target: .init(lines: 2..<2, original: []))
        #expect(inserted == ["func a() {", "    return 1", "// note", "}", "", "func b() {}"])
    }

    @Test func promptShowsTheLinesOrThePlace() {
        let rewrite = InlineEdit.prompt(instruction: " return two ", path: "src/a.swift", fileLines: file, target: .init(lines: 1..<2, original: ["    return 1"]))
        #expect(rewrite.contains("Rewrite line 2 of `src/a.swift`"))
        #expect(rewrite.contains("Instruction: return two\n"))
        #expect(rewrite.contains("```swift\n    return 1\n```"))
        let insert = InlineEdit.prompt(instruction: "log", path: "src/a.swift", fileLines: file, target: .init(lines: 2..<2, original: []))
        #expect(insert.contains("before line 3"))
        #expect(insert.contains("    return 1\n⟨here⟩\n}"))
    }
}
