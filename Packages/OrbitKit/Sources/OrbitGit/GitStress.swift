#if DEBUG
import Foundation
import OrbitAPI

/// Source Control's part of a stress run (D244): the run's project is a
/// repository with history, a branch, staged, unstaged and untracked changes,
/// and steps stage, commit, discard, switch branches and stash in it.
@MainActor
enum GitStress {
    static func register(_ context: PluginContext, model: GitModel) {
        let stress = context.stress
        stress.prepare { root in
            try git(["init", "-q", "-b", "main"], in: root)
            try git(["add", "-A"], in: root)
            try git(["commit", "-qm", "The project"], in: root)
            try git(["switch", "-qc", "feature"], in: root)
            try "export const feature = true\n".write(to: root.appendingPathComponent("src/feature.ts"), atomically: true, encoding: .utf8)
            try git(["add", "-A"], in: root)
            try git(["commit", "-qm", "A feature"], in: root)
            try git(["switch", "-q", "main"], in: root)
            // Staged, unstaged and untracked, for the gutter and the panel.
            let short = root.appendingPathComponent("src/short.tsx")
            var lines = try String(contentsOf: short, encoding: .utf8).components(separatedBy: "\n")
            lines[2] = "export const changed = 'by the run'"
            lines.remove(at: 9)
            try lines.joined(separator: "\n").write(to: short, atomically: true, encoding: .utf8)
            try "staged\n".write(to: root.appendingPathComponent("staged.txt"), atomically: true, encoding: .utf8)
            try git(["add", "staged.txt"], in: root)
            try "untracked\n".write(to: root.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)
        }

        stress.add(StressStep("git.stage", weight: 2, when: { _ in !model.status.files.isEmpty }) { run in
            let files = run.some(model.status.files, count: run.int(1...3))
            if run.chance(0.6) { model.stage(files) } else { model.unstage(files) }
        })
        stress.add(StressStep("git.commit", weight: 1, when: { _ in model.canCommit || !model.status.unstaged.isEmpty }) { run in
            if model.status.staged.isEmpty { model.stage(model.status.unstaged) }
            await run.settle()
            model.commitMessage = run.pick(["Fix", "A change by the stress run", "Ünïcödé 👩‍👩‍👧\n\nWith a body"]) ?? "Fix"
            run.run("git.commit")
        })
        stress.add(StressStep("git.discard", weight: 1, when: { _ in !model.status.unstaged.isEmpty }) { run in
            model.discard(run.some(model.status.unstaged, count: 1))
        })
        stress.add(StressStep("git.switchBranch", weight: 1, when: { _ in model.branches.count > 1 }) { run in
            if let branch = run.pick(model.branches) { model.switchBranch(branch) }
        })
        stress.add(StressStep("git.stash", weight: 1) { run in
            if let stash = model.stashes.first, run.chance(0.5) {
                model.applyStash(stash, drop: run.chance(0.5))
            } else if !model.status.files.isEmpty {
                model.stash(message: "stress")
            }
        })
        stress.add(StressStep("git.diff", weight: 2, covers: [StressCoverage.provider("git.diff")], when: { _ in !model.status.files.isEmpty }) { run in
            guard let file = run.pick(model.status.files) else { return }
            model.openDiff(file, staged: file.staged != nil && run.chance(0.5))
        })
        stress.add(StressStep("git.history", weight: 1, covers: [StressCoverage.provider("git.revision"), StressCoverage.provider("git.commit")],
                              when: { _ in !model.history.isEmpty }) { run in
            // A file at a commit, a commit's change to it, and the file against a commit.
            guard let commit = run.pick(model.history) else { return }
            model.openRevision(path: "src/short.tsx", at: commit.hash)
            await run.settle()
            model.showCommit(commit.hash, file: run.file("src/short.tsx"))
            await run.settle()
            model.compare(run.file("src/short.tsx"), with: commit.hash)
        })
        stress.add(StressStep("git.outsideChange", weight: 1) { run in
            // Git run from a terminal or another app: branches move under Orbit.
            try? git(["switch", "-q", run.chance(0.5) ? "feature" : "main"], in: run.project)
            context.workspace.fileSystemDidChange()
        })
        // A push, pull or fetch with no remote fails: the error path, not the network.
        stress.exempt(StressCoverage.command("git.generateMessage"), because: "asks an agent to write the message; a fake agent comes with phase 2")
    }

    /// Git Lens's part: history of a file and of lines, blame on and off.
    static func registerLens(_ context: PluginContext) {
        let stress = context.stress
        stress.add(StressStep("gitlens.history", weight: 1) { run in
            await run.open(run.pick(["src/short.tsx", "src/long.swift"]) ?? "src/short.tsx")
            run.run(run.pick(["git.fileHistory", "git.lineHistory", "editor.toggleBlame"]) ?? "git.fileHistory")
        })
        stress.exempt(StressCoverage.command("git.openRemote"), because: "opens the browser")
        stress.exempt(StressCoverage.command("git.copyRemoteLink"), because: "writes the user's clipboard")
    }

    nonisolated static func git(_ arguments: [String], in folder: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Orbit Stress", "-c", "user.email=stress@orbit.invalid", "-c", "commit.gpgsign=false"] + arguments
        process.currentDirectoryURL = folder
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }
}
#endif
