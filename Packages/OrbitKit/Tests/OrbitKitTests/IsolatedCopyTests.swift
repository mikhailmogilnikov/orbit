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

    /// The whole Create PR path against a local bare remote and a stand-in `gh` (D133).
    @Test func publishesOnlyTheAgentsChangesAsABranch() async throws {
        let project = try makeProject(["a.txt": "one", "wip.txt": "committed"])
        let remote = project.deletingLastPathComponent().appendingPathComponent("remote-\(UUID().uuidString).git")
        let tools = project.deletingLastPathComponent().appendingPathComponent("tools-\(UUID().uuidString)")
        defer {
            for url in [project, remote, tools] { try? FileManager.default.removeItem(at: url) }
        }
        func git(_ arguments: String..., in directory: URL) throws -> String {
            try Shell.run("/usr/bin/git", Array(arguments), in: directory)
        }
        _ = try git("init", "-q", "-b", "main", in: project)
        _ = try git("-c", "user.name=T", "-c", "user.email=t@t", "add", "-A", in: project)
        _ = try git("-c", "user.name=T", "-c", "user.email=t@t", "commit", "-q", "-m", "start", in: project)
        _ = try git("init", "-q", "--bare", remote.path, in: project)
        _ = try git("remote", "add", "origin", remote.path, in: project)
        // The user's uncommitted work, copied along: it must stay out of the pull request.
        try "user's draft".write(to: project.appendingPathComponent("wip.txt"), atomically: true, encoding: .utf8)

        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let gh = tools.appendingPathComponent("gh")
        try """
        #!/bin/sh
        case "$1 $2" in
          "auth status") exit 0 ;;
          "pr create") echo "https://github.com/me/project/pull/7" ;;
          *) exit 1 ;;
        esac
        """.write(to: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = tools.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["GIT_AUTHOR_NAME"] = "T"; environment["GIT_AUTHOR_EMAIL"] = "t@t"
        environment["GIT_COMMITTER_NAME"] = "T"; environment["GIT_COMMITTER_EMAIL"] = "t@t"

        let workspace = Workspace()
        let isolation = IsolatedCopies(workspace: workspace, tracker: ChangeTracker(workspace: workspace))
        let copy = try await isolation.makeCopy(of: project)
        defer { isolation.discard(copy) }
        #expect(await isolation.baseBranch(of: copy) == "main")
        try "ONE".write(to: copy.directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "new".write(to: copy.directory.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let url = try await isolation.publish(copy, branch: "orbit/test", title: "Shout", body: "Why", environment: environment)
        #expect(url.absoluteString == "https://github.com/me/project/pull/7")
        let files = try git("diff", "--name-only", "orbit/test~1", "orbit/test", in: remote)
        #expect(files.split(separator: "\n") == ["a.txt", "b.txt"])
        #expect(try git("log", "-1", "--format=%s", "orbit/test", in: remote) == "Shout\n")
        // The project itself stays on its branch, its draft untouched.
        #expect(try git("rev-parse", "--abbrev-ref", "HEAD", in: project) == "main\n")
        #expect(try String(contentsOf: project.appendingPathComponent("wip.txt"), encoding: .utf8) == "user's draft")

        // A later turn (D144): only its change is pushed, as a commit on the same branch.
        #expect(await isolation.unpushedChanges(in: copy) == 0)
        try "ONE!".write(to: copy.directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        #expect(await isolation.unpushedChanges(in: copy) == 1)
        try await isolation.pushUpdate(copy, message: "Louder", environment: environment)
        #expect(try git("log", "-1", "--format=%s", "orbit/test", in: remote) == "Louder\n")
        #expect(try git("diff", "--name-only", "orbit/test~1", "orbit/test", in: remote) == "a.txt\n")
        #expect(await isolation.unpushedChanges(in: copy) == 0)
    }
}
