import OrbitKit
import SwiftUI

/// Where each built-in command sits in the menu bar (D176): menus named like
/// Xcode's, each split into sections of related commands, long families
/// (line edits, case transforms, carets, folding) in submenus. A command not
/// listed here still gets an item: at the end of the menu its category maps
/// to, or in Plugins for a category of its own.
enum MenuLayout {
    enum Item {
        case command(String)
        case submenu(String, [String])
        /// Every command whose id starts with this, in registration order.
        case commands(prefix: String)
        case openRecent
        case commandPalette
    }

    typealias Section = [Item]

    static let file: [Section] = [
        [.command("shell.newWindow"), .command("explorer.newFile"), .command("explorer.newFolder")],
        [.command("workspace.openFolder"), .openRecent, .command("search.quickOpen")],
        [.command("editor.closeTab"), .command("workspace.closeFolder")],
        [.command("editor.save"), .command("editor.saveAll")],
        [.command("file.revealInFinder"), .command("file.copyPath"), .command("file.copyRelativePath")],
        [.command("editor.openProjectSettings")],
    ]

    static let view: [Section] = [
        [.commandPalette],
        [.command("shell.toggleSidebar"), .command("explorer.show"), .command("git.show"), .command("explorer.refresh")],
        [.command("shell.toggleAgents"), .command("agents.overview")],
        [.command("languages.problems"), .command("terminal.toggle")],
        [.command("shell.splitEditor"), .command("shell.joinEditors"), .command("shell.moveTabToOtherSide"),
         .command("shell.focusOtherSide"), .command("shell.focusSecondSide"), .command("shell.focusEditor")],
        [.command("preview.markdown"), .command("preview.browser")],
        [.command("editor.toggleInlayHints"), .command("editor.toggleBlame")],
        [.command("editor.zoomIn"), .command("editor.zoomOut"), .command("editor.zoomReset")],
        [.command("shell.selectTheme")],
    ]

    static let find: [Section] = [
        [.command("search.findInProject")],
        [.command("languages.findReferences"), .command("languages.peekReferences")],
        [.command("terminal.find")],
    ]

    static let navigate: [Section] = [
        [.command("shell.goBack"), .command("shell.goForward")],
        [.command("shell.nextTab"), .command("shell.previousTab"), .command("shell.recentTab"), .command("shell.reopenClosedTab")],
        [.command("editor.goToDefinition"), .command("languages.fileSymbols"), .command("languages.projectSymbols"), .command("editor.goToLine")],
        [.command("editor.nextProblem")],
    ]

    static let editor: [Section] = [
        [.command("editor.codeActions"), .command("editor.rename"), .command("editor.organizeImports")],
        [.command("editor.format"), .command("editor.formatSelection")],
        [.command("editor.insertSnippet"), .command("editor.toggleComment"),
         .submenu("Lines", ["editor.moveLineUp", "editor.moveLineDown", "editor.copyLineUp", "editor.copyLineDown",
                            "editor.sortLinesAscending", "editor.sortLinesDescending", "editor.removeDuplicateLines", "editor.reverseLines"]),
         .submenu("Transform", TextTransformIDs.all),
         .submenu("Selection", ["editor.addNextOccurrence", "editor.selectAllOccurrences", "editor.addCaretAbove", "editor.addCaretBelow"]),
         .submenu("Folding", ["editor.fold", "editor.unfold", "editor.foldAll", "editor.unfoldAll"])],
        [.command("languages.restart")],
    ]

    static let agent: [Section] = [
        [.command("agents.new"), .command("agents.newIsolated"), .commands(prefix: "agents.new.")],
        [.command("agents.focus"), .command("editor.inlineEdit"), .command("agents.stop")],
        [.command("review.acceptAll"), .command("review.rejectAll")],
        [.command("editor.nextChange"), .command("editor.previousChange"), .command("editor.keepChange"), .command("editor.undoChange")],
        [.command("editor.commentChange"), .command("agents.sendReviewComments")],
    ]

    static let sourceControl: [Section] = [
        [.command("git.commit"), .command("git.generateMessage")],
        [.command("git.pull"), .command("git.push"), .command("git.fetch")],
        [.command("git.stash"), .command("git.stashPop")],
        [.command("git.fileHistory"), .command("git.lineHistory"), .command("git.compareWith")],
        [.command("git.openRemote"), .command("git.copyRemoteLink")],
    ]

    static let terminal: [Section] = [
        [.command("terminal.new"), .command("terminal.kill")],
        [.command("tasks.run"), .command("tasks.runLast")],
    ]

    static let help: [Section] = [
        [.command("shell.shortcuts")],
    ]

    /// Which menu takes a command the layout doesn't list, by its category.
    static let menuForCategory: [String: String] = [
        "File": "File", "View": "View", "Appearance": "View", "Code": "Editor", "Languages": "Editor",
        "Agents": "Agent", "Review": "Agent", "Git": "Source Control", "Terminal": "Terminal", "Help": "Help",
        // Debug builds' own tools, at the end of Help.
        "Debug": "Help",
    ]

    /// Every id the layout places, so the rest can be found.
    static let placed: Set<String> = {
        var ids: Set<String> = []
        for menu in [file, view, find, navigate, editor, agent, sourceControl, terminal, help] {
            for section in menu {
                for item in section {
                    switch item {
                    case .command(let id): ids.insert(id)
                    case .submenu(_, let members): ids.formUnion(members)
                    case .commands, .openRecent, .commandPalette: break
                    }
                }
            }
        }
        return ids
    }()

    static let prefixes: [String] = [file, view, find, navigate, editor, agent, sourceControl, terminal, help]
        .flatMap { $0.flatMap { $0 } }
        .compactMap { if case .commands(let prefix) = $0 { prefix } else { nil } }

    static func isPlaced(_ command: OrbitCommand) -> Bool {
        placed.contains(command.id) || prefixes.contains { command.id.hasPrefix($0) }
    }
}

/// The case transforms' ids (`editor.case.*`), in the editor's order.
enum TextTransformIDs {
    static let all = ["upper", "lower", "title", "camel", "pascal", "snake", "kebab", "constant"].map { "editor.case.\($0)" }
}

/// Menus are generated from the command registry and `MenuLayout`, so plugin
/// commands get real menu items and shortcuts for free.
struct OrbitMenus: Commands {
    /// The main window's (D101): menus and their shortcuts act on it.
    private var host: PluginHost? { ProjectWindows.shared.activeHost }
    private var all: [OrbitCommand] { host?.commands.all ?? [] }
    private var pluginCommands: [OrbitCommand] {
        all.filter { !MenuLayout.isPlaced($0) && MenuLayout.menuForCategory[$0.category] == nil }
    }

    var body: some Commands {
        // Settings open inside the main window (see SettingsScreen), not as a separate one.
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Updater.shared.checkForUpdates() }
                .disabled(!Updater.isEnabled)
            Button("Install 'orbit' Command…") { CommandLineTool.install() }
                .help("Adds `orbit` to /usr/local/bin: `orbit .` opens a folder from the terminal")
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { host?.ui.showSettings() }
                .keyboardShortcut(",", modifiers: .command)
        }
        // File: ours replaces New / Open / Save / Close (⌘W closes a tab, not the window).
        CommandGroup(replacing: .newItem) { menu("File", MenuLayout.file) }
        CommandGroup(replacing: .saveItem) {}
        CommandGroup(after: .sidebar) {
            Divider()
            menu("View", MenuLayout.view)
        }
        CommandGroup(after: .help) { menu("Help", MenuLayout.help) }
        CommandMenu("Find") { menu("Find", MenuLayout.find) }
        CommandMenu("Navigate") { menu("Navigate", MenuLayout.navigate) }
        CommandMenu("Editor") { menu("Editor", MenuLayout.editor) }
        CommandMenu("Agent") { menu("Agent", MenuLayout.agent) }
        CommandMenu("Source Control") { menu("Source Control", MenuLayout.sourceControl) }
        CommandMenu("Terminal") { menu("Terminal", MenuLayout.terminal) }
        // Only when a plugin brings commands no menu takes.
        if !pluginCommands.isEmpty {
            CommandMenu("Plugins") {
                ForEach(pluginCommands) { CommandButton(command: $0, commands: host?.commands) }
            }
        }
    }

    /// The layout's sections with dividers between, then what its categories
    /// bring that the layout doesn't list.
    @ViewBuilder
    private func menu(_ name: String, _ sections: [MenuLayout.Section]) -> some View {
        let commands = all
        ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
            let items = section.filter { isShown($0, in: commands) }
            if !items.isEmpty {
                if index > 0 { Divider() }
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    view(for: item, in: commands)
                }
            }
        }
        let extra = commands.filter { !MenuLayout.isPlaced($0) && MenuLayout.menuForCategory[$0.category] == name }
        if !extra.isEmpty {
            Divider()
            ForEach(extra) { CommandButton(command: $0, commands: host?.commands) }
        }
    }

    private func isShown(_ item: MenuLayout.Item, in commands: [OrbitCommand]) -> Bool {
        switch item {
        case .command(let id): commands.contains { $0.id == id }
        case .submenu(_, let ids): commands.contains { ids.contains($0.id) }
        case .commands(let prefix): commands.contains { $0.id.hasPrefix(prefix) }
        case .openRecent, .commandPalette: true
        }
    }

    @ViewBuilder
    private func view(for item: MenuLayout.Item, in commands: [OrbitCommand]) -> some View {
        switch item {
        case .command(let id):
            if let command = commands.first(where: { $0.id == id }) {
                CommandButton(command: command, commands: host?.commands)
            }
        case .submenu(let title, let ids):
            Menu(title) {
                ForEach(ids.compactMap { id in commands.first { $0.id == id } }) {
                    CommandButton(command: $0, commands: host?.commands)
                }
            }
        case .commands(let prefix):
            let matching = commands.filter { $0.id.hasPrefix(prefix) }
            if !matching.isEmpty {
                Menu("New Session With") {
                    ForEach(matching) { CommandButton(command: $0, commands: host?.commands) }
                }
            }
        case .openRecent:
            OpenRecentMenu()
        case .commandPalette:
            Button("Command Palette…") { if let host { CommandPalette.toggle(in: host) } }
                .keyboardShortcut("p", modifiers: [.command, .shift])
        }
    }
}
