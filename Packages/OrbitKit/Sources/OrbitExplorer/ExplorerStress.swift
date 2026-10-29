#if DEBUG
import AppKit
import OrbitAPI

/// The explorer's part of a stress run (D244): files made, renamed and moved
/// in Orbit, and changed and removed outside it while they're open.
@MainActor
enum ExplorerStress {
    static func register(_ context: PluginContext, model: FileTreeModel) {
        let stress = context.stress
        let workspace = context.workspace
        // D252: Edit → Copy and Paste with the tree focused, as ⌘C ⌘V: a file
        // into a folder, then that folder into itself (beside it, as in Finder).
        // On a pasteboard of its own: the copies run side by side, and the user's clipboard stays.
        stress.add(StressStep("explorer.copyPaste", weight: 1) { [weak model] run in
            guard let model else { return }
            let own = NSPasteboard(name: .init("orbit-stress-\(UUID().uuidString)"))
            model.pasteboard = own
            defer {
                model.pasteboard = .general
                own.releaseGlobally()
            }
            let folder = run.file("pasted-\(run.int(0...9999))")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            context.ui.revealSidebarPanel("explorer")
            await run.open("one-line.txt")
            model.selectedFolder = nil
            model.focusList()
            await run.settle()
            // The menu's way, from the focused view up; in the background there's no key window to send it to.
            guard let responder = NSApp.windows.first(where: { $0.firstResponder is NSOutlineView })?.firstResponder else {
                return run.note("the tree didn't take the keys")
            }
            // The selection right before each: the list puts it back on the open file as its rows change.
            @MainActor func send(_ action: Selector, selecting selected: URL?) async {
                model.selectedFolder = selected
                _ = responder.tryToPerform(action, with: nil)
                await run.settle()
            }
            await send(#selector(NSText.copy(_:)), selecting: nil)
            await send(#selector(NSText.paste(_:)), selecting: folder)
            if !FileManager.default.fileExists(atPath: folder.appendingPathComponent("one-line.txt").path) { run.note("the file didn't land in the folder") }
            await send(#selector(NSText.copy(_:)), selecting: folder)
            await send(#selector(NSText.paste(_:)), selecting: folder)
            let beside = folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + " copy")
            if !FileManager.default.fileExists(atPath: beside.appendingPathComponent("one-line.txt").path) { run.note("the folder didn't land beside itself") }
            // It went into itself (D252).
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(folder.lastPathComponent).path) { run.note("the folder went into itself") }
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: beside)
        })
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
        // A folder with open files deleted (a branch switch, a clean), back half the time.
        stress.add(StressStep("explorer.folderGone", weight: 1) { run in
            let folder = run.file("src/deep")
            let saved = run.file("../deep-saved")
            await run.open("src/deep/a/b/c/name with spaces & ünïcode.txt")
            try? FileManager.default.removeItem(at: saved)
            try? FileManager.default.moveItem(at: folder, to: saved)
            await run.settle()
            if run.chance(0.5) { try? FileManager.default.moveItem(at: saved, to: folder) }
        })
        // Read-only on disk: typing works, saving fails and says so.
        stress.add(StressStep("explorer.readOnly", weight: 1) { run in
            let path = run.pick(["one-line.txt", "crlf.txt"]) ?? "one-line.txt"
            let url = run.file(path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
            await run.open(path)
            run.run("editor.save")
            await run.settle()
            if run.chance(0.6) { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        })
        // Renamed outside while open: in Finder, by git mv, by a refactoring tool.
        stress.add(StressStep("explorer.outsideRename", weight: 1) { run in
            let from = run.file("tabs.go"), to = run.file("tabs-moved.go")
            await run.open("tabs.go")
            try? FileManager.default.moveItem(at: from, to: to)
            await run.settle()
            try? FileManager.default.moveItem(at: to, to: from)
        })
        // The project's own folder renamed in Finder, then back.
        stress.add(StressStep("explorer.projectRenamed", weight: 1) { run in
            let moved = run.project.deletingLastPathComponent().appendingPathComponent(run.project.lastPathComponent + "-renamed")
            guard (try? FileManager.default.moveItem(at: run.project, to: moved)) != nil else { return }
            try? await Task.sleep(for: .milliseconds(run.int(50...1500)))
            await run.settle()
            try? FileManager.default.moveItem(at: moved, to: run.project)
        })
        stress.exempt(StressCoverage.command("file.revealInFinder"), because: "brings Finder to the front")
        stress.exempt(StressCoverage.command("file.copyPath"), because: "writes the user's clipboard")
        stress.exempt(StressCoverage.command("file.copyRelativePath"), because: "writes the user's clipboard")
    }
}
#endif
