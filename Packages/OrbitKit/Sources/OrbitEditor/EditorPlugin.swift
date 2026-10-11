import AppKit
import OrbitAPI
import OrbitUI
import SwiftUI

public final class EditorPlugin: OrbitPlugin {
    public static let manifest = PluginManifest(
        id: "orbit.editor",
        name: "Code Editor",
        summary: "TextKit 2 editor with tree-sitter highlighting.",
        systemImage: "chevron.left.forwardslash.chevron.right"
    )

    private var activationObserver: NSObjectProtocol?

    public init() {}

    public func activate(_ context: PluginContext) {
        HighlightQueries.prewarm()
        let workspace = context.workspace
        let services = context.services

        context.ui.addEditorProvider(EditorProvider(
            id: "editor.text",
            priority: 0,
            accepts: { $0.kind == EditorTab.fileKind && $0.url != nil }
        ) { tab in
            FileEditorView(
                document: workspace.documents.document(for: tab.url!),
                workspace: workspace,
                changes: services.resolve(ChangeTracking.self),
                versionControl: services.resolve(VersionControlBaseline.self)
            )
            .id(tab.id)
        })

        context.commands.register(OrbitCommand(
            id: "editor.save",
            title: "Save",
            category: "File",
            systemImage: "square.and.arrow.down",
            shortcut: KeyboardShortcut("s", modifiers: .command),
            isEnabled: { Self.activeDocument(workspace)?.isDirty == true }
        ) {
            if let document = Self.activeDocument(workspace) { Self.save(document) }
        })

        context.commands.register(OrbitCommand(
            id: "editor.saveAll",
            title: "Save All",
            category: "File",
            shortcut: KeyboardShortcut("s", modifiers: [.command, .option])
        ) {
            // Conflicted files wait for the user's pick in their banner.
            workspace.documents.syncWithDisk()
            for document in workspace.documents.dirtyDocuments where document.diskConflict == nil { try? document.save() }
        })

        context.commands.register(OrbitCommand(
            id: "editor.closeTab",
            title: "Close Tab",
            category: "File",
            shortcut: KeyboardShortcut("w", modifiers: .command),
            isEnabled: { workspace.activeTab != nil }
        ) {
            workspace.closeActiveTab()
        })

        // Edits made in other apps or an external terminal while Orbit was in the background.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { workspace.documents.syncWithDisk() }
        }

        registerChangeCommands(context)
        context.services.register(EditorSelectionProviding.self, EditorSelectionService.shared)
        context.services.register(SyntaxHighlighting.self, StaticHighlighter())
    }

    private func registerChangeCommands(_ context: PluginContext) {
        let services = context.services
        func hasHunks() -> Bool { ActiveEditor.shared.coordinator?.inlineDiff.hunks.isEmpty == false }
        func currentHunk() -> (DiffHunk, URL, ChangeTracking)? {
            guard let coordinator = ActiveEditor.shared.coordinator,
                  let tracker = services.resolve(ChangeTracking.self),
                  let hunk = coordinator.inlineDiff.hunk(near: coordinator.cursorLine) else { return nil }
            return (hunk, coordinator.document.url, tracker)
        }

        context.commands.register(OrbitCommand(
            id: "editor.keepChange",
            title: "Keep Change",
            category: "Review",
            systemImage: "checkmark",
            shortcut: KeyboardShortcut(.return, modifiers: [.command, .option]),
            isEnabled: hasHunks
        ) {
            guard let (hunk, url, tracker) = currentHunk() else { return }
            tracker.keep(hunk, in: url)
        })
        context.commands.register(OrbitCommand(
            id: "editor.undoChange",
            title: "Undo Change",
            category: "Review",
            systemImage: "arrow.uturn.backward",
            shortcut: KeyboardShortcut(.delete, modifiers: [.command, .option]),
            isEnabled: hasHunks
        ) {
            guard let (hunk, url, tracker) = currentHunk() else { return }
            tracker.revert(hunk, in: url)
        })
        context.commands.register(OrbitCommand(
            id: "editor.nextChange",
            title: "Next Change",
            category: "Review",
            systemImage: "chevron.down",
            shortcut: KeyboardShortcut(.downArrow, modifiers: [.command, .option]),
            isEnabled: hasHunks
        ) {
            guard let coordinator = ActiveEditor.shared.coordinator else { return }
            coordinator.revealHunk(after: coordinator.cursorLine, forward: true)
        })
        context.commands.register(OrbitCommand(
            id: "editor.previousChange",
            title: "Previous Change",
            category: "Review",
            systemImage: "chevron.up",
            shortcut: KeyboardShortcut(.upArrow, modifiers: [.command, .option]),
            isEnabled: hasHunks
        ) {
            guard let coordinator = ActiveEditor.shared.coordinator else { return }
            coordinator.revealHunk(after: coordinator.cursorLine, forward: false)
        })
    }

    public func deactivate() {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    /// Saving over a change made on disk since the file was loaded needs a confirmation.
    static func save(_ document: TextDocument) {
        document.syncWithDisk()
        if document.diskConflict != nil {
            let alert = NSAlert()
            alert.messageText = "“\(document.url.lastPathComponent)” was changed on disk."
            alert.informativeText = "Saving replaces the version on disk with yours. Use Compare in the banner to take parts of it instead."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Save Anyway")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        do {
            try document.save()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    static func activeDocument(_ workspace: Workspace) -> TextDocument? {
        guard let tab = workspace.activeTab, tab.kind == EditorTab.fileKind, let url = tab.url else { return nil }
        return workspace.documents.existingDocument(for: url)
    }
}

struct FileEditorView: View {
    let document: TextDocument
    let workspace: Workspace
    let changes: ChangeTracking?
    let versionControl: VersionControlBaseline?
    /// What the gutter's change markers compare against.
    @State private var gitBaseline: String?
    @State private var isComparing = false

    var body: some View {
        let url = document.url
        let hunks = changes?.hunks(for: url) ?? []
        VStack(spacing: 0) {
            if document.isDeletedOnDisk {
                DiskDeletedBanner(document: document, workspace: workspace)
            } else if document.diskConflict != nil {
                DiskConflictBanner(document: document, isComparing: $isComparing)
            }
            if let changes, !hunks.isEmpty {
                AgentChangesBanner(url: url, hunks: hunks, changes: changes)
            }
            if let error = document.loadError {
                EmptyStateView("Can't Open File", systemImage: "doc.questionmark", message: error)
            } else {
                CodeEditor(
                    document: document,
                    hunks: hunks,
                    onKeep: { changes?.keep($0, in: url) },
                    onRevert: { changes?.revert($0, in: url) },
                    revealLine: workspace.pendingReveal?.url == url ? workspace.pendingReveal?.line : nil,
                    onRevealHandled: { workspace.pendingReveal = nil },
                    gitBaseline: gitBaseline
                )
            }
        }
        .task(id: versionControl?.baselineGeneration ?? -1) {
            gitBaseline = await versionControl?.baseline(for: url)
        }
        .sheet(isPresented: $isComparing) {
            DiskConflictComparison(document: document)
        }
        .onChange(of: document.diskConflict == nil) { _, resolved in
            if resolved { isComparing = false }
        }
    }
}

struct AgentChangesBanner: View {
    let url: URL
    let hunks: [DiffHunk]
    let changes: ChangeTracking

    var body: some View {
        let added = hunks.reduce(0) { $0 + $1.added }
        let removed = hunks.reduce(0) { $0 + $1.removed }
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
            Text("\(hunks.count) agent change\(hunks.count == 1 ? "" : "s")")
                .font(.callout.weight(.medium))
            DiffStatBadge(added: added, removed: removed)
            HStack(spacing: 0) {
                IconButton("chevron.up", help: "Previous change (⌥⌘↑)") {
                    guard let coordinator = ActiveEditor.shared.coordinator else { return }
                    coordinator.revealHunk(after: coordinator.cursorLine, forward: false)
                }
                IconButton("chevron.down", help: "Next change (⌥⌘↓)") {
                    guard let coordinator = ActiveEditor.shared.coordinator else { return }
                    coordinator.revealHunk(after: coordinator.cursorLine, forward: true)
                }
            }
            Spacer()
            Button("Undo All") { changes.reject(url) }
                .buttonStyle(.glass)
            Button("Keep All") { changes.accept(url) }
                .buttonStyle(.glassProminent)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.tint.opacity(0.06))
        .overlay(alignment: .bottom) { Divider() }
    }
}

