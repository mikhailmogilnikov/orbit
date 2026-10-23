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
        stress.add(StressStep("shell.bottomPanel", weight: 2) { context in
            let ui = context.ui
            if let panel = context.pick(ui.bottomPanels) { ui.toggleBottomPanel(panel.id) }
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

    private static func window(of host: PluginHost) -> NSWindow? {
        NSApp.windows.first { ProjectWindows.shared.host(for: $0) === host }
    }
}
#endif
