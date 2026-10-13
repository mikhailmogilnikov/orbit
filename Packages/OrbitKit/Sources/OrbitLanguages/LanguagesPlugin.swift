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
        systemImage: "curlybraces"
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

        context.ui.addStatusItem(StatusItem(
            id: "languages.status", placement: .trailing, order: 10,
            isVisible: { Self.activeFile(workspace).flatMap(manager.server(for:)) != nil }
        ) {
            LanguageStatus(manager: manager, workspace: workspace, commands: context.commands, ui: context.ui)
        })

        context.ui.addSettingsPane(SettingsPane(
            id: "languages", title: "Languages", systemImage: "curlybraces", order: 15,
            keywords: ["lsp", "language server", "install", "mason", "python", "rust", "go", "completion", "errors"]
        ) {
            LanguagesSettingsPane(manager: manager)
        })

        let ui = context.ui
        ui.addBottomPanel(PanelContribution(id: "problems", title: "Problems", systemImage: "exclamationmark.triangle", order: 50) {
            ProblemsPanel(manager: manager, workspace: workspace)
        })
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

        context.commands.register(OrbitCommand(
            id: "languages.restart",
            title: "Restart Language Servers",
            category: "Languages",
            systemImage: "arrow.clockwise"
        ) {
            manager.restart()
        })
    }

    public func deactivate() {
        manager?.shutdown()
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

    var body: some View {
        if let url = LanguagesPlugin.activeFile(workspace), let server = manager.server(for: url) {
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
                        explainInstallFailure(server.name, failure, config: config)
                    } else if !installing {
                        Task { await manager.install(config.id) }
                    }
                    return
                }
                switch server.state {
                case .failed(let message), .unavailable(let message):
                    explain(server.name, message)
                default:
                    commands.run("editor.nextProblem")
                }
            } label: {
                HStack(spacing: 8) {
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
                    }
                }
                .labelStyle(.titleAndIcon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(canInstall ? "Download its language server from the Mason registry" : help(server.state, errors: errors, warnings: warnings))
        }
    }

    private static func isUnavailable(_ state: LanguageServerState) -> Bool {
        if case .unavailable = state { return true }
        return false
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

    private func explainInstallFailure(_ name: String, _ message: String, config: LanguageServerConfig) {
        let alert = NSAlert()
        alert.messageText = "Couldn't install the \(name) language server"
        alert.informativeText = message
        alert.addButton(withTitle: "Try Again")
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: Task { await manager.install(config.id) }
        case .alertSecondButtonReturn: ui.showSettings("languages")
        default: break
        }
    }

    /// Why the server isn't running, with a way to try again.
    private func explain(_ name: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = "The \(name) language server isn't running"
        alert.informativeText = message
        alert.addButton(withTitle: "Restart")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn { commands.run("languages.restart") }
    }

    private func help(_ state: LanguageServerState, errors: Int, warnings: Int) -> String {
        switch state {
        case .starting: "Starting the language server…"
        case .running: errors + warnings == 0 ? "No problems in this file" : "Go to the next problem (⌘')"
        case .failed(let message), .unavailable(let message): message
        }
    }
}
