import Foundation
@testable import OrbitACP
@testable import OrbitAPI
@testable import OrbitEditor
@testable import OrbitLanguages
import Testing

@Suite struct FoldingTests {
    private func ranges(_ text: String) -> [ClosedRange<Int>] {
        FoldingController.indentationRanges(in: text as NSString).map { $0.startLine...$0.endLine }
    }

    @Test func bracesKeepTheirClosingLine() {
        let text = """
        func a() {
            if x {
                y()

            }
        }
        let b = 1
        """
        #expect(ranges(text) == [0...4, 1...2])
    }

    @Test func indentedBlocksEndAtTheLastLine() {
        let text = "def f():\n    a\n\n    b\n\nc\n"
        #expect(ranges(text) == [0...3])
        #expect(ranges("class A:\n\tdef f():\n\t\tpass") == [0...2, 1...2])
    }

    @Test func flatTextHasNoRegions() {
        #expect(ranges("a\nb\n\nc") == [])
        #expect(ranges("") == [])
    }

    @Test func theRootRegionIsDropped() {
        let text = "\n{\n  \"a\": {\n    \"b\": 1\n  }\n}\n" as NSString
        var regions = [1: 4, 2: 3]
        FoldingController.dropRoot(from: &regions, in: text, starts: SourcePosition.lineStarts(of: text))
        #expect(regions == [2: 3])
    }

    @Test func foldsFollowAnAgentEdit() {
        let old = LineDiff.lines("a\nb {\n  c\n}\nd\ne {\n  f\n}")
        // Two lines added at the top, one inside the second block.
        let new = LineDiff.lines("x\ny\na\nb {\n  c\n}\nd\ne {\n  f\n  g\n}")
        let blocks = LineDiff.changeBlocks(oldLines: old, newLines: new)
        #expect(FoldingController.shift(header: 1, end: 2, through: blocks) == 2)
        #expect(FoldingController.shift(header: 5, end: 6, through: blocks) == nil)
    }

    @Test func serverRangesAreRead() {
        let value: JSONValue = ["startLine": 2, "startCharacter": 10, "endLine": 7, "kind": "imports"]
        #expect(LanguageServer.foldingRange(value) == FoldingRange(startLine: 2, endLine: 7, kind: .imports))
        #expect(LanguageServer.foldingRange(["startLine": 3, "endLine": 3]) == nil)
    }
}
