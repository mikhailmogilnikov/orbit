import AppKit
import OrbitAPI
import SwiftUI

public final class GitPlugin: OrbitPlugin {
    public static let manifest = PluginManifest(
        id: "orbit.git",
        name: "Source Control",
        summary: "Git status, staging, commits, branches, history, pull and push.",
        systemImage: "arrow.triangle.branch",
        tint: .orange,
        tools: ["git"]
    )

    private var activationObserver: NSObjectProtocol?

    public init() {}

    public func activate(_ context: PluginContext) {
        let workspace = context.workspace
        let ui = context.ui
        let model = GitModel(workspace: workspace, services: context.services, settings: context.settings)
        model.revealPanel = { [weak ui] in ui?.revealSidebarPanel("git") }

        ui.addSettingsPane(SettingsPane(
            id: "git", title: "Source Control", systemImage: "arrow.triangle.branch", tint: .orange, group: .code, order: 30,
            summary: "What Git shows in the editor and the status bar.",
            keywords: ["git", "gutter", "markers", "changes"],
            items: { [
                SettingsItem("changeMarkers", "Change markers", keywords: ["gutter", "diff", "modified lines"]),
            ] }
        ) {
            GitSettingsPane(model: model)
        })
        context.services.register(FileStatusProviding.self, model)
        context.services.register(VersionControlBaseline.self, model)
        context.services.register(ConflictResolving.self, model)
        // Git Lens (same module, its own plugin) builds on this model (D194).
        context.services.register(GitModel.self, model)

        ui.addEditorProvider(EditorProvider(
            id: "git.diff",
            accepts: { $0.kind == GitModel.diffKind || $0.kind == GitModel.stagedDiffKind }
        ) { tab in
            GitDiffView(model: model, url: tab.url!, staged: tab.kind == GitModel.stagedDiffKind)
                .id(tab.id)
        })

        ui.addEditorProvider(EditorProvider(
            id: "git.commit",
            accepts: { $0.kind == GitModel.commitKind || $0.kind == GitModel.compareKind }
        ) { tab in
            GitCommitDiffView(model: model, tab: tab)
                .id(tab.id)
        })

        ui.addEditorProvider(EditorProvider(
            id: "git.revision",
            accepts: { $0.kind == GitModel.revisionKind }
        ) { tab in
            GitRevisionView(model: model, tab: tab)
                .id(tab.id)
        })

        ui.addSidebarPanel(PanelContribution(id: "git", title: "Source Control", systemImage: "arrow.triangle.branch", order: 15) {
            GitPanel(model: model)
        }.command("git.show"))

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

        // Status follows the folder, agent edits and anything done outside (terminal, other apps).
        // Weakly: the workspace keeps the observation until it next changes,
        // long after Source Control may have been turned off (D194).
        Self.observe(context) { [weak model] in model?.refresh() }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { model.refresh() }
        }
        model.refresh()
        #if DEBUG
        GitStress.register(context, model: model)
        #endif
    }

    public func deactivate() {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    private static func observe(_ context: PluginContext, onChange: @escaping @MainActor () -> Void) {
        observe(context.workspace, lifetime: context.lifetime, onChange: onChange)
    }

    /// The host holds `lifetime` while the plugin is on; once it's gone, so is this.
    private static func observe(_ workspace: Workspace, lifetime: PluginLifetime, onChange: @escaping @MainActor () -> Void) {
        withObservationTracking {
            _ = workspace.root
            _ = workspace.fileSystemGeneration
        } onChange: { [weak workspace, weak lifetime] in
            Task { @MainActor in
                guard let workspace, let lifetime, lifetime.isActive, !workspace.isClosed else { return }
                onChange()
                observe(workspace, lifetime: lifetime, onChange: onChange)
            }
        }
    }
}
