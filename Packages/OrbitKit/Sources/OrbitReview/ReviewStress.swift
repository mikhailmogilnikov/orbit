#if DEBUG
import Foundation
import OrbitAPI

/// Inline review's part of a stress run (D244): agent turns as agents make
/// them, through the files (the shell, D-gotcha), several files at once, new
/// and deleted ones, reviewed while the user keeps editing.
@MainActor
enum ReviewStress {
    static func register(_ context: PluginContext, tracker: ChangeTracker) {
        let stress = context.stress
        let workspace = context.workspace
        let files = ["src/short.tsx", "src/long.swift", "tabs.go", "crlf.txt", "unicode.txt", "empty.txt", "one-line.txt"]

        stress.add(StressStep("review.agentTurn", weight: 4) { run in
            // As an agent over ACP or its shell: a turn, the files written on disk, the turn's end.
            _ = await tracker.beginAgentTurn()
            for path in run.some(files, count: run.int(1...3)) {
                let url = run.file(path)
                guard var lines = (try? String(contentsOf: url, encoding: .utf8))?.components(separatedBy: "\n") else { continue }
                for _ in 0..<run.int(1...6) {
                    let index = run.int(0...max(0, lines.count - 1))
                    switch run.int(0...3) {
                    case 0 where !lines.isEmpty: lines[index] = "// changed by a pretend agent \(run.int(0...999))"
                    case 1 where lines.count > 1: lines.remove(at: index)
                    case 2: lines.insert(contentsOf: ["    // inserted A", "    // inserted B"], at: index)
                    default: lines.append("// appended")
                    }
                }
                try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            }
            if run.chance(0.3) {
                try? "export const created = true\n".write(to: run.file("src/agent-\(run.int(0...9)).ts"), atomically: true, encoding: .utf8)
            }
            await tracker.refreshAgentChanges()
            await tracker.endAgentTurn()
            workspace.fileSystemDidChange()
        })
        stress.add(StressStep("review.decide", weight: 2, when: { _ in !tracker.changedFiles.isEmpty }) { run in
            if run.chance(0.5) { run.run("review.acceptAll") } else { run.run("review.rejectAll") }
        })
        stress.add(StressCheck("review.changedFilesAreReal") { _ in
            let root = workspace.root?.standardizedFileURL.path ?? "/"
            let outside = tracker.changedFiles.first { !$0.standardizedFileURL.path.hasPrefix(root) }
            return outside.map { "a change outside the project: \($0.path)" }
        })
    }
}
#endif
