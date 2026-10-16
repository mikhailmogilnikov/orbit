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

    /// The open folder's languages get their grammars before their files open (D71).
    private static func prefetchGrammars(_ workspace: Workspace, services: ServiceRegistry) {
        let root = withObservationTracking { workspace.root } onChange: {
            Task { @MainActor in
                if !workspace.isClosed { prefetchGrammars(workspace, services: services) }
            }
        }
        guard root != nil else { return }
        Task { @MainActor in
            guard let index = services.resolve(ProjectFileIndex.self) else { return }
            let paths = await index.allPaths()
            guard workspace.root == root else { return }
            GrammarRegistry.shared.prefetch(paths)
        }
    }

    public func activate(_ context: PluginContext) {
        let workspace = context.workspace
        let services = context.services
        Task.detached(priority: .background) { GrammarStore.shared.pruneOutdated() }
        Self.prefetchGrammars(workspace, services: services)
        let options = EditorOptions(settings: context.settings)

        context.ui.addSettingsPane(SettingsPane(
            id: "editor", title: "Editor", systemImage: "chevron.left.forwardslash.chevron.right", order: 10,
            keywords: ["font", "size", "wrap", "line", "highlight", "inlay", "hints", "types", "parameters"]
        ) {
            EditorSettingsPane(options: options)
        })

        context.ui.addEditorProvider(EditorProvider(
            id: "editor.text",
            priority: 0,
            accepts: { $0.kind == EditorTab.fileKind && $0.url != nil }
        ) { tab in
            FileEditorView(
                document: workspace.documents.document(for: tab.url!),
                workspace: workspace,
                changes: services.resolve(ChangeTracking.self),
                versionControl: services.resolve(VersionControlBaseline.self),
                languages: services.resolve(LanguageIntelligence.self),
                options: options,
                ui: context.ui,
                commands: context.commands
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
            guard let document = Self.activeDocument(workspace) else { return }
            Self.formatThenSave(document, options: options, languages: services.resolve(LanguageIntelligence.self))
        })

        context.commands.register(OrbitCommand(
            id: "editor.saveAll",
            title: "Save All",
            category: "File",
            shortcut: KeyboardShortcut("s", modifiers: [.command, .option])
        ) {
            // Conflicted files wait for the user's pick in their banner.
            workspace.documents.syncWithDisk()
            for document in workspace.documents.dirtyDocuments where document.diskConflict == nil {
                Self.formatThenSave(document, options: options, languages: services.resolve(LanguageIntelligence.self), quietly: true)
            }
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

        let hasServer: @MainActor () -> Bool = {
            guard let coordinator = ActiveEditor.shared.coordinator else { return false }
            return coordinator.languages?.server(for: coordinator.document.url) != nil
        }
        // Xcode's keys: Jump to Definition ⌃⌘J, Jump to Next Issue ⌘'.
        context.commands.register(OrbitCommand(
            id: "editor.goToDefinition",
            title: "Go to Definition",
            category: "Code",
            systemImage: "arrow.right.circle",
            shortcut: KeyboardShortcut("j", modifiers: [.command, .control]),
            editorMenu: EditorMenuPlacement(.navigate, isVisible: hasServer)
        ) {
            guard let coordinator = ActiveEditor.shared.coordinator, let textView = coordinator.textView else {
                NSSound.beep()
                return
            }
            coordinator.goToDefinition(at: textView.textSelection.location)
        })

        // Xcode's keys for folding (D79).
        let folding: [(id: String, title: String, symbol: String, key: KeyEquivalent, shift: Bool, run: @MainActor (FoldingController) -> Void)] = [
            ("editor.fold", "Fold", "chevron.down", .leftArrow, false, { $0.foldAtCaret() }),
            ("editor.unfold", "Unfold", "chevron.right", .rightArrow, false, { $0.unfoldAtCaret() }),
            ("editor.foldAll", "Fold All", "chevron.down.2", .leftArrow, true, { $0.foldAll() }),
            ("editor.unfoldAll", "Unfold All", "chevron.right.2", .rightArrow, true, { $0.unfoldAll() }),
        ]
        for command in folding {
            context.commands.register(OrbitCommand(
                id: command.id,
                title: command.title,
                category: "Code",
                systemImage: command.symbol,
                shortcut: KeyboardShortcut(command.key, modifiers: command.shift ? [.command, .option, .shift] : [.command, .option])
            ) {
                guard let coordinator = ActiveEditor.shared.coordinator else {
                    NSSound.beep()
                    return
                }
                command.run(coordinator.folding)
            })
        }

        context.ui.addStatusItem(StatusItem(
            id: "editor.indentation", placement: .trailing, order: 20,
            isVisible: { Self.activeDocument(workspace).flatMap { EditorIndentation.shared.indentation(for: $0.url) } != nil }
        ) {
            IndentationStatus(workspace: workspace)
        })

        context.ui.addStatusItem(StatusItem(
            id: "editor.fileFormat", placement: .trailing, order: 19,
            isVisible: { Self.activeDocument(workspace)?.format.isDefault == false }
        ) {
            FileFormatStatus(workspace: workspace)
        })

        context.commands.register(OrbitCommand(
            id: "editor.toggleInlayHints",
            title: "Toggle Inlay Hints",
            category: "Code",
            systemImage: "text.badge.plus"
        ) {
            options.showsInlayHints.toggle()
        })

        context.commands.register(OrbitCommand(
            id: "editor.nextProblem",
            title: "Next Problem",
            category: "Code",
            systemImage: "exclamationmark.triangle",
            shortcut: KeyboardShortcut("'", modifiers: .command),
        ) {
            ActiveEditor.shared.coordinator?.revealNextProblem()
        })
        // Language-server actions (D59). ⌘. is Stop Agent, so code actions take Xcode's ⇧⌘A.
        // Always enabled: menus can't observe the active editor or its server,
        // so a disabled item would stay disabled (the action beeps instead).
        context.commands.register(OrbitCommand(
            id: "editor.codeActions",
            title: "Show Code Actions",
            category: "Code",
            systemImage: "wand.and.sparkles",
            shortcut: KeyboardShortcut("a", modifiers: [.command, .shift]),
            editorMenu: EditorMenuPlacement(.edit, title: "Fixes and Actions…", isVisible: hasServer)
        ) {
            ActiveEditor.shared.coordinator?.showCodeActions()
        })
        context.commands.register(OrbitCommand(
            id: "editor.rename",
            title: "Rename Symbol…",
            category: "Code",
            systemImage: "pencil",
            shortcut: KeyboardShortcut("e", modifiers: [.command, .control]),
            editorMenu: EditorMenuPlacement(.edit, isVisible: hasServer)
        ) {
            ActiveEditor.shared.coordinator?.startRename()
        })
        context.commands.register(OrbitCommand(
            id: "editor.toggleComment",
            title: "Toggle Comment",
            category: "Code",
            systemImage: "number",
            shortcut: KeyboardShortcut("/", modifiers: .command),
            editorMenu: EditorMenuPlacement(.edit)
        ) {
            ActiveEditor.shared.coordinator?.toggleComment()
        })
        registerLineCommands(context)

        context.commands.register(OrbitCommand(
            id: "editor.format",
            title: "Format Document",
            category: "Code",
            systemImage: "text.alignleft",
            shortcut: KeyboardShortcut("i", modifiers: [.control, .shift]),
            editorMenu: EditorMenuPlacement(.edit) {
                guard let coordinator = ActiveEditor.shared.coordinator else { return false }
                return coordinator.languages?.canFormat(coordinator.document.url) == true
            }
        ) {
            ActiveEditor.shared.coordinator?.formatDocument()
        })
        // On demand, for projects whose linter doesn't order imports (D81); ⌃⌥O as VS Code's ⇧⌥O types a letter here.
        context.commands.register(OrbitCommand(
            id: "editor.organizeImports",
            title: "Organize Imports",
            category: "Code",
            systemImage: "arrow.up.arrow.down",
            shortcut: KeyboardShortcut("o", modifiers: [.control, .option]),
            editorMenu: EditorMenuPlacement(.edit, isVisible: hasServer)
        ) {
            guard let coordinator = ActiveEditor.shared.coordinator, let languages = coordinator.languages else {
                NSSound.beep()
                return
            }
            let url = coordinator.document.url
            Task {
                if await languages.runCodeActions(["source.organizeImports"], in: url) == 0 { NSSound.beep() }
            }
        })
        context.services.register(SourceEditing.self, OpenEditors.shared)
        context.services.register(EditorSelectionProviding.self, EditorSelectionService.shared)
        context.services.register(SyntaxHighlighting.self, StaticHighlighter())
    }

    /// Text editing as in VS Code and Cursor; keys that mean something else in
    /// text fields are the editor's own (`editorShortcut`).
    private func registerLineCommands(_ context: PluginContext) {
        func editor(_ run: @escaping @MainActor (CodeEditor.Coordinator) -> Void) -> @MainActor () -> Void {
            {
                guard let coordinator = ActiveEditor.shared.coordinator else { return NSSound.beep() }
                run(coordinator)
            }
        }
        let commands: [OrbitCommand] = [
            OrbitCommand(
                id: "editor.goToLine", title: "Go to Line…", category: "Code", systemImage: "arrow.right.to.line",
                shortcut: KeyboardShortcut("g", modifiers: .control), run: editor { $0.showGoToLine() }
            ),
            // ⌥⌘[ ⌥⌘] are Xcode's, safe in the menu; ⌥↑ ⌥↓ are VS Code's, in the editor only.
            OrbitCommand(
                id: "editor.moveLineUp", title: "Move Line Up", category: "Code", systemImage: "arrow.up.to.line",
                shortcut: KeyboardShortcut("[", modifiers: [.command, .option]),
                editorShortcut: KeyboardShortcut(.upArrow, modifiers: .option), run: editor { $0.moveLines(up: true) }
            ),
            OrbitCommand(
                id: "editor.moveLineDown", title: "Move Line Down", category: "Code", systemImage: "arrow.down.to.line",
                shortcut: KeyboardShortcut("]", modifiers: [.command, .option]),
                editorShortcut: KeyboardShortcut(.downArrow, modifiers: .option), run: editor { $0.moveLines(up: false) }
            ),
            OrbitCommand(
                id: "editor.copyLineUp", title: "Copy Line Up", category: "Code", systemImage: "plus.square.on.square",
                editorShortcut: KeyboardShortcut(.upArrow, modifiers: [.option, .shift]), run: editor { $0.copyLines(down: false) }
            ),
            OrbitCommand(
                id: "editor.copyLineDown", title: "Copy Line Down", category: "Code", systemImage: "plus.square.on.square",
                editorShortcut: KeyboardShortcut(.downArrow, modifiers: [.option, .shift]), run: editor { $0.copyLines(down: true) }
            ),
            OrbitCommand(
                id: "editor.addNextOccurrence", title: "Add Selection to Next Match", category: "Code", systemImage: "character.cursor.ibeam",
                editorShortcut: KeyboardShortcut("d", modifiers: .command), run: editor { $0.addNextOccurrence() }
            ),
            OrbitCommand(
                id: "editor.selectAllOccurrences", title: "Select All Matches", category: "Code", systemImage: "text.cursor",
                editorShortcut: KeyboardShortcut("l", modifiers: [.command, .shift]), run: editor { $0.selectAllOccurrences() }
            ),
            // ⌥⌘↑ ⌥⌘↓ walk agent changes here (D45), so Xcode's ⌃⇧↑ ⌃⇧↓.
            OrbitCommand(
                id: "editor.addCaretAbove", title: "Add Cursor Above", category: "Code", systemImage: "arrow.up",
                editorShortcut: KeyboardShortcut(.upArrow, modifiers: [.control, .shift]), run: editor { $0.addCaret(up: true) }
            ),
            OrbitCommand(
                id: "editor.addCaretBelow", title: "Add Cursor Below", category: "Code", systemImage: "arrow.down",
                editorShortcut: KeyboardShortcut(.downArrow, modifiers: [.control, .shift]), run: editor { $0.addCaret(up: false) }
            ),
        ]
        for command in commands { context.commands.register(command) }

        // The code font is shared with the terminal and diffs, so zoom is app-wide.
        let preferences = Preferences.shared
        func zoom(_ size: @escaping @MainActor (Double) -> Double) -> @MainActor () -> Void {
            {
                let range = Preferences.codeFontSizes
                preferences.codeFontSize = min(range.upperBound, max(range.lowerBound, size(preferences.codeFontSize)))
            }
        }
        context.commands.register(OrbitCommand(
            id: "editor.zoomIn", title: "Increase Font Size", category: "View", systemImage: "textformat.size.larger",
            shortcut: KeyboardShortcut("=", modifiers: .command), run: zoom { ($0 + 1).rounded(.down) }
        ))
        context.commands.register(OrbitCommand(
            id: "editor.zoomOut", title: "Decrease Font Size", category: "View", systemImage: "textformat.size.smaller",
            shortcut: KeyboardShortcut("-", modifiers: .command), run: zoom { ($0 - 1).rounded(.up) }
        ))
        context.commands.register(OrbitCommand(
            id: "editor.zoomReset", title: "Actual Font Size", category: "View", systemImage: "textformat.size",
            shortcut: KeyboardShortcut("0", modifiers: .command), run: zoom { _ in Preferences.defaultCodeFontSize }
        ))
    }

    private func registerChangeCommands(_ context: PluginContext) {
        let services = context.services
        let workspace = context.workspace
        func hasHunks() -> Bool { ActiveEditor.shared.coordinator?.inlineDiff.hunks.isEmpty == false }
        func hasPendingChanges() -> Bool { services.resolve(ChangeTracking.self)?.changedFiles.isEmpty == false }
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
            isEnabled: hasHunks,
            editorMenu: EditorMenuPlacement(.review) { currentHunk() != nil }
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
            isEnabled: hasHunks,
            editorMenu: EditorMenuPlacement(.review) { currentHunk() != nil }
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
            isEnabled: hasPendingChanges
        ) {
            Self.revealChange(forward: true, workspace: workspace, changes: services.resolve(ChangeTracking.self))
        })
        context.commands.register(OrbitCommand(
            id: "editor.previousChange",
            title: "Previous Change",
            category: "Review",
            systemImage: "chevron.up",
            shortcut: KeyboardShortcut(.upArrow, modifiers: [.command, .option]),
            isEnabled: hasPendingChanges
        ) {
            Self.revealChange(forward: false, workspace: workspace, changes: services.resolve(ChangeTracking.self))
        })
    }

    /// Next/previous agent change across all changed files: past the last
    /// change of the current file it moves on to the next file (wrapping).
    static func revealChange(forward: Bool, workspace: Workspace, changes: ChangeTracking?) {
        let coordinator = ActiveEditor.shared.coordinator
        let current = workspace.activeTab?.url?.standardizedFileURL
        if let coordinator, coordinator.document.url.standardizedFileURL == current {
            let line = coordinator.cursorLine
            let hunks = coordinator.inlineDiff.hunks
            let inFile = forward
                ? hunks.first { $0.newRange.lowerBound > line }
                : hunks.last { $0.newRange.lowerBound < line }
            if inFile != nil {
                coordinator.revealHunk(after: line, forward: forward)
                return
            }
        }
        guard let changes else { return }
        let files = changes.changedFiles.map(\.standardizedFileURL).filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { return }
        let index = current.flatMap { files.firstIndex(of: $0) }
        let target: URL
        if let index {
            target = files[(index + (forward ? 1 : files.count - 1)) % files.count]
        } else {
            target = forward ? files[0] : files[files.count - 1]
        }
        if target == current, let coordinator {
            // The only changed file: wrap around inside it.
            coordinator.revealHunk(after: coordinator.cursorLine, forward: forward)
            return
        }
        let hunks = changes.hunks(for: target)
        let hunk = forward ? hunks.first : hunks.last
        workspace.openFile(target, line: hunk?.newRange.lowerBound ?? 0)
    }

    public func deactivate() {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    /// Formats first when that's on and the server can; a slow server doesn't hold the save up.
    static func formatThenSave(_ document: TextDocument, options: EditorOptions, languages: LanguageIntelligence?, quietly: Bool = false) {
        func save() {
            if quietly { try? document.save() } else { Self.save(document) }
        }
        guard let languages, languages.server(for: document.url) != nil || options.formatsOnSave && languages.canFormat(document.url) else {
            save()
            return
        }
        // As in VS Code: code actions on save (ESLint's fixes, D81), then the formatter; a slow server doesn't hold the save.
        Task {
            let url = document.url
            let work = Task {
                await languages.runSaveActions(url)
                if options.formatsOnSave, languages.canFormat(url) { _ = await languages.format(url) }
            }
            let timeout = Task {
                try? await Task.sleep(for: .seconds(3))
                work.cancel()
            }
            await work.value
            timeout.cancel()
            save()
        }
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
    let languages: LanguageIntelligence?
    let options: EditorOptions
    let ui: UIRegistry
    let commands: CommandRegistry
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
            if let languages, let offer = languages.installOffer(for: url) {
                LanguageInstallBanner(offer: offer, install: { languages.installServer(for: url) }, decline: { languages.declineInstall(for: url) })
            }
            if let changes, !hunks.isEmpty {
                AgentChangesBanner(url: url, hunks: hunks, changes: changes, workspace: workspace)
            }
            if let error = document.loadError {
                VStack(spacing: 12) {
                    EmptyStateView("Can't Open File", systemImage: "doc.questionmark", message: error)
                        .fixedSize(horizontal: false, vertical: true)
                    if document.canReopenWithEncoding {
                        Menu("Reopen with Encoding") {
                            ForEach(TextFile.encodings, id: \.name) { entry in
                                Button(entry.name) { document.reopen(as: entry.encoding) }
                            }
                        }
                            .fixedSize()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let actions = ui.editorActions.filter { $0.isVisible(url) }
                if options.showsBreadcrumbs {
                    PathBar(document: document, workspace: workspace, languages: languages) {
                        EditorActionButtons(actions: actions, commands: commands)
                    }
                }
                CodeEditor(
                    document: document,
                    hunks: hunks,
                    onKeep: { changes?.keep($0, in: url) },
                    onRevert: { changes?.revert($0, in: url) },
                    reveal: workspace.pendingReveal.flatMap { $0.url == url ? ($0.line, $0.column) : nil },
                    onRevealHandled: { workspace.pendingReveal = nil },
                    gitBaseline: gitBaseline,
                    fontSize: Preferences.shared.codeFontSize,
                    wrapsLines: options.wrapsLines,
                    highlightsCurrentLine: options.highlightsCurrentLine,
                    diagnostics: languages?.diagnostics(for: url) ?? [],
                    languages: languages,
                    showsInlayHints: options.showsInlayHints,
                    showsStickyScroll: options.showsStickyScroll,
                    inlayHintsRevision: languages?.inlayHintsRevision(for: url) ?? 0,
                    onOpenLocation: { workspace.open($0) },
                    grammarRevision: GrammarRegistry.shared.revision,
                    workspaceRoot: workspace.root,
                    indentation: EditorIndentation.shared.indentation(for: url),
                    takesFocus: workspace.quietTabID != EditorTab.file(url).id,
                    focusRequest: workspace.editorFocusRequest.flatMap { $0.tabID == EditorTab.file(url).id ? $0.serial : nil },
                    commands: commands,
                    onCaretMove: { workspace.caretMoved(to: EditorLocation(url: url, line: $0, column: $1)) }
                )
                .overlay(alignment: .topTrailing) {
                    // Without the path bar, the actions float over the editor's corner.
                    if !options.showsBreadcrumbs, !actions.isEmpty {
                        EditorActionButtons(actions: actions, commands: commands)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .glassEffect(.regular, in: .capsule)
                            .padding(8)
                    }
                }
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

/// The file's language has no server yet: one click installs it (D57).
struct LanguageInstallBanner: View {
    let offer: LanguageInstallOffer
    let install: () -> Void
    let decline: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: offer.failure == nil ? "sparkles" : "exclamationmark.triangle.fill")
                .foregroundStyle(offer.failure == nil ? Theme.accent : .orange)
            if offer.isInstalling {
                Text("Installing \(offer.name) support…")
                    .font(.callout.weight(.medium))
                ProgressView().controlSize(.small)
                Spacer()
            } else if let failure = offer.failure {
                Text("Couldn't install \(offer.name) support")
                    .font(.callout.weight(.medium))
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(failure)
                Spacer()
                Button("Not Now", action: decline)
                    .buttonStyle(.glass)
                Button("Try Again", action: install)
                    .buttonStyle(.glassProminent)
            } else {
                Text("\(offer.name) support isn't installed")
                    .font(.callout.weight(.medium))
                Text(details)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Not Now", action: decline)
                    .buttonStyle(.glass)
                    .help("Don't offer this again; Settings → Languages still installs it")
                Button("Install", action: install)
                    .buttonStyle(.glassProminent)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.accent.opacity(offer.failure == nil ? 0.08 : 0))
        .background(.orange.opacity(offer.failure == nil ? 0 : 0.08))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var details: String {
        let what = offer.purpose ?? "Errors, completion and go to definition need its language server."
        return offer.needs.map { "\(what) Needs \($0)." } ?? what
    }
}

struct AgentChangesBanner: View {
    let url: URL
    let hunks: [DiffHunk]
    let changes: ChangeTracking
    let workspace: Workspace

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
                    EditorPlugin.revealChange(forward: false, workspace: workspace, changes: changes)
                }
                IconButton("chevron.down", help: "Next change, then the next file (⌥⌘↓)") {
                    EditorPlugin.revealChange(forward: true, workspace: workspace, changes: changes)
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

/// Buttons other plugins add for a file (`EditorAction`), e.g. Markdown's preview.
struct EditorActionButtons: View {
    let actions: [EditorAction]
    let commands: CommandRegistry

    var body: some View {
        HStack(spacing: 2) {
            ForEach(actions) { action in
                Button {
                    commands.run(action.commandID, teaching: true)
                } label: {
                    Image(systemName: action.systemImage)
                        .font(.system(size: 12))
                        .frame(width: 22, height: 20)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(commands.help(action.commandID))
            }
        }
    }
}
