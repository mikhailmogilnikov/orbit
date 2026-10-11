import AppKit
import OrbitAPI
import SwiftUI

public final class GitPlugin: OrbitPlugin {
    public static let manifest = PluginManifest(
        id: "orbit.git",
        name: "Source Control",
        summary: "Git status, staging, commits, branches, pull and push.",
        systemImage: "arrow.triangle.branch"
    )

    private var activationObserver: NSObjectProtocol?

    public init() {}

    public func activate(_ context: PluginContext) {
        let workspace = context.workspace
        let ui = context.ui
        let model = GitModel(workspace: workspace, services: context.services)
        context.services.register(FileStatusProviding.self, model)
        context.services.register(VersionControlBaseline.self, model)

        ui.addEditorProvider(EditorProvider(
            id: "git.diff",
            accepts: { $0.kind == GitModel.diffKind || $0.kind == GitModel.stagedDiffKind }
        ) { tab in
            GitDiffView(model: model, url: tab.url!, staged: tab.kind == GitModel.stagedDiffKind)
                .id(tab.id)
        })

        ui.addEditorProvider(EditorProvider(
            id: "git.commit",
            accepts: { $0.kind == GitModel.commitKind }
        ) { tab in
            GitCommitDiffView(model: model, tab: tab)
                .id(tab.id)
        })

        ui.addSidebarPanel(PanelContribution(id: "git", title: "Source Control", systemImage: "arrow.triangle.branch", order: 15) {
            GitPanel(model: model)
        })

        let isReady: @MainActor () -> Bool = { model.state == .ready && !model.isBusy }
        context.commands.register(OrbitCommand(
            id: "git.show",
            title: "Show Source Control",
            category: "Git",
            systemImage: "arrow.triangle.branch",
            shortcut: KeyboardShortcut("g", modifiers: [.control, .shift])
        ) {
            ui.revealSidebarPanel("git")
        })
        context.commands.register(OrbitCommand(
            id: "git.commit", title: "Commit", category: "Git", systemImage: "checkmark.circle",
            isEnabled: { isReady() && model.canCommit }
        ) { model.commit() })
        context.commands.register(OrbitCommand(
            id: "git.generateMessage", title: "Generate Commit Message", category: "Git", systemImage: "sparkles",
            isEnabled: { isReady() && model.messageAgent != nil && !model.status.files.isEmpty }
        ) { model.generateMessage() })
        context.commands.register(OrbitCommand(
            id: "git.pull", title: "Pull", category: "Git", systemImage: "arrow.down.circle", isEnabled: isReady
        ) { model.pull() })
        context.commands.register(OrbitCommand(
            id: "git.push", title: "Push", category: "Git", systemImage: "arrow.up.circle", isEnabled: isReady
        ) { model.push() })
        context.commands.register(OrbitCommand(
            id: "git.fetch", title: "Fetch", category: "Git", systemImage: "arrow.triangle.2.circlepath", isEnabled: isReady
        ) { model.fetch() })
        context.commands.register(OrbitCommand(
            id: "git.stash", title: "Stash Changes…", category: "Git", systemImage: "tray.and.arrow.down",
            isEnabled: { isReady() && !model.status.files.isEmpty }
        ) {
            ui.revealSidebarPanel("git")
            model.isNamingStash = true
        })
        context.commands.register(OrbitCommand(
            id: "git.stashPop", title: "Pop Latest Stash", category: "Git", systemImage: "tray.and.arrow.up",
            isEnabled: { isReady() && !model.stashes.isEmpty }
        ) {
            if let latest = model.stashes.first { model.applyStash(latest, drop: true) }
        })

        // The Editor plugin activates later; look its service up when drawing.
        let services = context.services
        ui.addStatusItem(StatusItem(
            id: "git.blame", placement: .trailing, order: 50,
            isVisible: {
                guard model.state == .ready, model.status.hasCommits,
                      let cursor = services.resolve(EditorSelectionProviding.self)?.cursor else { return false }
                return cursor.url == workspace.activeTab?.url && model.status(of: cursor.url) != .untracked
            }
        ) {
            if let editor = services.resolve(EditorSelectionProviding.self) {
                BlameStatus(model: model, editor: editor, workspace: workspace)
            }
        })

        // Status follows the folder, agent edits and anything done outside (terminal, other apps).
        Self.observe(workspace) { model.refresh() }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { model.refresh() }
        }
        model.refresh()
    }

    public func deactivate() {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    private static func observe(_ workspace: Workspace, onChange: @escaping @MainActor () -> Void) {
        withObservationTracking {
            _ = workspace.root
            _ = workspace.fileSystemGeneration
        } onChange: {
            Task { @MainActor in
                onChange()
                observe(workspace, onChange: onChange)
            }
        }
    }
}
