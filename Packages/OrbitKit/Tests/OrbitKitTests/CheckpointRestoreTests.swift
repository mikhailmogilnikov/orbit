import Foundation
@testable import OrbitAPI
@testable import OrbitReview
import Testing

@MainActor
@Suite(.serialized) struct CheckpointRestoreTests {
    @Test func restoresFilesAsReviewableChanges() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("orbit-restore-\(UUID().uuidString)", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: Checkpoints(root: root).gitDir)
            try? FileManager.default.removeItem(at: root)
        }
        let a = root.appendingPathComponent("a.txt"), gone = root.appendingPathComponent("gone.txt")
        let new = root.appendingPathComponent("new.txt"), image = root.appendingPathComponent("image.bin")
        try "one\ntwo".write(to: a, atomically: true, encoding: .utf8)
        try "bye".write(to: gone, atomically: true, encoding: .utf8)
        try Data([0, 1, 2]).write(to: image)

        let workspace = Workspace()
        workspace.openFolder(root)
        let tracker = ChangeTracker(workspace: workspace)
        let checkpoint = try #require(await tracker.beginAgentTurn())
        try "ONE\ntwo".write(to: a, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: gone)
        try "hi".write(to: new, atomically: true, encoding: .utf8)
        try Data([9, 9]).write(to: image)
        await tracker.endAgentTurn()
        tracker.acceptAll()

        let restored = try await tracker.restore(checkpoint)
        #expect(Set(restored.map(\.lastPathComponent)) == ["a.txt", "gone.txt", "new.txt", "image.bin"])
        #expect(try String(contentsOf: a, encoding: .utf8) == "one\ntwo")
        #expect(try String(contentsOf: gone, encoding: .utf8) == "bye")
        #expect(!FileManager.default.fileExists(atPath: new.path))
        #expect(try Data(contentsOf: image) == Data([0, 1, 2]))

        // The restore is reviewable: undoing it brings the agent's edit back.
        #expect(Set(tracker.changedFiles.map(\.lastPathComponent)) == ["a.txt", "gone.txt", "new.txt"])
        tracker.reject(a)
        #expect(try String(contentsOf: a, encoding: .utf8) == "ONE\ntwo")
        #expect(try await tracker.restore(checkpoint).map(\.lastPathComponent).contains("a.txt"))
    }
}
