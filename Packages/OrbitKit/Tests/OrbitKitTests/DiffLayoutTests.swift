import Testing
@testable import OrbitAPI
@testable import OrbitUI

@Suite struct DiffLayoutTests {
    @Test func removedLinesPairWithTheAddedOnesAfterThem() throws {
        let hunk = try #require(LineDiff.hunks(old: "a\nb\nc\nd", new: "a\nB\nC\nX\nd", context: 1).first)
        let rows = DiffLayout.rows(hunk.lines)
        #expect(rows.map { $0.old?.text } == ["a", "b", "c", nil, "d"])
        #expect(rows.map { $0.new?.text } == ["a", "B", "C", "X", "d"])
    }
}
