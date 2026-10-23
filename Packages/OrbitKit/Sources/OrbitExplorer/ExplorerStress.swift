#if DEBUG
import Foundation
import OrbitAPI

/// The explorer's part of a stress run (D244): files made, renamed and moved
/// in Orbit, and changed and removed outside it while they're open.
@MainActor
enum ExplorerStress {
    static func register(_ context: PluginContext) {
        let stress = context.stress
        let workspace = context.workspace
        let names = ["new.txt", "Ünïcödé file.md", "with spaces.swift", ".hidden", "no-extension", "a.b.c.d"]
        func made(_ run: StressContext) -> [URL] {
            let folder = run.file("made")
            return (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        }

        stress.add(StressStep("explorer.create", weight: 2) { run in
            let folder = run.file("made")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = "\(run.int(0...99))-\(run.pick(names) ?? "new.txt")"
            if let made = try? workspace.createItem(named: name, in: folder, isFolder: run.chance(0.2)), run.chance(0.6) {
                workspace.openFile(made.url)
            }
        })
        stress.add(StressStep("explorer.rename", weight: 1) { run in
            let folder = run.file("made")
            if made(run).isEmpty {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                _ = try? workspace.createItem(named: "to-rename.txt", in: folder, isFolder: false)
            }
            guard let url = run.pick(made(run)) else { return }
            _ = try? workspace.renameItem(url, to: "renamed-\(run.int(0...999))-\(run.pick(names) ?? "x")")
        })
        stress.add(StressStep("explorer.compare", weight: 1, covers: [StressCoverage.provider("explorer.compare")]) { run in
            workspace.open(CompareFiles.tab(run.file("src/short.tsx"), run.file(run.pick(["src/long.swift", "empty.txt", "binary.bin"]) ?? "empty.txt")))
        })
        // Outside Orbit: another editor saving, a build tool deleting, while the files are open.
        stress.add(StressStep("explorer.outsideWrite", weight: 2) { run in
            guard let path = run.pick(["src/short.tsx", "one-line.txt", "crlf.txt", "unicode.txt"]) else { return }
            let url = run.file(path)
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            try? (text + "\n// written outside Orbit \(run.int(0...999))\n").write(to: url, atomically: run.chance(0.5), encoding: .utf8)
        })
        stress.add(StressStep("explorer.outsideDelete", weight: 1, when: { !made($0).isEmpty }) { run in
            guard let url = run.pick(made(run)) else { return }
            try? FileManager.default.removeItem(at: url)
        })
        stress.add(StressStep("explorer.manyFiles", weight: 1) { run in
            // A generator writing hundreds of files at once, then removing them.
            let folder = run.file("generated")
            if FileManager.default.fileExists(atPath: folder.path), run.chance(0.5) {
                try? FileManager.default.removeItem(at: folder)
            } else {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for index in 0..<500 { try? "\(index)\n".write(to: folder.appendingPathComponent("file\(index).txt"), atomically: false, encoding: .utf8) }
            }
        })
        stress.exempt(StressCoverage.command("file.revealInFinder"), because: "brings Finder to the front")
        stress.exempt(StressCoverage.command("file.copyPath"), because: "writes the user's clipboard")
        stress.exempt(StressCoverage.command("file.copyRelativePath"), because: "writes the user's clipboard")
    }
}
#endif
