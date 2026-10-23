import AppKit
import OrbitAPI
import OrbitUI
import SwiftUI

/// Language servers (LSP) for errors, hover and go-to-definition (D54).
public final class LanguagesPlugin: OrbitPlugin {
    public static let manifest = PluginManifest(
        id: "orbit.languages",
        name: "Languages",
        summary: "Errors, completion, hover and go to definition from language servers; installs them from the Mason registry.",
        systemImage: "curlybraces",
        tint: .purple
    )

    private var manager: LanguageManager?

    public init() {}

    public func activate(_ context: PluginContext) {
        let workspace = context.workspace
        let manager = LanguageManager(workspace: workspace)
        self.manager = manager
        context.services.register(LanguageIntelligence.self, manager)
        let services = context.services
        manager.editing = { services.resolve(SourceEditing.self) }
        manager.changes = { services.resolve(ChangeTracking.self) }
        manager.tasks = { services.resolve(TaskProblems.self) }
        manager.projectFiles = { services.resolve(ProjectFileIndex.self) }
        Self.followExtensionServers(lifetime: context.lifetime, workspace: context.workspace, manager: manager)

        context.ui.addStatusItem(StatusItem(
            id: "languages.status", placement: .trailing, order: 10,
            isVisible: { Self.activeFile(workspace).map { manager.server(for: $0) != nil || manager.turnedOff($0) != nil } ?? false }
        ) {
            LanguageStatus(
                manager: manager, workspace: workspace, commands: context.commands, ui: context.ui,
                agent: { [services = context.services] in services.resolve(AgentTasks.self) }
            )
        })

        context.ui.addExtensionSource(LanguageExtensionSource(manager: manager))
        context.ui.addSettingsPane(SettingsPane(
            id: "languages", title: "Languages", systemImage: "curlybraces", tint: .purple, group: .code, order: 10,
            summary: "Language servers for completion, errors, hover and go to definition.",
            keywords: ["lsp", "language server", "install", "mason", "python", "rust", "go", "typescript", "swift", "completion", "errors", "restart"],
            items: {
                // Servers by the languages they serve, so "python" finds Pyright.
                LanguagesSettingsPane.ready(manager).map {
                    SettingsItem($0.id, $0.name, keywords: Array(Set($0.languages.values)).sorted())
                } + [
                    SettingsItem("notInstalled", "Not installed servers", keywords: ["install", "mason", "missing"]),
                    SettingsItem("restart", "Restart Servers", keywords: ["running servers", "restart"]),
                ]
            }
        ) {
            LanguagesSettingsPane(manager: manager, ui: context.ui)
        })
        context.ui.addSettingsPane(SettingsPane(
            id: "formatting", title: "Formatting", systemImage: "wand.and.sparkles", tint: .teal, group: .code, order: 20,
            summary: "Which formatter each file type in this project uses.",
            keywords: ["format", "formatter", "prettier", "biome", "ruff", "black", "editorconfig", "indent"],
            items: { [
                SettingsItem("projectFormatters", "Project formatters", keywords: ["custom formatter", ".orbit/settings.json"]),
                SettingsItem("globalFormatters", "Global formatters", keywords: ["custom formatter", "~/.orbit/settings.json"]),
            ] }
        ) {
            FormattingSettingsPane(manager: manager)
        })

        let ui = context.ui
        ui.addBottomPanel(PanelContribution(id: "problems", title: "Problems", systemImage: "exclamationmark.triangle", order: 50, badge: {
            // Errors when there are any, else warnings.
            let severities = manager.problems.flatMap { $0.diagnostics.map(\.severity) }
            let errors = severities.count { $0 == .error }, warnings = severities.count { $0 == .warning }
            if errors > 0 { return PanelBadge(errors, style: .error) }
            return warnings > 0 ? PanelBadge(warnings, style: .warning) : nil
        }) {
            ProblemsPanel(manager: manager, workspace: workspace, fix: services.resolve(AgentTasks.self).map { agent in
                { files in _ = agent.draftTask(ProblemPrompt.text(for: files, root: workspace.root) { url in
                    workspace.documents.existingDocument(for: url)?.text ?? (try? String(contentsOf: url, encoding: .utf8))
                }) }
            })
        }.command("languages.problems"))
        context.commands.register(OrbitCommand(
            id: "languages.problems",
            title: "Show Problems",
            category: "Code",
            systemImage: "exclamationmark.triangle",
            shortcut: KeyboardShortcut("m", modifiers: [.command, .shift])
        ) {
            if ui.isBottomPanelVisible, ui.selectedBottomPanel == "problems" {
                ui.isBottomPanelVisible = false
            } else {
                ui.selectedBottomPanel = "problems"
                ui.isBottomPanelVisible = true
            }
        })

        registerNavigation(context, manager: manager)

        context.commands.register(OrbitCommand(
            id: "languages.restart",
            title: "Restart Language Servers",
            category: "Languages",
            systemImage: "arrow.clockwise"
        ) {
            manager.restart()
        })
        #if DEBUG
        LanguagesStress.register(context)
        #endif
    }

    public func deactivate() {
        manager?.shutdown()
    }

    /// Servers from extensions (D195), read again when extensions change;
    /// running servers restart when the list did, so files get the new one.
    private static func followExtensionServers(lifetime: PluginLifetime, workspace: Workspace, manager: LanguageManager) {
        let servers = Extensions.shared.languageServerFiles.flatMap { file in
            (try? Data(contentsOf: file.url)).flatMap {
                try? ExtensionServers.parse($0, folder: file.url.deletingLastPathComponent(), extensionName: file.extensionName)
            } ?? []
        }
        if servers != ExtensionServers.current {
            ExtensionServers.set(servers)
            manager.restart()
        }
        // Weakly: `Extensions` outlives the window and keeps this until it next reloads.
        // The host holds the lifetime while the plugin is on.
        withObservationTracking {
            _ = Extensions.shared.revision
        } onChange: { [weak lifetime, weak workspace, weak manager] in
            Task { @MainActor in
                guard let lifetime, let workspace, let manager, lifetime.isActive, !workspace.isClosed else { return }
                followExtensionServers(lifetime: lifetime, workspace: workspace, manager: manager)
            }
        }
    }

    /// Find References, Go to Symbol in File / Project (D62). Always enabled,
    /// like the other Code commands (D59): without a server they beep.
    private func registerNavigation(_ context: PluginContext, manager: LanguageManager) {
        let workspace = context.workspace
        let services = context.services
        let ui = context.ui
        let references = ReferencesModel()
        func caret() -> SourceLocation? {
            guard let caret = services.resolve(EditorSelectionProviding.self)?.caret,
                  caret.url.standardizedFileURL == Self.activeFile(workspace)?.standardizedFileURL else { return nil }
            return caret
        }

        manager.showLocations = { origin, locations in
            references.show(locations, origin: origin, workspace: workspace)
            ui.revealBottomPanel("references")
        }
        manager.runInTerminal = { request in
            guard let terminals = services.resolve(AgentTerminalHosting.self) else { return false }
            terminals.run(request).reveal()
            return true
        }
        ui.addBottomPanel(PanelContribution(id: "references", title: "References", systemImage: "link", order: 55, badge: {
            references.count > 0 ? PanelBadge(references.count) : nil
        }) {
            ReferencesPanel(model: references, workspace: workspace)
        })
        // ⇧⌘R, beside ⇧⌘O (symbols) and ⇧⌘A (actions); was Xcode's four-key ⌃⇧⌘F (D67).
        context.commands.register(OrbitCommand(
            id: "languages.findReferences",
            title: "Find References",
            category: "Code",
            systemImage: "link",
            shortcut: KeyboardShortcut("r", modifiers: [.command, .shift]),
            editorMenu: EditorMenuPlacement(.navigate) {
                Self.activeFile(workspace).map { manager.server(for: $0) != nil } ?? false
            }
        ) {
            guard let caret = caret() else {
                NSSound.beep()
                return
            }
            references.find(at: caret, languages: manager, workspace: workspace)
            ui.revealBottomPanel("references")
        })
        context.commands.register(OrbitCommand(
            id: "languages.peekReferences",
            title: "Peek References…",
            category: "Code",
            systemImage: "list.bullet.below.rectangle",
            shortcut: KeyboardShortcut("r", modifiers: [.command, .option, .shift]),
            editorMenu: EditorMenuPlacement(.navigate) {
                Self.activeFile(workspace).map { manager.server(for: $0) != nil } ?? false
            }
        ) {
            guard let caret = caret() else {
                NSSound.beep()
                return
            }
            SymbolPicks.peekReferences(caret, languages: manager, workspace: workspace, ui: ui)
        })
        let hierarchy = HierarchyModel()
        ui.addBottomPanel(PanelContribution(id: "hierarchy", title: "Hierarchy", systemImage: "list.bullet.indent", order: 56) {
            HierarchyPanel(model: hierarchy, workspace: workspace)
        })
        // Xcode's Find Call Hierarchy key.
        for (kind, id, title, shortcut) in [
            (HierarchyKind.calls, "languages.callHierarchy", "Show Call Hierarchy", KeyboardShortcut("h", modifiers: [.command, .control, .shift]) as KeyboardShortcut?),
            (HierarchyKind.types, "languages.typeHierarchy", "Show Type Hierarchy", nil),
        ] {
            context.commands.register(OrbitCommand(
                id: id,
                title: title,
                category: "Code",
                systemImage: kind == .calls ? "arrow.triangle.branch" : "square.stack.3d.up",
                shortcut: shortcut,
                editorMenu: EditorMenuPlacement(.navigate) {
                    Self.activeFile(workspace).map { manager.server(for: $0) != nil } ?? false
                }
            ) {
                guard let caret = caret() else {
                    NSSound.beep()
                    return
                }
                hierarchy.show(kind, at: caret, languages: manager)
                ui.revealBottomPanel("hierarchy")
            })
        }
        context.commands.register(OrbitCommand(
            id: "languages.fileSymbols",
            title: "Go to Symbol in File…",
            category: "Code",
            systemImage: "list.bullet.indent",
            shortcut: KeyboardShortcut("o", modifiers: [.command, .shift])
        ) {
            guard let caret = caret() else {
                NSSound.beep()
                return
            }
            SymbolPicks.fileSymbols(caret, languages: manager, workspace: workspace, ui: ui)
        })
        context.commands.register(OrbitCommand(
            id: "languages.projectSymbols",
            title: "Go to Symbol in Project…",
            category: "Code",
            systemImage: "magnifyingglass",
            shortcut: KeyboardShortcut("t", modifiers: .command)
        ) {
            SymbolPicks.projectSymbols(languages: manager, workspace: workspace, ui: ui)
        })
    }

    static func activeFile(_ workspace: Workspace) -> URL? {
        guard let tab = workspace.activeTab, tab.kind == EditorTab.fileKind else { return nil }
        return tab.url
    }
}

/// The active file's server and its problem counts; a click goes to the next problem.
struct LanguageStatus: View {
    let manager: LanguageManager
    let workspace: Workspace
    let commands: CommandRegistry
    let ui: UIRegistry
    let agent: () -> AgentTasks?

    var body: some View {
        if let url = LanguagesPlugin.activeFile(workspace), let language = manager.turnedOff(url) {
            let inSettings = manager.turnedOffInSettings(url)
            Button {
                if inSettings { ui.showSettings("languages") } else { manager.editServerSettings() }
            } label: {
                Text("\(language) off")
                    .orbitFont(.caption)
                    .foregroundStyle(.tertiary)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(inSettings ? "\(language) is turned off in Settings → Languages" : "The language server is turned off for these files in .orbit/settings.json")
            .contextMenu { serverMenu(url) }
        } else if let url = LanguagesPlugin.activeFile(workspace), let server = manager.server(for: url) {
            let diagnostics = manager.diagnostics(for: url)
            let errors = diagnostics.count { $0.severity == .error }
            let warnings = diagnostics.count { $0.severity == .warning }
            let config = manager.config(for: url)
            let installing = config.map { manager.installing.contains($0.id) } ?? false
            let failure = config.flatMap { manager.installFailures[$0.id] }
            let canInstall = config?.install != nil && Self.isUnavailable(server.state)
            Button {
                if canInstall, let config {
                    if let failure {
                        explainInstallFailure(server.name, failure, config: config, url: url)
                    } else if !installing {
                        Task { await manager.install(config.id) }
                    }
                    return
                }
                switch server.state {
                case .failed(let message), .unavailable(let message):
                    explain(server.name, message, url: url)
                default:
                    commands.run("languages.problems", teaching: true)
                }
            } label: {
                HStack(spacing: 6) {
                    if canInstall {
                        if installing {
                            ProgressView().controlSize(.mini)
                            Text("Installing \(server.name)…")
                        } else if failure != nil {
                            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                            Text("\(server.name) install failed")
                        } else {
                            Image(systemName: "arrow.down.circle")
                            Text("Install \(server.name) Support")
                        }
                    } else {
                        stateLabel(server, errors: errors, warnings: warnings)
                        // ESLint, Tailwind beside it (D64); dimmed while not running.
                        ForEach(manager.companions(for: url), id: \.name) { companion in
                            Text("· \(companion.name)")
                                .opacity(companion.state == .running ? 1 : 0.5)
                        }
                    }
                }
                .labelStyle(TightLabelStyle())
                .orbitFont(.caption)
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(canInstall ? "Download its language server from the Mason registry" : help(server.state, errors: errors, warnings: warnings) + companionNotes(url))
            .contextMenu { serverMenu(url) }
        }
    }

    /// Another server for this file type (D65), saved in ~/.orbit/settings.json.
    @ViewBuilder
    private func serverMenu(_ url: URL) -> some View {
        let current = manager.config(for: url)?.id
        let chosen = manager.chosenInSettings(url)
        let type = url.pathExtension.isEmpty ? url.lastPathComponent : ".\(url.pathExtension)"
        Section("Language Server for \(type) Files") {
            ForEach(manager.alternatives(for: url), id: \.id) { option in
                Toggle(option.title, isOn: Binding(get: { current == option.id }, set: { _ in choose(option.id, url) }))
            }
            Toggle("None", isOn: Binding(get: { chosen == "off" }, set: { _ in choose("off", url) }))
        }
        if chosen != nil {
            Button("Use Orbit's Choice") { choose(nil, url) }
        }
        Divider()
        Button("Edit Settings File…") { manager.editServerSettings() }
    }

    private func choose(_ id: String?, _ url: URL) {
        guard let failure = manager.chooseServer(id, for: url) else { return }
        let alert = NSAlert()
        alert.messageText = "Couldn't save the choice"
        alert.informativeText = failure
        alert.runSheetModal()
    }

    private static func isUnavailable(_ state: LanguageServerState) -> Bool {
        if case .unavailable = state { return true }
        return false
    }

    /// Matches the bottom-panel buttons beside it (3 pt between icon and count).
    private struct TightLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 3) {
                configuration.icon
                configuration.title.monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private func stateLabel(_ server: (name: String, state: LanguageServerState), errors: Int, warnings: Int) -> some View {
        switch server.state {
        case .starting:
            ProgressView().controlSize(.mini)
            Text(server.name)
        case .running:
            if errors == 0, warnings == 0 {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
            if errors > 0 {
                Label("\(errors)", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            }
            if warnings > 0 {
                Label("\(warnings)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Text(server.name)
        case .failed, .unavailable:
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.secondary)
            Text(server.name)
        }
    }

    private func explainInstallFailure(_ name: String, _ message: String, config: LanguageServerConfig, url: URL) {
        let alert = NSAlert()
        alert.messageText = "Couldn't install the \(name) language server"
        alert.informativeText = message
        alert.addButton(withTitle: "Try Again")
        alert.addButton(withTitle: "Open Settings")
        let agent = agent()
        if agent != nil { alert.addButton(withTitle: "Ask Agent to Set Up") }
        alert.addButton(withTitle: "Cancel")
        switch alert.runSheetModal() {
        case .alertFirstButtonReturn: Task { await manager.install(config.id) }
        case .alertSecondButtonReturn: ui.showSettings("languages")
        case .alertThirdButtonReturn where agent != nil:
            _ = agent?.draftTask(manager.setUpPrompt(for: url, problem: "Installing it failed: \(message)"))
        default: break
        }
    }

    /// Why the server isn't running, with a way to try again.
    /// Why the server isn't running, with a way to try again or to have the agent set it up (D65).
    private func explain(_ name: String, _ message: String, url: URL) {
        let alert = NSAlert()
        alert.messageText = "The \(name) language server isn't running"
        alert.informativeText = message
        alert.addButton(withTitle: "Restart")
        let agent = agent()
        if agent != nil { alert.addButton(withTitle: "Ask Agent to Set Up") }
        alert.addButton(withTitle: "OK")
        switch alert.runSheetModal() {
        case .alertFirstButtonReturn: commands.run("languages.restart")
        case .alertSecondButtonReturn where agent != nil: _ = agent?.draftTask(manager.setUpPrompt(for: url, problem: message))
        default: break
        }
    }

    /// Why ESLint or Tailwind isn't running, when it isn't.
    private func companionNotes(_ url: URL) -> String {
        manager.companions(for: url).compactMap { companion in
            switch companion.state {
            case .failed(let message), .unavailable(let message): "\n\(companion.name): \(message)"
            default: nil
            }
        }.joined()
    }

    private func help(_ state: LanguageServerState, errors: Int, warnings: Int) -> String {
        switch state {
        case .starting: "Starting the language server…"
        case .running: (errors + warnings == 0 ? "No problems in this file" : "Problems in this file") + ". Click to show the Problems panel (⇧⌘M)"
        case .failed(let message), .unavailable(let message): message
        }
    }
}
