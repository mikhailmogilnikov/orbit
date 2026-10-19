import OrbitKit
import SwiftUI

@main
struct OrbitApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    init() {
        // Tooltips name buttons and their shortcuts (D67); macOS's ~1 s wait hid them.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 250])
        Self.forgetMinimumWindowFrames()
        _ = Updater.shared
    }

    /// Windows of D101's first builds saved their minimum size (no default
    /// size then); forgotten once, they open at the default size (D103).
    private static func forgetMinimumWindowFrames() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "orbit.forgotMinimumWindowFrames") else { return }
        defaults.set(true, forKey: "orbit.forgotMinimumWindowFrames")
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("NSWindow Frame main-AppWindow-") {
            defaults.removeObject(forKey: key)
        }
    }

    var body: some Scene {
        // A window per project (D101); `ProjectWindows` brings back the ones open at quit.
        WindowGroup("Orbit", id: "main", for: ProjectWindowID.self) { $value in
            ProjectWindowView(id: value.id)
        } defaultValue: {
            ProjectWindowID()
        }
        // Without it a new window opened at its minimum size (D103).
        .defaultSize(width: 1280, height: 800)
        // Tabs and window buttons live in the content's top row (D42).
        .windowStyle(.hiddenTitleBar)
        .restorationBehavior(.disabled)
        // Folders from Finder and the Dock go through the app delegate, not into a new window each.
        .handlesExternalEvents(matching: [])
        .commands { OrbitMenus() }
    }
}

/// One window: its project's whole workspace, or the welcome screen without one.
struct ProjectWindowView: View {
    let id: UUID
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let windows = ProjectWindows.shared
        let _ = windows.hostRevisions[id]
        let host = windows.host(for: id)
        MainWindow(host: host)
            // Close Folder gives the window a new host: its layout state starts over with it.
            .id(ObjectIdentifier(host))
            .frame(minWidth: 960, minHeight: 600)
            .tint(Theme.accent)
            .background(ProjectWindowReader(id: id))
            .onAppear { ProjectWindows.shared.windowAppeared(openWindow: openWindow) }
            .onChange(of: host.workspace.root, initial: true) { _, root in
                if let root { RecentFolders.shared.note(root) }
                ProjectWindows.shared.rootDidChange(host)
                ProjectWindows.shared.saveOpenFolders()
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { ProjectWindows.shared.confirmQuit() ? .terminateNow : .terminateCancel }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        // AppKit asks on the main thread; NSMenu just can't cross the isolation boundary.
        nonisolated(unsafe) var menu: NSMenu?
        MainActor.assumeIsolated { menu = ProjectWindows.shared.activeHost.map { RecentFolders.shared.dockMenu(host: $0) } }
        return menu
    }

    /// A folder dropped on the Dock icon or opened with Orbit in Finder (D102).
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls {
                var isFolder: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { continue }
                // A file (`orbit src/main.swift`, D142): in the window of its project.
                if isFolder.boolValue { ProjectWindows.shared.open(url) } else { ProjectWindows.shared.openFile(url) }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { ProjectWindows.shared.shutdown() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Menus are generated from the command registry, so plugin commands get
/// real menu items and shortcuts for free.
struct OrbitMenus: Commands {
    /// The main window's (D101): menus and their shortcuts act on it.
    private var host: PluginHost? { ProjectWindows.shared.activeHost }
    private var all: [OrbitCommand] { host?.commands.all ?? [] }
    private static let builtInCategories: Set<String> = ["File", "Code", "Agents", "Review", "Git", "Terminal", "Appearance", "Help", "View"]

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
        CommandGroup(replacing: .newItem) {
            items(in: "File", excluding: ["editor.save", "editor.saveAll", "editor.closeTab"])
        }
        CommandGroup(after: .newItem) {
            OpenRecentMenu()
        }
        CommandGroup(replacing: .saveItem) {
            items(ids: ["editor.save", "editor.saveAll", "editor.closeTab"])
        }
        CommandGroup(after: .sidebar) {
            Button("Command Palette…") { if let host { CommandPalette.toggle(in: host) } }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            items(ids: ["shell.toggleSidebar", "shell.toggleAgents", "shell.selectTheme"])
            items(ids: ["editor.zoomIn", "editor.zoomOut", "editor.zoomReset"])
            Divider()
            items(ids: ["shell.splitEditor", "shell.moveTabToOtherSide", "shell.focusOtherSide", "shell.joinEditors"])
            Divider()
            items(ids: ["shell.focusEditor", "shell.focusSecondSide", "shell.nextTab", "shell.previousTab", "shell.reopenClosedTab"])
            items(ids: ["shell.goBack", "shell.goForward", "shell.recentTab"])
            Divider()
        }
        // Language features (D59): navigation, fixes, rename, formatting, problems.
        CommandGroup(after: .help) { items(in: "Help") }
        CommandMenu("Code") { items(in: "Code") }
        CommandMenu("Agents") { items(in: "Agents") }
        CommandMenu("Review") { items(in: "Review") }
        CommandMenu("Git") { items(in: "Git") }
        CommandMenu("Terminal") { items(in: "Terminal") }
        CommandMenu("Plugins") {
            ForEach(all.filter { !Self.builtInCategories.contains($0.category) }) { command in
                CommandButton(command: command, commands: host?.commands)
            }
        }
    }

    private func items(in category: String, excluding: Set<String> = []) -> some View {
        ForEach(all.filter { $0.category == category && !excluding.contains($0.id) }) { command in
            CommandButton(command: command, commands: host?.commands)
        }
    }

    private func items(ids: [String]) -> some View {
        ForEach(ids.compactMap { id in all.first { $0.id == id } }) { command in
            CommandButton(command: command, commands: host?.commands)
        }
    }
}

struct CommandButton: View {
    let command: OrbitCommand
    let commands: CommandRegistry?

    var body: some View {
        let button = Button(command.title) {
            // Picked with the mouse, not by its shortcut: show the shortcut (D67).
            if NSApp.currentEvent?.type != .keyDown { commands?.teach(command) }
            command.run()
        }
            .disabled(!command.isEnabled())
        if let shortcut = command.shortcut {
            button.keyboardShortcut(shortcut)
        } else {
            button
        }
    }
}

/// File → Open Recent: the Dock menu's folders (D100).
struct OpenRecentMenu: View {
    var body: some View {
        let recent = RecentFolders.shared
        Menu("Open Recent") {
            ForEach(recent.existing, id: \.self) { folder in
                Button((folder.path as NSString).abbreviatingWithTildeInPath) { recent.open(folder) }
            }
            Divider()
            Button("Clear Menu") { recent.clear() }
        }
        .disabled(recent.existing.isEmpty)
    }
}
