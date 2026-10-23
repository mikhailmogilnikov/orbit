import AppKit
import OrbitAPI
import OrbitUI
import SwiftUI

/// GitLens's everyday features on top of Source Control (D194): who changed
/// a line (after it in the editor, in the status bar), a file's and a line
/// range's history, comparing with a branch or commit, links to the line on
/// the web host. Its own plugin in Source Control's module: it shares the
/// `GitModel` that plugin registers, and is off whenever Source Control is.
public final class GitLensPlugin: OrbitPlugin {
    public static let manifest = PluginManifest(
        id: "orbit.gitlens",
        name: "Git Lens",
        summary: "Blame in the editor and the status bar, file and line history, compare with a branch, GitHub links.",
        systemImage: "person.text.rectangle",
        tint: .orange,
        requires: [GitPlugin.manifest.id]
    )

    public init() {}

    public func activate(_ context: PluginContext) {
        guard let model = context.services.resolve(GitModel.self) else { return }
        let workspace = context.workspace
        let ui = context.ui
        let services = context.services
        // The editor draws the caret line's blame when this is there (D187).
        context.services.register(LineBlaming.self, model)

        ui.addSettingsPane(SettingsPane(
            id: "gitlens", title: "Git Lens", systemImage: "person.text.rectangle", tint: .orange, group: .code, order: 31,
            summary: "Who changed what, and when, while you read the code.",
            keywords: ["git", "blame", "gitlens", "author", "history", "status bar"],
            items: { [
                SettingsItem("statusBlame", "Blame for the current line", keywords: ["status bar", "git blame", "author"]),
            ] }
        ) {
            GitLensSettingsPane(model: model)
        })

        let isReady: @MainActor () -> Bool = { model.state == .ready && !model.isBusy }
        let activeFile: @MainActor () -> URL? = {
            guard model.state == .ready, let url = workspace.activeTab?.url, model.repositoryPath(of: url) != nil else { return nil }
            return url
        }
        context.commands.register(OrbitCommand(
            id: "git.fileHistory", title: "Show File History", category: "Git", systemImage: "clock.arrow.circlepath",
            isEnabled: { activeFile() != nil }
        ) {
            guard let url = activeFile() else { return }
            model.showHistory(of: url)
            ui.revealSidebarPanel("git")
        })
        context.commands.register(OrbitCommand(
            id: "git.lineHistory", title: "Show Line History", category: "Git", systemImage: "text.line.first.and.arrowtriangle.forward",
            isEnabled: { activeFile() != nil }
        ) {
            guard let url = activeFile() else { return }
            let editor = services.resolve(EditorSelectionProviding.self)
            let lines = editor?.selection.flatMap { $0.url.standardizedFileURL == url.standardizedFileURL ? $0.lines : nil }
                ?? editor?.caret.map { ($0.range.start.line + 1)...($0.range.start.line + 1) }
            model.showHistory(of: url, lines: lines)
            ui.revealSidebarPanel("git")
        })
        context.commands.register(OrbitCommand(
            id: "git.compareWith", title: "Compare File with…", category: "Git", systemImage: "arrow.left.arrow.right",
            isEnabled: { activeFile() != nil }
        ) {
            guard let url = activeFile() else { return }
            Task {
                let targets = await model.compareTargets(for: url)
                ui.presentQuickPick(QuickPick(id: "git.compare", placeholder: "Compare \(url.lastPathComponent) with a branch or commit") { query in
                    Self.compareItems(targets, query: query) { model.compare(url, with: $0) }
                })
            }
        })
        registerRemoteLinks(context, model: model, isReady: isReady)

        ui.addStatusItem(StatusItem(
            id: "git.blame", placement: .trailing, order: 50,
            isVisible: {
                guard model.showsBlame, model.state == .ready, model.status.hasCommits,
                      let cursor = services.resolve(EditorSelectionProviding.self)?.cursor else { return false }
                return cursor.url == workspace.activeTab?.url && model.status(of: cursor.url) != .untracked
            }
        ) {
            if let editor = services.resolve(EditorSelectionProviding.self) {
                BlameStatus(model: model, editor: editor, workspace: workspace)
            }
        })
        #if DEBUG
        GitStress.registerLens(context)
        #endif
    }

    /// Branches and commits matching the query, best first.
    @MainActor
    private static func compareItems(
        _ targets: [(title: String, detail: String, revision: String)], query: String, open: @escaping @MainActor (String) -> Void
    ) -> [QuickPickItem] {
        var found: [(target: (title: String, detail: String, revision: String), match: FuzzyMatch.Result)] = []
        for target in targets {
            if let match = FuzzyMatch.match(query, in: target.title) {
                found.append((target, match))
            } else if let match = FuzzyMatch.match(query, in: target.detail) {
                found.append((target, FuzzyMatch.Result(score: match.score - 5, positions: [])))
            }
        }
        if !query.isEmpty { found.sort { $0.match.score > $1.match.score } }
        return found.map { entry in
            let revision = entry.target.revision
            return QuickPickItem(
                id: revision,
                title: FuzzyMatch.highlighted(entry.target.title, positions: entry.match.positions),
                subtitle: entry.target.detail,
                systemImage: entry.target.detail == "Branch" ? "arrow.triangle.branch" : "clock"
            ) { open(revision) }
        }
    }

    /// Copy GitHub Link / Open on GitHub for the selected lines (D150).
    private func registerRemoteLinks(_ context: PluginContext, model: GitModel, isReady: @escaping @MainActor () -> Bool) {
        let services = context.services
        let workspace = context.workspace
        func target() -> (url: URL, lines: ClosedRange<Int>?)? {
            guard let url = workspace.activeTab?.url, workspace.activeTab?.kind == EditorTab.fileKind else { return nil }
            let editor = services.resolve(EditorSelectionProviding.self)
            if let selection = editor?.selection, selection.url == url { return (url, selection.lines) }
            if let cursor = editor?.cursor, cursor.url == url { return (url, (cursor.line + 1)...(cursor.line + 1)) }
            return (url, nil)
        }
        func link(_ use: @escaping @MainActor (URL) -> Void) {
            guard let target = target() else { return NSSound.beep() }
            Task {
                guard let url = await model.remoteLink(for: target.url, lines: target.lines) else {
                    let alert = NSAlert()
                    alert.messageText = "No link for this file"
                    alert.informativeText = "The repository has no remote on a web host, or the file isn't in it."
                    alert.runSheetModal()
                    return
                }
                use(url)
            }
        }
        let available: @MainActor () -> Bool = { isReady() && workspace.activeTab?.kind == EditorTab.fileKind }
        context.commands.register(OrbitCommand(
            id: "git.copyRemoteLink", title: "Copy GitHub Link", category: "Git", systemImage: "link",
            isEnabled: available, editorMenu: EditorMenuPlacement(.navigate, isVisible: available)
        ) {
            link { url in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        })
        context.commands.register(OrbitCommand(
            id: "git.openRemote", title: "Open on GitHub", category: "Git", systemImage: "safari",
            isEnabled: available, editorMenu: EditorMenuPlacement(.navigate, isVisible: available)
        ) {
            link { NSWorkspace.shared.open($0) }
        })
    }
}

struct GitLensSettingsPane: View {
    @Bindable var model: GitModel

    var body: some View {
        SettingsForm {
            Section {
                Toggle(isOn: $model.showsBlame) {
                    Text("Blame for the current line")
                    Text("Who last changed the line with the caret, and when.")
                }
                .settingsItem("statusBlame")
            } header: {
                Text("Status Bar")
            } footer: {
                Text("Blame after the caret's line, in the editor, is in Editor. Show File History, Show Line History and Compare File with… are in the Git menu.")
            }
        }
    }
}
