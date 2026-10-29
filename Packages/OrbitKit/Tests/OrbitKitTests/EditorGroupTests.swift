import Foundation
@testable import OrbitAPI
import Testing

@MainActor
@Suite(.serialized) struct EditorGroupTests {
    private func makeWorkspace() throws -> (Workspace, URL, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-groups-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt"), c = root.appendingPathComponent("c.txt")
        for url in [a, b, c] { try "x".write(to: url, atomically: true, encoding: .utf8) }
        let workspace = Workspace()
        workspace.openFolder(root)
        return (workspace, a, b, c)
    }

    @Test func splitsMovesAndCollapses() throws {
        let (workspace, a, b, _) = try makeWorkspace()
        workspace.openFile(a)
        workspace.openFile(b)
        workspace.splitEditor()
        #expect(workspace.isSplit)
        #expect(workspace.focusedGroup == 1)
        #expect(workspace.activeTab?.url == b)
        #expect(workspace.groups[0].tabs.count == 2)

        // Opening a file shown on the other side focuses it there.
        workspace.openFile(a)
        #expect(workspace.focusedGroup == 0)

        // Closing the right side's only tab joins the split.
        workspace.close(EditorTab.file(b).id, in: workspace.groups[1].id)
        #expect(!workspace.isSplit)
        #expect(workspace.tabs.map(\.url) == [a, b])

        workspace.moveActiveTabToOtherGroup()
        #expect(workspace.isSplit)
        #expect(workspace.groups.map { $0.tabs.map(\.url) } == [[b], [a]])

        // A deleted file closes everywhere.
        workspace.close(EditorTab.file(a).id)
        #expect(!workspace.isSplit)
        #expect(workspace.tabs.map(\.url) == [b])
    }

    @Test func opensBesideKeepingFocusAndRestores() throws {
        let (workspace, a, b, c) = try makeWorkspace()
        workspace.openFile(a)
        workspace.openBeside(.file(b))
        #expect(workspace.focusedGroup == 0)
        #expect(workspace.groups[1].activeTab?.url == b)
        workspace.focusGroup(1)
        workspace.openFile(c)

        let again = Workspace()
        again.openFolder(workspace.root!)
        #expect(again.groups.map { $0.tabs.map(\.url) } == [[a], [b, c]])
        #expect(again.focusedGroup == 1)
        #expect(again.activeTab?.url == c)

        again.joinGroups()
        #expect(again.tabs.map(\.url) == [b, c, a])
    }

    @Test func dropsReorderMoveAndSplit() throws {
        let (workspace, a, b, c) = try makeWorkspace()
        for url in [a, b, c] { workspace.openFile(url) }
        let group = workspace.groups[0].id

        // Reorder: c to the front, then a to the end.
        workspace.place(.file(c), from: group, into: 0, at: 0)
        #expect(workspace.tabs.map(\.url) == [c, a, b])
        workspace.place(.file(c), from: group, into: 0, at: 3)
        #expect(workspace.tabs.map(\.url) == [a, b, c])

        // A tab dropped on the right edge moves into a new right side.
        workspace.placeInNewGroup(.file(b), from: group, side: .trailing)
        #expect(workspace.groups.map { $0.tabs.map(\.url) } == [[a, c], [b]])
        #expect(workspace.focusedGroup == 1)

        // Its last tab moved back closes the right side.
        workspace.place(.file(b), from: workspace.groups[1].id, into: 0, at: 1)
        #expect(workspace.groups.map { $0.tabs.map(\.url) } == [[a, b, c]])

        // A file from the explorer on the left edge: a new left side; a single tab is copied.
        let single = try makeWorkspace()
        single.0.openFile(single.1)
        single.0.placeInNewGroup(.file(single.1), from: single.0.groups[0].id, side: .leading)
        #expect(single.0.groups.count == 2)
        #expect(single.0.focusedGroup == 0)
    }

    @Test func movedFilesTakeTheirTabsAndEdits() throws {
        let (workspace, a, b, _) = try makeWorkspace()
        let root = workspace.root!
        let src = root.appendingPathComponent("src"), lib = root.appendingPathComponent("src/lib")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        let nested = lib.appendingPathComponent("n.txt")
        try "n".write(to: nested, atomically: true, encoding: .utf8)
        workspace.openFile(a)
        workspace.openFile(nested)
        workspace.documents.document(for: a).text = "unsaved"

        #expect(workspace.moveItems([a], into: src).isEmpty)
        let movedA = src.appendingPathComponent("a.txt").standardizedFileURL
        #expect(workspace.tabs.map(\.url).contains(movedA))
        #expect(workspace.documents.existingDocument(for: movedA)?.text == "unsaved")
        #expect(workspace.documents.existingDocument(for: a) == nil)

        // A folder carries the tabs of what's inside it.
        let docs = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        #expect(workspace.moveItems([lib], into: docs).isEmpty)
        #expect(workspace.activeTab?.url == docs.appendingPathComponent("lib/n.txt").standardizedFileURL)

        // Never into itself, never over an existing item.
        #expect(workspace.moveItems([docs], into: docs.appendingPathComponent("lib")).count == 1)
        try "b2".write(to: src.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        #expect(workspace.moveItems([b], into: src).count == 1)
        #expect(FileManager.default.fileExists(atPath: b.path))
    }

    /// D255: moves made in Orbit go out together for the language servers;
    /// copies and a server's own renames don't.
    @Test func movesAreAnnouncedInOneBatch() async throws {
        let (workspace, a, b, c) = try makeWorkspace()
        let root = workspace.root!
        let folder = root.appendingPathComponent("lib")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let renamed = try workspace.renameItem(a, to: "renamed.txt")
        workspace.moveItems([b], into: folder)
        workspace.moveItems([c], into: folder, copy: true)
        try workspace.moveItem(renamed, to: root.appendingPathComponent("quiet.txt"), announced: false)
        #expect(workspace.lastMoves == nil)
        for _ in 0..<100 where workspace.lastMoves == nil { await Task.yield() }
        let moves = try #require(workspace.lastMoves)
        #expect(moves.items.map(\.from) == [a.standardizedFileURL, b.standardizedFileURL])
        #expect(moves.items.map(\.to) == [renamed, folder.appendingPathComponent("b.txt").standardizedFileURL])
    }

    @Test func renamesCarryTabsAndRefuseTakenNames() throws {
        let (workspace, a, b, _) = try makeWorkspace()
        let root = workspace.root!
        workspace.openFile(a)
        workspace.documents.document(for: a).text = "unsaved"

        let renamed = try workspace.renameItem(a, to: "renamed.txt")
        #expect(renamed == root.appendingPathComponent("renamed.txt").standardizedFileURL)
        #expect(workspace.activeTab?.url == renamed)
        #expect(workspace.documents.existingDocument(for: renamed)?.text == "unsaved")

        // A case-only rename works on a case-insensitive disk too.
        let upper = try workspace.renameItem(renamed, to: "Renamed.txt")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).contains("Renamed.txt"))
        #expect(workspace.activeTab?.url == upper)

        #expect(throws: FileOperationError.exists("b.txt")) { try workspace.renameItem(upper, to: "b.txt") }
        #expect(throws: FileOperationError.invalidName("x/y")) { try workspace.renameItem(b, to: "x/y") }
        #expect(throws: FileOperationError.invalidName("")) { try workspace.renameItem(b, to: "  ") }

        // Undoing a move: back to the exact place, the tab following.
        try workspace.moveItem(upper, to: a)
        #expect(workspace.activeTab?.url == a)
    }

    @Test func createsNestedItemsAndTrashesThem() throws {
        let (workspace, a, _, _) = try makeWorkspace()
        let root = workspace.root!
        let created = try workspace.createItem(named: "src/lib/new.ts", in: root, isFolder: false)
        #expect(created.url == root.appendingPathComponent("src/lib/new.ts").standardizedFileURL)
        #expect(created.topmost == root.appendingPathComponent("src").standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: created.url.path))
        #expect(throws: FileOperationError.exists("new.ts")) { try workspace.createItem(named: "src/lib/new.ts", in: root, isFolder: false) }
        let folder = try workspace.createItem(named: "empty", in: root.appendingPathComponent("src"), isFolder: true)
        #expect(folder.topmost == folder.url)
        #expect(throws: FileOperationError.invalidName("../out")) { try workspace.createItem(named: "../out", in: root, isFolder: true) }

        // Trashing closes the tabs of what's inside; moving it back restores it.
        workspace.openFile(a)
        workspace.openFile(created.url)
        let trashed = workspace.trashItems([created.topmost])
        #expect(trashed.problems.isEmpty)
        #expect(workspace.tabs.map(\.url) == [a])
        #expect(!FileManager.default.fileExists(atPath: created.topmost.path))
        let item = try #require(trashed.items.first)
        #expect(item.from == created.topmost)
        try workspace.moveItem(item.to, to: item.from)
        #expect(FileManager.default.fileExists(atPath: created.url.path))
    }

    @Test func transfersReportWhatMoved() throws {
        let (workspace, a, b, _) = try makeWorkspace()
        let root = workspace.root!
        let src = root.appendingPathComponent("src").standardizedFileURL
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let result = workspace.transferItems([a, b], into: src)
        #expect(result.items == [.init(from: a, to: src.appendingPathComponent("a.txt").standardizedFileURL),
                                 .init(from: b, to: src.appendingPathComponent("b.txt").standardizedFileURL)])
        let copies = workspace.transferItems([result.items[0].to], into: root, copy: true)
        #expect(copies.items.map(\.to) == [a])
        #expect(FileManager.default.fileExists(atPath: result.items[0].to.path))
    }

    @Test func previewTabsAreReusedUntilKept() throws {
        let (workspace, a, b, c) = try makeWorkspace()
        workspace.openFile(a)
        workspace.openFile(b, preview: true)
        #expect(workspace.groups[0].previewTabID == EditorTab.file(b).id)

        // Another single click replaces the preview in place.
        workspace.openFile(c, preview: true)
        #expect(workspace.tabs.map(\.url) == [a, c])
        #expect(workspace.activeTab?.url == c)

        // Clicking an open, kept tab doesn't make it a preview.
        workspace.openFile(a, preview: true)
        #expect(workspace.groups[0].previewTabID == EditorTab.file(c).id)

        // A kept preview stays; the next click opens a new one.
        workspace.pin(EditorTab.file(c).id)
        workspace.openFile(b, preview: true)
        #expect(workspace.tabs.map(\.url) == [a, b, c])

        // A preview with unsaved edits isn't replaced.
        workspace.documents.document(for: b).text = "unsaved"
        workspace.openFile(c, preview: true)
        workspace.openFile(c)
        let d = workspace.root!.appendingPathComponent("d.txt")
        try "d".write(to: d, atomically: true, encoding: .utf8)
        workspace.openFile(d, preview: true)
        #expect(workspace.tabs.map(\.url).contains(b))
        #expect(workspace.groups[0].previewTabID == EditorTab.file(d).id)

        // The preview follows a rename.
        let renamed = try workspace.renameItem(d, to: "e.txt")
        #expect(workspace.groups[0].previewTabID == EditorTab.file(renamed).id)
    }

    @Test func pastedCopiesKeepBoth() throws {
        let (workspace, a, _, _) = try makeWorkspace()
        let root = workspace.root!
        // Pasting into the same folder duplicates, as in Finder.
        let first = workspace.transferItems([a], into: root, copy: true, keepingBoth: true)
        #expect(first.items.map(\.to) == [root.appendingPathComponent("a copy.txt").standardizedFileURL])
        let second = workspace.transferItems([a], into: root, copy: true, keepingBoth: true)
        #expect(second.items.map(\.to) == [root.appendingPathComponent("a copy 2.txt").standardizedFileURL])
        // Without it, a taken name is refused.
        #expect(workspace.transferItems([a], into: root, copy: true).items.isEmpty)
    }

    @Test func keyboardNavigation() throws {
        let (workspace, a, b, c) = try makeWorkspace()
        for url in [a, b, c] { workspace.openFile(url) }

        // Tabs cycle both ways, wrapping around.
        workspace.showAdjacentTab(1)
        #expect(workspace.activeTab?.url == a)
        workspace.showAdjacentTab(-1)
        #expect(workspace.activeTab?.url == c)

        // Browsing the explorer leaves the focus; asking for the editor takes it.
        workspace.openFile(b, preview: true, focus: false)
        #expect(workspace.quietTabID == EditorTab.file(b).id)
        workspace.focusEditor()
        #expect(workspace.quietTabID == nil)
        #expect(workspace.editorFocusRequest?.tabID == EditorTab.file(b).id)

        // Closed tabs reopen newest first.
        workspace.requestClose(EditorTab.file(b).id)
        workspace.requestClose(EditorTab.file(c).id)
        #expect(workspace.closedFiles == [b, c])
        workspace.reopenClosedTab()
        #expect(workspace.activeTab?.url == c)
        #expect(workspace.closedFiles == [b])
    }

    @Test func locationHistoryGoesBackAndForward() throws {
        let (workspace, a, b, c) = try makeWorkspace()
        workspace.openFile(a)
        workspace.caretMoved(to: EditorLocation(url: a, line: 3, column: 2))
        // Small moves aren't jumps; a long one is.
        workspace.caretMoved(to: EditorLocation(url: a, line: 5, column: 0))
        #expect(workspace.backLocations.isEmpty)
        workspace.caretMoved(to: EditorLocation(url: a, line: 40, column: 0))
        #expect(workspace.backLocations == [EditorLocation(url: a, line: 5, column: 0)])

        // Going to another file records where the caret was.
        workspace.openFile(b, line: 7, column: 1)
        #expect(workspace.backLocations.last == EditorLocation(url: a, line: 40, column: 0))
        // A jump within the file records too.
        workspace.openFile(b, line: 9)
        #expect(workspace.backLocations.last == EditorLocation(url: b, line: 7, column: 1))

        workspace.goBack()
        #expect(workspace.activeTab?.url == b)
        #expect(workspace.pendingReveal?.line == 7)
        workspace.goBack()
        #expect(workspace.activeTab?.url == a)
        #expect(workspace.pendingReveal?.line == 40)
        #expect(workspace.forwardLocations.count == 2)
        // Arriving reports the caret where it was sent: no new jump.
        workspace.caretMoved(to: EditorLocation(url: a, line: 40, column: 0))
        workspace.goForward()
        #expect(workspace.activeTab?.url == b)
        #expect(workspace.pendingReveal?.line == 7)

        // A new jump drops what was ahead.
        workspace.openFile(c)
        #expect(workspace.forwardLocations.isEmpty)
        workspace.goBack()
        #expect(workspace.activeTab?.url == b)
    }

    @Test func recentTabsAreMostRecentlyShownFirst() throws {
        let (workspace, a, b, c) = try makeWorkspace()
        for url in [a, b, c] { workspace.openFile(url) }
        workspace.openFile(a)
        #expect(workspace.recentTabs.map(\.url) == [a, c, b])
        workspace.openBeside(.file(b))
        workspace.focusGroup(1)
        #expect(workspace.recentTabs.map(\.url) == [b, a, c])
    }
}
