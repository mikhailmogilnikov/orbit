import AppKit
@testable import OrbitAPI
@testable import OrbitExplorer
import Testing

/// Copy, Cut and Paste in the Explorer, on a pasteboard of the test's own.
@MainActor
@Suite struct ExplorerPasteTests {
    let root: URL
    let model: FileTreeModel

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-paste-\(UUID().uuidString)", isDirectory: true).standardizedFileURL
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("folder/inner"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("target"), withIntermediateDirectories: true)
        try "a".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: root.appendingPathComponent("folder/inner/b.txt"), atomically: true, encoding: .utf8)
        let workspace = Workspace()
        workspace.openFolder(root)
        model = FileTreeModel(workspace: workspace, services: ServiceRegistry())
        model.pasteboard = NSPasteboard(name: .init("orbit-test-\(UUID().uuidString)"))
        model.sync()
    }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) }

    @Test func copiesAFileAndAFolderIntoAFolder() {
        defer { try? FileManager.default.removeItem(at: root) }
        model.copyItems([root.appendingPathComponent("a.txt"), root.appendingPathComponent("folder")], cut: false)
        #expect(model.canPaste)
        model.paste(into: root.appendingPathComponent("target"))
        #expect(exists("target/a.txt"))
        #expect(exists("target/folder/inner/b.txt"))
        #expect(exists("a.txt") && exists("folder/inner/b.txt"))
    }

    @Test func pastesIntoAFolderNeverExpanded() {
        defer { try? FileManager.default.removeItem(at: root) }
        model.copyItems([root.appendingPathComponent("a.txt")], cut: false)
        model.paste(into: root.appendingPathComponent("folder/inner"))
        #expect(exists("folder/inner/a.txt"))
    }

    /// Copied and pasted while still selected: beside itself, as in Finder.
    @Test func aFolderPastedIntoItselfGoesBesideIt() {
        defer { try? FileManager.default.removeItem(at: root) }
        model.copyItems([root.appendingPathComponent("folder")], cut: false)
        model.paste(into: root.appendingPathComponent("folder"))
        #expect(exists("folder copy/inner/b.txt"))
        model.paste(into: root.appendingPathComponent("folder/inner"))
        #expect(exists("folder copy 2/inner/b.txt"))
    }

    /// A folder's URL off the pasteboard ends in a slash: it went into itself.
    @Test func aFolderWithASlashIsNotCopiedIntoItself() {
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = URL(fileURLWithPath: root.appendingPathComponent("folder").path, isDirectory: true)
        #expect(folder.absoluteString.hasSuffix("/"))
        model.pasteboard.clearContents()
        model.pasteboard.writeObjects([folder as NSURL])
        model.paste(into: root.appendingPathComponent("folder"))
        #expect(exists("folder copy/inner/b.txt"))
        #expect(!exists("folder/folder"))
        let transfer = model.workspace.transferItems([folder], into: root.appendingPathComponent("folder"), copy: true)
        #expect(transfer.items.isEmpty && !transfer.problems.isEmpty)
        #expect(!exists("folder/folder"))
    }

    @Test func cutMovesAndPastingInPlaceDuplicates() {
        defer { try? FileManager.default.removeItem(at: root) }
        model.copyItems([root.appendingPathComponent("a.txt")], cut: true)
        model.paste(into: root.appendingPathComponent("target"))
        #expect(exists("target/a.txt") && !exists("a.txt"))
        model.copyItems([root.appendingPathComponent("target/a.txt")], cut: false)
        model.paste(into: root.appendingPathComponent("target/a.txt"))
        #expect(exists("target/a copy.txt"))
    }
}
