import Foundation
@testable import OrbitAPI
@testable import OrbitReview
import Testing

@MainActor
@Suite(.serialized) struct IsolatedCopyTests {
    private func makeProject(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("orbit-isolated-\(UUID().uuidString)", isDirectory: true)
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return root.standardizedFileURL
    }

    @Test func appliesCopyChangesAsAgentChanges() async throws {
        let project = try makeProject(["a.txt": "one\ntwo\nthree\nfour\nfive", "gone.txt": "bye"])
        let workspace = Workspace()
        let tracker = ChangeTracker(workspace: workspace)
        let isolation = IsolatedCopies(workspace: workspace, tracker: tracker)
        let copy = try await isolation.makeCopy(of: project)
        defer { isolation.discard(copy) }
        #expect(try String(contentsOf: copy.directory.appendingPathComponent("a.txt"), encoding: .utf8) == "one\ntwo\nthree\nfour\nfive")
        #expect(await isolation.unappliedChanges(in: copy).isEmpty)

        // The agent edits its copy; meanwhile the user edits another line of the project.
        try "ONE\ntwo\nthree\nfour\nfive".write(to: copy.directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "new".write(to: copy.directory.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: copy.directory.appendingPathComponent("gone.txt"))
        try "one\ntwo\nthree\nfour\nFIVE".write(to: project.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        #expect(await isolation.unappliedChanges(in: copy).count == 3)

        let result = await isolation.apply(copy)
        #expect(result.applied.count == 3)
        #expect(result.conflicts.isEmpty)
        #expect(try String(contentsOf: project.appendingPathComponent("a.txt"), encoding: .utf8) == "ONE\ntwo\nthree\nfour\nFIVE")
        #expect(try String(contentsOf: project.appendingPathComponent("new.txt"), encoding: .utf8) == "new")
        #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent("gone.txt").path))
        #expect(tracker.hasChanges(project.appendingPathComponent("a.txt")))
        #expect(await isolation.unappliedChanges(in: copy).isEmpty)
    }

    @Test func sameLineEditsConflict() async throws {
        let project = try makeProject(["a.txt": "one\ntwo"])
        let workspace = Workspace()
        let isolation = IsolatedCopies(workspace: workspace, tracker: ChangeTracker(workspace: workspace))
        let copy = try await isolation.makeCopy(of: project)
        defer { isolation.discard(copy) }
        try "agent\ntwo".write(to: copy.directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "user\ntwo".write(to: project.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let result = await isolation.apply(copy)
        #expect(result.applied.isEmpty)
        #expect(result.conflicts.map(\.lastPathComponent) == ["a.txt"])
        #expect(try String(contentsOf: project.appendingPathComponent("a.txt"), encoding: .utf8) == "user\ntwo")
    }
}
