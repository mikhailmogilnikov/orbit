import Foundation
@testable import OrbitReview
import Testing

@Suite struct CheckpointStorageTests {
    /// The shadow repositories of folders that are gone go (D250); one of a
    /// folder that's there, of one on a disk that isn't mounted, or without a
    /// folder it names, stays.
    @Test func removesTheRepositoriesOfGoneFolders() throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("orbit-storage-\(UUID().uuidString)", isDirectory: true)
        let storage = scratch.appendingPathComponent("checkpoints", isDirectory: true)
        let project = scratch.appendingPathComponent("project", isDirectory: true)
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        func repository(_ name: String, worktree: String?) throws {
            let gitDir = storage.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: gitDir, withIntermediateDirectories: true)
            try git(["--git-dir=\(gitDir.path)", "init", "--quiet"])
            if let worktree { try git(["config", "--file", gitDir.appendingPathComponent("config").path, "core.worktree", worktree]) }
        }
        try repository("there", worktree: project.path)
        try repository("gone", worktree: scratch.appendingPathComponent("deleted project").path)
        try repository("unmounted", worktree: "/Volumes/Orbit Test Disk \(UUID().uuidString)/project")
        try repository("none", worktree: nil)

        #expect(CheckpointStorage.removeGone(in: storage) == 1)
        let left = try fm.contentsOfDirectory(atPath: storage.path).sorted()
        #expect(left == ["none", "there", "unmounted"])
    }

    private func git(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
