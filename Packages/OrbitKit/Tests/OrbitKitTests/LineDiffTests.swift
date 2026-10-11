import SwiftUI
import Testing
@testable import OrbitUI
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

@Suite struct LineMarkersTests {
    @Test func marksAddedModifiedAndDeletedLines() {
        let baseline = "a\nb\nc\nd\ne"
        let current = "a\nB\nc\nnew\nd"
        let markers = LineMarkers(baseline: baseline, current: current)
        #expect(markers.modified == IndexSet(integer: 1))
        #expect(markers.added == IndexSet(integer: 3))
        // "e" was removed after the last line.
        #expect(markers.deletedAbove == IndexSet(integer: 5))
    }

    @Test func deletionInTheMiddleMarksTheLineBelow() {
        let markers = LineMarkers(baseline: "a\nb\nc", current: "a\nc")
        #expect(markers.deletedAbove == IndexSet(integer: 1))
        #expect(markers.added.isEmpty && markers.modified.isEmpty)
        #expect(LineMarkers(baseline: "same", current: "same").isEmpty)
    }
}

@Suite struct DiffHighlightingTests {
    @Test func colorsOnlyTheRequestedLinesAndClipsSpansToThem() throws {
        let text = "let a = 1\n/* multi\nline */ b\n"
        // "let" and a comment spanning lines 2–3.
        let spans = [
            SyntaxSpan(range: NSRange(location: 0, length: 3), color: .red),
            SyntaxSpan(range: NSRange(location: 10, length: 16), color: .green),
        ]
        let lines = DiffHighlighting.lines(of: text, spans: spans, numbers: [1, 3])
        #expect(Set(lines.keys) == [1, 3])
        let first = try #require(lines[1])
        #expect(String(first.characters) == "let a = 1")
        #expect(colors(first) == [.red, nil])
        let third = try #require(lines[3])
        #expect(String(third.characters) == "line */ b")
        // The comment ends at "*/": the rest of the line keeps the default color.
        #expect(colors(third) == [.green, nil])
    }

    private func colors(_ text: AttributedString) -> [Color?] {
        text.runs.map { $0[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] }
    }
}
