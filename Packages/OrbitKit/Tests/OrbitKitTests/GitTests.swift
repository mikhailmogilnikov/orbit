import Foundation
@testable import OrbitGit
import OrbitAPI
import Testing

@Suite struct GitTests {
    @Test func parsesPorcelainV2() {
        let records = [
            "# branch.oid 1234",
            "# branch.head main",
            "# branch.upstream origin/main",
            "# branch.ab +2 -1",
            "1 M. N... 100644 100644 100644 aaa bbb Sources/staged file.swift",
            "1 .M N... 100644 100644 100644 aaa bbb README.md",
            "1 MM N... 100644 100644 100644 aaa bbb both.txt",
            "2 R. N... 100644 100644 100644 aaa bbb R100 new.txt", "old.txt",
            "u UU N... 100644 100644 100644 100644 a b c conflict.txt",
            "? untracked.txt",
            "",
        ]
        let status = GitStatus.parse(Data(records.joined(separator: "\0").utf8))
        #expect(status.branch == "main")
        #expect(status.upstream == "origin/main")
        #expect(status.ahead == 2 && status.behind == 1)
        #expect(status.staged.map(\.path) == ["both.txt", "new.txt", "Sources/staged file.swift"])
        #expect(status.unstaged.map(\.path) == ["both.txt", "README.md", "untracked.txt"])
        #expect(status.conflicted.map(\.path) == ["conflict.txt"])
        #expect(status.files.first { $0.path == "new.txt" }?.originalPath == "old.txt")
        #expect(status.files.first { $0.path == "untracked.txt" }?.unstaged == .untracked)
    }

    @Test func stageUnstageCommitInRealRepository() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var env = ProcessInfo.processInfo.environment
        env["GIT_AUTHOR_NAME"] = "Test"; env["GIT_AUTHOR_EMAIL"] = "t@e.st"
        env["GIT_COMMITTER_NAME"] = "Test"; env["GIT_COMMITTER_EMAIL"] = "t@e.st"
        let repo = GitRepository(root: root, environment: env)

        #expect(!repo.isRepository())
        try repo.initialize()
        #expect(repo.isRepository())
        try "one\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        var status = try repo.status()
        #expect(!status.hasCommits)
        #expect(status.unstaged.map(\.path) == ["a.txt"])

        try repo.stage(["a.txt"])
        #expect(try repo.status().staged.map(\.path) == ["a.txt"])
        try repo.unstage(["a.txt"], hasCommits: false)
        #expect(try repo.status().staged.isEmpty)

        try repo.stage(["."])
        try repo.commit(message: "First\n\nBody line")
        status = try repo.status()
        #expect(status.hasCommits && status.files.isEmpty)
        let log = String(decoding: try repo.run(["log", "-1", "--format=%B"]), as: UTF8.self)
        #expect(log.trimmingCharacters(in: .whitespacesAndNewlines) == "First\n\nBody line")

        try "two\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try repo.discard(["a.txt"])
        #expect(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8) == "one\n")

        try repo.switchBranch("feature", create: true)
        #expect(try repo.status().branch == "feature")
        #expect(Set(try repo.branches()) == ["feature", try repo.branches().first { $0 != "feature" }!])

        #expect(throws: GitError.self) { try repo.commit(message: "nothing to commit") }
    }

    @MainActor @Test func cleansAgentReplies() {
        #expect(GitModel.cleanMessage("```\nAdd search panel\n\nBody\n```") == "Add search panel\n\nBody")
        #expect(GitModel.cleanMessage("  \"Fix crash on tab switch\"\n") == "Fix crash on tab switch")
        #expect(GitModel.cleanMessage("Plain message") == "Plain message")
    }

    @Test func commitContextIncludesNewFilesAndHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var env = ProcessInfo.processInfo.environment
        env["GIT_AUTHOR_NAME"] = "Test"; env["GIT_AUTHOR_EMAIL"] = "t@e.st"
        env["GIT_COMMITTER_NAME"] = "Test"; env["GIT_COMMITTER_EMAIL"] = "t@e.st"
        let repo = GitRepository(root: root, environment: env)
        try repo.initialize()
        try "a\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try repo.stage(["."])
        try repo.commit(message: "Initial commit")
        try "a\nchanged\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "brand new\n".write(to: root.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)

        let all = repo.commitContext(stagedOnly: false, hasCommits: true, untracked: ["new.txt"])
        #expect(all.diff.contains("+changed"))
        #expect(all.diff.contains("New file: new.txt\nbrand new"))
        #expect(all.recentSubjects == ["Initial commit"])

        try repo.stage(["a.txt"])
        let staged = repo.commitContext(stagedOnly: true, hasCommits: true, untracked: ["new.txt"])
        #expect(staged.diff.contains("+changed") && !staged.diff.contains("new.txt"))
    }

    @Test func changeKindsForDecorations() {
        #expect(GitFileStatus(path: "a", unstaged: .untracked).changeKind == .untracked)
        #expect(GitFileStatus(path: "a", staged: .added, unstaged: .modified).changeKind == .added)
        #expect(GitFileStatus(path: "a", staged: .modified, unstaged: .modified).changeKind == .modified)
        #expect(GitFileStatus(path: "a", unstaged: .deleted).changeKind == .deleted)
        #expect(GitFileStatus(path: "a", staged: .conflicted, unstaged: .conflicted).changeKind == .conflicted)
        #expect(FileChangeKind.conflicted > .modified && FileChangeKind.modified > .untracked)
    }

    @Test func diffSidesForStagedAndWorkingChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var env = ProcessInfo.processInfo.environment
        env["GIT_AUTHOR_NAME"] = "Test"; env["GIT_AUTHOR_EMAIL"] = "t@e.st"
        env["GIT_COMMITTER_NAME"] = "Test"; env["GIT_COMMITTER_EMAIL"] = "t@e.st"
        let repo = GitRepository(root: root, environment: env)
        try repo.initialize()
        let file = root.appendingPathComponent("a.txt")
        try "v1\n".write(to: file, atomically: true, encoding: .utf8)
        try repo.stage(["."])
        try repo.commit(message: "v1")
        try "v2\n".write(to: file, atomically: true, encoding: .utf8)
        try repo.stage(["a.txt"])
        try "v3\n".write(to: file, atomically: true, encoding: .utf8)
        try "new\n".write(to: root.appendingPathComponent("n.txt"), atomically: true, encoding: .utf8)

        let status = try repo.status()
        let a = try #require(status.files.first { $0.path == "a.txt" })
        #expect(repo.diffSides(of: a, staged: true) == (.text("v1\n"), .text("v2\n")))
        #expect(repo.diffSides(of: a, staged: false) == (.text("v2\n"), .text("v3\n")))
        let n = try #require(status.files.first { $0.path == "n.txt" })
        #expect(repo.diffSides(of: n, staged: false) == (.text(""), .text("new\n")))
    }
}
