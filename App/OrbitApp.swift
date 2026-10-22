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
            .orbitTextSize(Preferences.shared.interfaceTextSize)
            .frame(minWidth: 960, minHeight: 600)
            .tint(Theme.controlTint)
            .pillControls()
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
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Orbit has its own tabs; the system's window tabs only added
        // "Show Tab Bar" and "Show All Tabs" to View (D176).
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before any window: a move relaunches Orbit from Applications (D221).
        MainActor.assumeIsolated { MoveToApplications.offerIfNeeded() }
        // SwiftUI makes its window right after this, when it makes one at all.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated { ProjectWindows.shared.openWindowIfNone() }
        }
        // Themes and icon sets from the catalog, once a day (D186); agents and
        // language servers update from their plugins.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(40))
            await ExtensionCatalog.shared.updateInstalled()
            await ExtensionRegistry.shared.updateInstalled()
        }
    }

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
