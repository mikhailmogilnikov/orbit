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

@Suite struct GitHistoryTests {
    private func makeRepository() throws -> GitRepository {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-git-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var env = ProcessInfo.processInfo.environment
        env["GIT_AUTHOR_NAME"] = "Ann Dev"; env["GIT_AUTHOR_EMAIL"] = "a@d.ev"
        env["GIT_COMMITTER_NAME"] = "Ann Dev"; env["GIT_COMMITTER_EMAIL"] = "a@d.ev"
        let repo = GitRepository(root: root, environment: env)
        try repo.initialize()
        return repo
    }

    private func write(_ text: String, _ path: String, in repo: GitRepository) throws {
        try text.write(to: repo.root.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    /// GitLens's file and line history, and a file at a revision (D189).
    @Test func fileAndLineHistory() throws {
        let repo = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try write("one\ntwo\nthree\n", "a.txt", in: repo)
        try repo.stage(["."])
        try repo.commit(message: "Add a")
        try write("other\n", "b.txt", in: repo)
        try repo.stage(["."])
        try repo.commit(message: "Add b")
        try write("one\nTWO\nthree\n", "a.txt", in: repo)
        try repo.stage(["."])
        try repo.commit(message: "Change line 2")
        try write("ONE\nTWO\nthree\n", "a.txt", in: repo)
        try repo.stage(["."])
        try repo.commit(message: "Change line 1")

        #expect(repo.fileLog(path: "a.txt").map(\.subject) == ["Change line 1", "Change line 2", "Add a"])
        #expect(repo.fileLog(path: "a.txt", lines: 2...2).map(\.subject) == ["Change line 2", "Add a"])
        #expect(repo.fileLog(path: "a.txt", lines: 3...3).map(\.subject) == ["Add a"])
        let first = try #require(repo.fileLog(path: "a.txt").last)
        #expect(repo.contents(of: "a.txt", at: first.hash) == .text("one\ntwo\nthree\n"))
    }

    @Test func stashPopAndDrop() throws {
        let repo = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try write("one\n", "a.txt", in: repo)
        try repo.stage(["."])
        try repo.commit(message: "First")

        try write("two\n", "a.txt", in: repo)
        try write("new\n", "new.txt", in: repo)
        try repo.stash(message: "my wip")
        #expect(try repo.status().files.isEmpty)
        let stashes = repo.stashes()
        #expect(stashes.map(\.message) == ["my wip"])
        #expect(stashes.first?.ref == "stash@{0}")
        // Its files, as a commit's against HEAD (D154).
        let stashed = repo.files(in: stashes[0].hash)
        #expect(stashed.map(\.path).contains("a.txt"))
        #expect(repo.commitSides(stashes[0].hash, file: stashed.first { $0.path == "a.txt" }!).new == .text("two\n"))

        try repo.applyStash(stashes[0], drop: true)
        #expect(repo.stashes().isEmpty)
        #expect(Set(try repo.status().files.map(\.path)) == ["a.txt", "new.txt"])

        try repo.stash(message: "")
        try repo.dropStash(repo.stashes()[0])
        #expect(repo.stashes().isEmpty)
        #expect(try repo.status().files.isEmpty)
    }

    @Test func historyFilesAndBlame() throws {
        let repo = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try write("one\ntwo\n", "a.txt", in: repo)
        try repo.stage(["."])
        try repo.commit(message: "First")
        try write("one\nTWO\nthree\n", "a.txt", in: repo)
        try write("x\n", "b.txt", in: repo)
        try repo.stage(["."])
        try repo.commit(message: "Second | with bars")

        let log = repo.log()
        #expect(log.map(\.subject) == ["Second | with bars", "First"])
        #expect(log[0].author == "Ann Dev" && log[0].shortHash.count >= 7)

        let files = repo.files(in: log[0].hash)
        #expect(files.map(\.path).sorted() == ["a.txt", "b.txt"])
        #expect(files.first { $0.path == "b.txt" }?.status == .added)
        let sides = repo.commitSides(log[0].hash, file: try #require(files.first { $0.path == "a.txt" }))
        #expect(sides.old == .text("one\ntwo\n") && sides.new == .text("one\nTWO\nthree\n"))
        // The first commit has no parent: its files come from nothing.
        let first = repo.files(in: log[1].hash)
        #expect(repo.commitSides(log[1].hash, file: first[0]).old == .text(""))

        // Blame the editor's text: an unsaved extra line isn't committed.
        let blame = try #require(repo.blame(path: "a.txt", contents: "one\nTWO\nthree\nunsaved\n"))
        #expect(blame.count == 4)
        #expect(blame[0].summary == "First" && blame[1].summary == "Second | with bars")
        #expect(blame[0].author == "Ann Dev")
        #expect(!blame[3].isCommitted && blame[2].isCommitted)
    }

    @Test func parsesNameStatusWithRenames() {
        let data = Data("M\0a.txt\0R087\0old name.txt\0new name.txt\0D\0gone.txt\0".utf8)
        let files = GitParse.nameStatus(data)
        #expect(files.map(\.path) == ["a.txt", "new name.txt", "gone.txt"])
        #expect(files[1].status == .renamed && files[1].oldPath == "old name.txt")
    }

    /// Branches, a merge, refs, search and the graph's lanes (D136).
    @Test func historyAcrossBranchesWithGraphAndSearch() throws {
        let repo = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try write("a\n", "a.txt", in: repo)
        try repo.stage(["."])
        try repo.commit(message: "Base")
        let main = try #require(repo.branches().first)
        try repo.switchBranch("feature", create: true)
        try write("f\n", "f.txt", in: repo)
        try repo.stage(["."])
        try repo.commit(message: "Feature work")
        try repo.switchBranch(main)
        try write("m\n", "m.txt", in: repo)
        try repo.stage(["."])
        try repo.commit(message: "Main work")
        _ = try repo.run(["merge", "--no-ff", "-m", "Merge feature", "feature"])

        let log = repo.log()
        #expect(log.map(\.subject) == ["Merge feature", "Feature work", "Main work", "Base"]
                || log.map(\.subject) == ["Merge feature", "Main work", "Feature work", "Base"])
        #expect(log[0].parents.count == 2)
        #expect(log[0].refs.contains { $0.hasPrefix("HEAD -> ") })
        #expect(repo.log(revisions: ["feature"]).map(\.subject) == ["Feature work", "Base"])

        // The merge opens a second lane that closes again at the base.
        let rows = GitGraph.rows(log)
        #expect(rows[0].column == 0)
        #expect(rows[0].bottom.count == 2)
        #expect(rows.map(\.laneCount).max() == 2)
        #expect(rows.last?.continuing == [])

        #expect(repo.searchLog("feature").map(\.subject).contains("Feature work"))
        #expect(repo.searchLog("ann dev").count == 4)
        let hash = String(log[3].hash.prefix(7))
        #expect(repo.searchLog(hash).map(\.subject) == ["Base"])
        #expect(repo.searchLog("nothing like this").isEmpty)
    }

    @Test func graphOfALinearHistoryIsOneLane() {
        let commits = (0..<3).map { index in
            GitCommit(hash: "c\(index)", shortHash: "c\(index)", author: "", date: .now, subject: "",
                      parents: index < 2 ? ["c\(index + 1)"] : [])
        }
        let rows = GitGraph.rows(commits)
        #expect(rows.map(\.column) == [0, 0, 0])
        #expect(rows.map(\.laneCount) == [1, 1, 1])
        #expect(rows[1].top.map { [$0.0, $0.1] } == [[0, 0]])
        #expect(rows[2].bottom.isEmpty)
    }
}
