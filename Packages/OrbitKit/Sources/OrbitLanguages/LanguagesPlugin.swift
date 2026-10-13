import OrbitAPI
import OrbitUI
import SwiftUI

/// Language servers (LSP) for errors, hover and go-to-definition (D54).
public final class LanguagesPlugin: OrbitPlugin {
    public static let manifest = PluginManifest(
        id: "orbit.languages",
        name: "Languages",
        summary: "Errors, hover and go to definition from language servers (Swift, TypeScript).",
        systemImage: "curlybraces"
    )

    private var manager: LanguageManager?

    public init() {}

    public func activate(_ context: PluginContext) {
        let workspace = context.workspace
        let manager = LanguageManager(workspace: workspace)
        self.manager = manager
        context.services.register(LanguageIntelligence.self, manager)

        context.ui.addStatusItem(StatusItem(
            id: "languages.status", placement: .trailing, order: 10,
            isVisible: { Self.activeFile(workspace).flatMap(manager.server(for:)) != nil }
        ) {
            LanguageStatus(manager: manager, workspace: workspace, commands: context.commands)
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

    var body: some View {
        if let url = LanguagesPlugin.activeFile(workspace), let server = manager.server(for: url) {
            let diagnostics = manager.diagnostics(for: url)
            let errors = diagnostics.count { $0.severity == .error }
            let warnings = diagnostics.count { $0.severity == .warning }
            Button {
                commands.run("editor.nextProblem")
            } label: {
                HStack(spacing: 8) {
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
                .labelStyle(.titleAndIcon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(help(server.state, errors: errors, warnings: warnings))
        }
    }

    private func help(_ state: LanguageServerState, errors: Int, warnings: Int) -> String {
        switch state {
        case .starting: "Starting the language server…"
        case .running: errors + warnings == 0 ? "No problems in this file" : "Go to the next problem (⌘')"
        case .failed(let message), .unavailable(let message): message
        }
    }
}
