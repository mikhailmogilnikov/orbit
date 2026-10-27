#if DEBUG
import AppKit
import OrbitKit

/// The shell's part of a stress run (D244): the window itself, beside what
/// the plugins bring. Registered in every window of a debug build.
@MainActor
enum ShellStress {
    static func register(in host: PluginHost) {
        let stress = host.stress
        let workspace = host.workspace

        stress.add(StressStep("shell.windowSize", weight: 4) { context in
            guard let window = window(of: host), let screen = window.screen ?? NSScreen.main else { return }
            // The minimum, odd sizes, the screen and past it (AppKit keeps it on screen).
            let sizes = [NSSize(width: 960, height: 600), NSSize(width: 973, height: 611), NSSize(width: 1280, height: 800),
                         screen.visibleFrame.size, NSSize(width: 4000, height: 3000)]
            guard let size = context.pick(sizes) else { return }
            context.note("\(Int(size.width))×\(Int(size.height)), \(workspace.isSplit ? "split" : "one group"), \(workspace.allTabs.count) tabs")
            let frame = NSRect(origin: window.frame.origin, size: size)
            window.setFrame(window.constrainFrameRect(frame, to: screen), display: true)
        })
        if !StressRunner.shared.inBackground {
            stress.add(StressStep("shell.fullScreen", weight: 1) { context in
                window(of: host)?.toggleFullScreen(nil)
                try? await Task.sleep(for: .seconds(1))
            })
        }
        stress.add(StressStep("shell.appearance", weight: 1) { context in
            Preferences.shared.appearance = context.pick(Preferences.Appearance.allCases) ?? .system
        })
        stress.add(StressStep("shell.splitAndMove", weight: 2, when: { _ in !workspace.allTabs.isEmpty }) { context in
            workspace.splitEditor()
            await context.settle()
            if context.chance(0.5) { workspace.moveActiveTabToOtherGroup() }
            workspace.splitFraction = Double(context.int(15...85)) / 100
        })
        // D243: Join right after Split crashed in EditorGroups.
        stress.add(StressStep("shell.splitThenJoin", weight: 1, regression: true, when: { _ in !workspace.allTabs.isEmpty }) { _ in
            workspace.splitEditor()
            workspace.joinGroups()
        })
        // D246: on a 1x screen (macOS 26 in the VM) a zoomed font in a narrow
        // split laid the window out forever, the editor area's width fed back.
        stress.add(StressStep("shell.zoomedNarrowSplit", weight: 1, regression: true) { context in
            guard let window = window(of: host), let screen = window.screen ?? NSScreen.main else { return }
            let frame = window.frame
            await context.open("src/short.tsx")
            context.run("editor.zoomIn")
            if !workspace.isSplit { workspace.splitEditor() }
            context.run("editor.zoomIn")
            window.setFrame(window.constrainFrameRect(NSRect(origin: frame.origin, size: NSSize(width: 1024, height: 681)), to: screen), display: true)
            await context.settle()
            await context.open("one-line.txt")
            await context.settle()
            context.run("editor.zoomReset")
            window.setFrame(frame, display: true)
        })
        // D247: Settings opened with the sidebar and the inspector open in the
        // smallest window: the workspace taken down kept resizing and AppKit threw.
        stress.add(StressStep("shell.settingsInSmallWindow", weight: 1, regression: true) { context in
            guard let window = window(of: host), let screen = window.screen ?? NSScreen.main else { return }
            let frame = window.frame
            context.ui.revealSidebarPanel(context.ui.sidebarPanels.first?.id ?? "explorer")
            context.ui.revealInspectorPanel(context.ui.inspectorPanels.first?.id ?? "agents")
            window.setFrame(window.constrainFrameRect(NSRect(origin: frame.origin, size: NSSize(width: 960, height: 600)), to: screen), display: true)
            await context.settle()
            context.ui.showSettings("general")
            await context.settle()
            context.ui.isSettingsVisible = false
            await context.settle()
            window.setFrame(frame, display: true)
        })
        // D250: the agents' inspector shown from inside a view update (a new
        // chat reveals it) in the smallest window: the split view's columns
        // kept asking for another Update Constraints pass, and in a window of
        // few views (just opened, no tabs) AppKit threw. Here, with the run's
        // many views, it only plays the path; the shrunk log reproduced it.
        stress.add(StressStep("shell.inspectorInSmallWindow", weight: 1, regression: true) { context in
            guard let window = window(of: host), let screen = window.screen ?? NSScreen.main else { return }
            let frame = window.frame
            if UserDefaults.standard.bool(forKey: "orbit.showsInspector") { context.run("shell.toggleAgents") }
            await context.settle()
            window.setFrame(window.constrainFrameRect(NSRect(origin: frame.origin, size: NSSize(width: 960, height: 600)), to: screen), display: true)
            await context.settle()
            await context.settle()
            context.ui.revealInspectorPanel(context.ui.inspectorPanels.first?.id ?? "agents")
            await context.settle()
            window.setFrame(frame, display: true)
        })
        stress.add(StressStep("shell.tabs", weight: 3, when: { _ in workspace.allTabs.count > 1 }) { context in
            for _ in 0..<context.int(1...6) {
                switch context.int(0...3) {
                case 0: workspace.showAdjacentTab(context.chance(0.5) ? 1 : -1)
                case 1: workspace.closeActiveTab()
                case 2: workspace.reopenClosedTab()
                default: if context.chance(0.5) { workspace.goBack() } else { workspace.goForward() }
                }
            }
        })
        // The same state in every run, for commands that need it: tabs on both
        // sides of a split, one just closed, a place to go back to.
        stress.add(StressStep("shell.richState", weight: 1) { context in
            for path in ["src/short.tsx", "tabs.go", "crlf.txt"] { await context.open(path) }
            if !workspace.isSplit { workspace.splitEditor() }
            await context.settle()
            for path in ["src/long.swift", "one-line.txt"] { await context.open(path) }
            workspace.closeActiveTab()
        })
        stress.add(StressStep("shell.backAndForth", weight: 2) { context in
            await context.open("src/short.tsx")
            await context.open("tabs.go")
            context.run("shell.goBack")
            await context.settle()
            context.run("shell.goForward")
        })
        // A process Orbit started dies: a language server, a terminal's shell, git.
        stress.add(StressStep("shell.childDies", weight: 1) { context in
            guard let child = context.pick(childProcesses()) else { return }
            context.note("killed \(child.name) (\(child.pid))")
            kill(child.pid, context.chance(0.5) ? SIGKILL : SIGTERM)
        })
        stress.add(StressStep("shell.bottomPanel", weight: 2) { context in
            let ui = context.ui
            if let panel = context.pick(ui.bottomPanels) { ui.toggleBottomPanel(panel.id) }
        })

        // A window opened, used and closed: all it held goes with it (D101, D246).
        stress.add(StressStep("shell.secondWindow", weight: 1) { context in
            let before = Set(ProjectWindows.shared.allHosts.map(ObjectIdentifier.init))
            ProjectWindows.shared.newWindow()
            var opened: PluginHost?
            for _ in 0..<100 where opened == nil {
                try? await Task.sleep(for: .milliseconds(50))
                opened = ProjectWindows.shared.allHosts.first { !before.contains(ObjectIdentifier($0)) }
            }
            guard let opened else { return context.note("no second window") }
            opened.workspace.requestOpenFolder(context.file("src"))
            await context.settle()
            opened.workspace.openFile(context.file("src/long.swift"))
            await context.settle()
            if let panel = context.pick(opened.ui.sidebarPanels) { opened.ui.revealSidebarPanel(panel.id) }
            await context.settle()
            window(of: opened)?.performClose(nil)
            context.expectFreed(opened, "a closed window's PluginHost")
            context.expectFreed(opened.workspace, "a closed window's Workspace")
        })
        // Settings opened and closed: its views go with it (D246).
        stress.add(StressStep("shell.settingsFreed", weight: 1) { context in
            guard let window = window(of: host), let content = window.contentView, !context.ui.isSettingsVisible else { return }
            let before = Set(views(in: content).map(ObjectIdentifier.init))
            let pane = context.pick(context.ui.settingsPanes.map(\.id)) ?? "general"
            context.note(pane)
            context.ui.showSettings(pane)
            await context.settle()
            // The outermost new views: freed, so is everything inside them.
            let opened = views(in: content).filter { !before.contains(ObjectIdentifier($0)) }
            let openedIDs = Set(opened.map(ObjectIdentifier.init))
            let roots = opened.filter { $0.superview.map { !openedIDs.contains(ObjectIdentifier($0)) } ?? true }
            context.ui.isSettingsVisible = false
            await context.settle()
            // The largest of them stands for Settings: one a close, so three closes make three.
            if let root = roots.max(by: { views(in: $0).count < views(in: $1).count }), root.window == nil {
                context.expectFreed(root, "a view of closed Settings")
            }
        })
        stress.add(StressStep("shell.pluginOffAndOn", weight: 1) { context in
            let optional = host.entries.filter {
                !$0.manifest.isRequired && StressCoverage.exemption(for: StressCoverage.plugin($0.id), in: host.stress.exemptions) == nil
            }
            guard let entry = context.pick(optional) else { return }
            context.note(entry.id)
            await StressRunner.shared.turnOffAndOn(entry.id)
        })

        stress.add(StressCheck("shell.groups") { _ in
            let groups = workspace.groups
            guard (1...2).contains(groups.count) else { return "\(groups.count) editor groups" }
            guard groups.indices.contains(workspace.focusedGroup) else { return "focused group \(workspace.focusedGroup) of \(groups.count)" }
            for group in groups {
                let ids = group.tabs.map(\.id)
                if Set(ids).count != ids.count { return "a group holds a tab twice" }
                if let active = group.activeTabID, !group.contains(active) { return "the active tab isn't in its group" }
                if group.activeTabID == nil, !group.tabs.isEmpty { return "a group with tabs and none active" }
                if let preview = group.previewTabID, !group.contains(preview) { return "the preview tab isn't in its group" }
            }
            if groups.count == 2, groups.contains(where: \.tabs.isEmpty) { return "a split with an empty side" }
            return nil
        })
    }

    private static func childProcesses() -> [(pid: pid_t, name: String)] {
        let list = Process()
        let pipe = Pipe()
        list.executableURL = URL(fileURLWithPath: "/bin/ps")
        list.arguments = ["-o", "pid=,comm=", "-g", String(getpgrp())]
        list.standardOutput = pipe
        guard (try? list.run()) != nil else { return [] }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        list.waitUntilExit()
        return output.split(separator: "\n").compactMap { line in
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let pid = pid_t(parts[0]), pid != getpid(), pid != list.processIdentifier else { return nil }
            return (pid, String(parts[1]).components(separatedBy: "/").last ?? "")
        }
    }

    private static func views(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { views(in: $0) }
    }

    private static func window(of host: PluginHost) -> NSWindow? {
        NSApp.windows.first { ProjectWindows.shared.host(for: $0) === host }
    }
}
#endif
