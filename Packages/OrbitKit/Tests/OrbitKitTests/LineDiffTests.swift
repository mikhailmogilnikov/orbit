import Testing
@testable import OrbitACP
@testable import OrbitAPI

@Suite struct LineDiffTests {
    let old = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj"
    let new = "a\nB\nc\nd\ne\nf\ng\nh\nI\nj\nk"

    @Test func findsSeparateBlocks() {
        let hunks = LineDiff.hunks(old: old, new: new)
        #expect(hunks.count == 3)
        #expect(hunks[0].oldRange == 1..<2)
        #expect(hunks[0].newRange == 1..<2)
        #expect(hunks[2].removed == 0)
        #expect(hunks[2].added == 1)
    }

    @Test func revertingEveryHunkRestoresBaseline() {
        var current = new
        while let hunk = LineDiff.hunks(old: old, new: current).first {
            current = LineDiff.revert(hunk, current: current, baseline: old)
        }
        #expect(current == old)
    }

    @Test func keepingEveryHunkAdoptsCurrent() {
        var baseline = old
        while let hunk = LineDiff.hunks(old: baseline, new: new).first {
            baseline = LineDiff.keep(hunk, current: new, baseline: baseline)
        }
        #expect(baseline == new)
    }

    @Test func mixedKeepAndRevert() {
        let hunks = LineDiff.hunks(old: old, new: new)
        // Revert i→I, keep the rest.
        let current = LineDiff.revert(hunks[1], current: new, baseline: old)
        var baseline = old
        for hunk in LineDiff.hunks(old: baseline, new: current).reversed() {
            baseline = LineDiff.keep(hunk, current: current, baseline: baseline)
        }
        #expect(LineDiff.hunks(old: baseline, new: current).isEmpty)
        #expect(current == "a\nB\nc\nd\ne\nf\ng\nh\ni\nj\nk")
    }

    @Test func newFile() {
        let hunks = LineDiff.hunks(old: "", new: "x\ny")
        #expect(hunks.count == 1)
        #expect(LineDiff.stats(old: "", new: "x\ny").added == 2)
    }

    @Test func jsonRoundTrip() throws {
        let value: JSONValue = ["id": 1, "ok": true, "list": [1.5, "x", nil]]
        let data = try JSONEncoder().encode(value)
        #expect(String(decoding: data, as: UTF8.self).contains("\"id\":1"))
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
    }
}

import Foundation
