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

    @Test func aHugePasteIsOneChange() {
        // Thousands of lines pasted at many carets: one block, not seconds of diffing (D249).
        let oldLines = (0..<80).map { "line \($0)" }
        let newLines = ["line 0"] + (0..<14_000).map { "pasted \($0 % 40) \($0 / 40)" } + ["line 79"]
        let blocks = LineDiff.changeBlocks(oldLines: oldLines, newLines: newLines)
        #expect(blocks.count == 1)
        #expect(blocks[0].old == 1..<79)
        #expect(blocks[0].new == 1..<14_001)
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

@Suite struct LineMergeTests {
    let base = "a\nb\nc\nd\ne\nf\ng"

    @Test func mergesChangesOnDifferentLines() {
        let merged = LineDiff.merge(base: base, mine: "A\nb\nc\nd\ne\nf\ng", theirs: "a\nb\nc\nd\ne\nf\nG\nh")
        #expect(merged == "A\nb\nc\nd\ne\nf\nG\nh")
    }

    @Test func sameOrAdjacentLinesConflict() {
        #expect(LineDiff.merge(base: base, mine: "a\nb\nX\nd\ne\nf\ng", theirs: "a\nb\nY\nd\ne\nf\ng") == nil)
        #expect(LineDiff.merge(base: base, mine: "a\nB\nc\nd\ne\nf\ng", theirs: "a\nb\nC\nd\ne\nf\ng") == nil)
    }

    @Test func identicalChangesMergeOnce() {
        let mine = "a\nb\nX\nd\ne\nf\ng"
        #expect(LineDiff.merge(base: base, mine: mine, theirs: mine + "\nh") == mine + "\nh")
        #expect(LineDiff.merge(base: base, mine: "h\n" + mine, theirs: mine) == "h\n" + mine)
    }

    @Test func oneSideUnchanged() {
        #expect(LineDiff.merge(base: base, mine: base, theirs: "x") == "x")
        #expect(LineDiff.merge(base: base, mine: "x", theirs: base) == "x")
    }
}

@MainActor
@Suite struct DiskSyncTests {
    private func makeFile(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-sync-\(UUID().uuidString).txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func cleanBufferReloads() throws {
        let url = try makeFile("one\ntwo")
        let document = TextDocument(url: url)
        try "one\nthree".write(to: url, atomically: true, encoding: .utf8)
        document.syncWithDisk()
        #expect(document.text == "one\nthree")
        #expect(!document.isDirty)
    }

    @Test func unsavedEditsMergeWithDiskChange() throws {
        let url = try makeFile("a\nb\nc\nd\ne")
        let document = TextDocument(url: url)
        document.text = "A\nb\nc\nd\ne"
        try "a\nb\nc\nd\nE".write(to: url, atomically: true, encoding: .utf8)
        document.syncWithDisk()
        #expect(document.text == "A\nb\nc\nd\nE")
        #expect(document.savedText == "a\nb\nc\nd\nE")
        #expect(document.diskConflict == nil)
    }

    @Test func overlappingChangeConflictsUntilResolved() throws {
        let url = try makeFile("a\nb\nc")
        let document = TextDocument(url: url)
        document.text = "a\nmine\nc"
        try "a\ntheirs\nc".write(to: url, atomically: true, encoding: .utf8)
        document.syncWithDisk()
        #expect(document.text == "a\nmine\nc")
        #expect(document.diskConflict == "a\ntheirs\nc")

        let hunk = try #require(LineDiff.hunks(old: document.text, new: "a\ntheirs\nc").first)
        document.takeFromDisk(hunk)
        #expect(document.text == "a\ntheirs\nc")
        #expect(document.diskConflict == nil)
        #expect(!document.isDirty)
    }

    @Test func deletionIsFlaggedUntilSaved() throws {
        let url = try makeFile("a")
        let document = TextDocument(url: url)
        try FileManager.default.removeItem(at: url)
        document.syncWithDisk()
        #expect(document.isDeletedOnDisk)
        try document.save()
        #expect(!document.isDeletedOnDisk)
        #expect(try String(contentsOf: url, encoding: .utf8) == "a")
    }

    @Test func keepMineOverwritesDisk() throws {
        let url = try makeFile("a\nb\nc")
        let document = TextDocument(url: url)
        document.text = "a\nmine\nc"
        try "a\ntheirs\nc".write(to: url, atomically: true, encoding: .utf8)
        document.syncWithDisk()
        try document.keepMine()
        #expect(try String(contentsOf: url, encoding: .utf8) == "a\nmine\nc")
        #expect(document.diskConflict == nil)
    }
}

@MainActor
@Suite struct WorkspaceTabTests {
    /// A definition reported as /private/tmp/… lands in the tab opened as /tmp/… .
    @Test func onePathSpellingPerTab() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("a.ts")
        try Data().write(to: file)
        let real = file.resolvingSymlinksInPath().path
        let privatePath = real.hasPrefix("/private") ? real : "/private" + real
        let workspace = Workspace()
        workspace.openFile(URL(fileURLWithPath: real))
        workspace.openFile(URL(fileURLWithPath: privatePath))
        workspace.openFile(URL(string: "file://" + privatePath)!)
        #expect(workspace.tabs.count == 1)
    }
}
