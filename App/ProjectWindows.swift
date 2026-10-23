import AppKit
import OrbitKit
import SwiftUI

/// A window's identity for SwiftUI's `WindowGroup(for:)`.
struct ProjectWindowID: Codable, Hashable {
    var id = UUID()
}

/// Windows and their projects (D101): every window has its own plugin host
/// (editor, terminals, agents, language servers), Open Folder in a window
/// that shows a project opens a new one, and the folders open at quit come
/// back on launch.
@MainActor
@Observable
final class ProjectWindows {
    static let shared = ProjectWindows()

    /// Made while SwiftUI builds a window: observing them would mean changing state mid-update.
    @ObservationIgnored private var hosts: [UUID: PluginHost] = [:]
    /// The window commands and menus act on: the main window's.
    private(set) var activeID: UUID?
    @ObservationIgnored private var openWindow: OpenWindowAction?
    /// The menus' own, there before any window: see `openWindowIfNone`.
    @ObservationIgnored private var menusOpenWindow: OpenWindowAction?
    @ObservationIgnored private var launchFolders: [URL] = []
    /// Folders Finder or the Dock asked to open before a window could.
    @ObservationIgnored private var earlyOpens: [URL] = []
    /// Bumped when a window's host is replaced (Close Folder), so its view picks up the new one.
    private(set) var hostRevisions: [UUID: Int] = [:]

    @ObservationIgnored private var order: [UUID] = []
    @ObservationIgnored private var windows: [UUID: WeakWindow] = [:]
    @ObservationIgnored private var pendingRoots: [UUID: URL] = [:]
    @ObservationIgnored private var restoredLaunchFolders = false
    @ObservationIgnored private var isTerminating = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Off in a stress run in the background (D244): it keeps behind the user's windows.
    @ObservationIgnored var activatesApp = true

    private static let openFoldersKey = "orbit.openFolders"

    private final class WeakWindow {
        weak var window: NSWindow?
        init(_ window: NSWindow) { self.window = window }
    }

    private init() {
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main
        ) { note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                let shared = ProjectWindows.shared
                if let id = shared.id(of: window) { shared.activeID = id }
            }
        })
    }

    var activeHost: PluginHost? {
        activeID.flatMap { hosts[$0] } ?? order.lazy.compactMap { self.hosts[$0] }.first
    }

    var allHosts: [PluginHost] { order.compactMap { hosts[$0] } }

    func host(for window: NSWindow?) -> PluginHost? { id(of: window).flatMap { hosts[$0] } }

    private func id(of window: NSWindow?) -> UUID? {
        guard let window else { return nil }
        return windows.first { $0.value.window === window }?.key
    }

    /// The window's host, made on first use. The first window of a launch
    /// takes the first folder open at the last quit; the others get windows.
    func host(for id: UUID) -> PluginHost {
        if let host = hosts[id] { return host }
        var root = pendingRoots.removeValue(forKey: id)
        if !restoredLaunchFolders {
            restoredLaunchFolders = true
            // A folder Orbit was launched to open comes first, in the window macOS opens.
            var seen = Set<URL>()
            launchFolders = (earlyOpens + LaunchGuard.shared.foldersToReopen(Self.savedFolders())).filter { seen.insert($0).inserted }
            earlyOpens = []
            if root == nil, !launchFolders.isEmpty { root = launchFolders.removeFirst() }
        }
        let host = makeHost(id: id, root: root)
        order.append(id)
        return host
    }

    private func makeHost(id: UUID, root: URL?) -> PluginHost {
        let host = PluginHost(plugins: BuiltinPlugins.all, root: root)
        registerShellCommands(in: host, id: id)
        #if DEBUG
        ShellStress.register(in: host)
        #endif
        host.workspace.openFolderElsewhere = { [weak self] url in self?.openElsewhere(url, from: id) ?? false }
        host.workspace.bringWindowToFront = { [weak self] in
            guard let self, activatesApp else { return }
            NSApp.activate()
            windows[id]?.window?.makeKeyAndOrderFront(nil)
        }
        hosts[id] = host
        return host
    }

    /// File → Close Folder: the window stops everything of its project and
    /// becomes a welcome window, with a fresh host (D102).
    func closeFolder(in id: UUID) {
        guard let host = hosts[id], host.workspace.root != nil,
              host.workspace.confirmUnsavedChanges(in: host.workspace.documents.dirtyDocuments) else { return }
        host.shutdown()
        _ = makeHost(id: id, root: nil)
        hostRevisions[id, default: 0] += 1
        saveOpenFolders()
    }

    /// A window's view is up: from now on windows can be opened, the rest of the launch's first.
    func windowAppeared(openWindow: OpenWindowAction) {
        self.openWindow = openWindow
        let folders = launchFolders + earlyOpens
        launchFolders = []
        earlyOpens = []
        for folder in folders where !focusWindow(showing: folder) { openNewWindow(folder) }
    }

    func menusAppeared(openWindow: OpenWindowAction) {
        menusOpenWindow = openWindow
    }

    /// Launched to open a folder (Finder, the Dock, `open -a`), macOS makes no
    /// window of its own: the folders waiting for one waited forever, in an app
    /// without windows, and its quit then saved an empty list.
    func openWindowIfNone() {
        guard hosts.isEmpty, let menusOpenWindow else { return }
        openWindow = menusOpenWindow
        openNewWindow(nil)
    }

    func attach(_ window: NSWindow, to id: UUID) {
        windows[id] = WeakWindow(window)
        if window.isMainWindow || activeID == nil { activeID = id }
        WindowCloseGuard.install(on: window) { [weak self] in self?.windowShouldClose(id) ?? true }
    }

    // MARK: Opening

    /// A folder for the user, from anywhere (Open Recent, the Dock, Finder):
    /// its window if one shows it, else the active window if it has none, else a new window.
    func open(_ url: URL) {
        if activatesApp { NSApp.activate() }
        guard openWindow != nil else {
            earlyOpens.append(url.standardizedFileURL)
            return
        }
        if let host = activeHost {
            host.workspace.requestOpenFolder(url)
        } else {
            openNewWindow(url)
        }
    }

    /// Files waiting for their project's window to open it.
    @ObservationIgnored private var pendingFiles: [URL: [URL]] = [:]

    /// A file from Finder or `orbit` (D142): in the window whose project has
    /// it, else its project (the git repository around it, or its folder) opens first.
    func openFile(_ url: URL) {
        let file = url.standardizedFileURL
        if let id = order.first(where: { hosts[$0]?.workspace.root.map { file.path.hasPrefix($0.path + "/") } == true }),
           let host = hosts[id] {
            if activatesApp { NSApp.activate() }
            windows[id]?.window?.makeKeyAndOrderFront(nil)
            host.workspace.openFile(file)
            return
        }
        let folder = Self.project(of: file)
        pendingFiles[folder, default: []].append(file)
        open(folder)
    }

    func rootDidChange(_ host: PluginHost) {
        guard let root = host.workspace.root?.standardizedFileURL, let files = pendingFiles.removeValue(forKey: root) else { return }
        for file in files { host.workspace.openFile(file) }
    }

    private static func project(of file: URL) -> URL {
        let folder = file.deletingLastPathComponent().standardizedFileURL
        var candidate = folder
        while candidate.path != "/" {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent(".git").path) { return candidate }
            candidate = candidate.deletingLastPathComponent()
        }
        return folder
    }

    /// File → New Window: the welcome screen.
    func newWindow() { openNewWindow(nil) }

    private func openElsewhere(_ url: URL, from id: UUID) -> Bool {
        if focusWindow(showing: url) { return true }
        guard hosts[id]?.workspace.root != nil else { return false }
        openNewWindow(url)
        return true
    }

    private func openNewWindow(_ root: URL?) {
        let value = ProjectWindowID()
        if let root { pendingRoots[value.id] = root.standardizedFileURL }
        openWindow?(id: "main", value: value)
    }

    @discardableResult
    private func focusWindow(showing url: URL) -> Bool {
        let url = url.standardizedFileURL
        guard let id = order.first(where: { hosts[$0]?.workspace.root == url }),
              let window = windows[id]?.window else { return false }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    // MARK: Closing

    private func windowShouldClose(_ id: UUID) -> Bool {
        guard !isTerminating, let host = hosts[id] else { return true }
        guard host.workspace.confirmUnsavedChanges(in: host.workspace.documents.dirtyDocuments) else { return false }
        // The last window closing quits the app: its folder opens again next time.
        // Minimized windows count: they keep the app running.
        if windows.values.filter({ $0.window != nil }).count <= 1 {
            saveOpenFolders()
            isTerminating = true
            return true
        }
        // After the window is gone: emptied, its views would flash the welcome screen.
        DispatchQueue.main.async { host.shutdown() }
        hosts[id] = nil
        order.removeAll { $0 == id }
        windows[id] = nil
        if activeID == id { activeID = order.first }
        saveOpenFolders()
        return true
    }

    /// Asks about unsaved edits in every window; false when the user cancels.
    func confirmQuit() -> Bool {
        guard !isTerminating else { return true }
        for id in order {
            guard let host = hosts[id] else { continue }
            let dirty = host.workspace.documents.dirtyDocuments
            guard !dirty.isEmpty else { continue }
            windows[id]?.window?.makeKeyAndOrderFront(nil)
            if !host.workspace.confirmUnsavedChanges(in: dirty) { return false }
        }
        saveOpenFolders()
        isTerminating = true
        return true
    }

    func shutdown() {
        for host in hosts.values { host.shutdown() }
    }

    // MARK: Folders open at quit

    func saveOpenFolders() {
        // Before the first window the saved folders haven't been opened yet: keep them.
        guard !isTerminating, restoredLaunchFolders else { return }
        let folders = order.compactMap { hosts[$0]?.workspace.root?.path }
        UserDefaults.standard.set(folders, forKey: Self.openFoldersKey)
    }

    private static func savedFolders() -> [URL] {
        let saved = UserDefaults.standard.stringArray(forKey: openFoldersKey)
            // Before D101 only one folder was remembered.
            ?? UserDefaults.standard.string(forKey: "orbit.lastWorkspaceRoot").map { [$0] } ?? []
        var seen = Set<String>()
        return saved.filter { FileManager.default.fileExists(atPath: $0) && seen.insert($0).inserted }
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
    }

    // MARK: Commands every window has

    private func registerShellCommands(in host: PluginHost, id: UUID) {
        host.commands.register(OrbitCommand(
            id: "shell.selectTheme", title: "Select Theme…", category: "Appearance",
            systemImage: "paintpalette", shortcut: KeyboardShortcut("t", modifiers: [.command, .control])
        ) { [weak host] in
            if let host { ThemeSelector.show(in: host) }
        })
        host.commands.register(OrbitCommand(
            id: "shell.welcome", title: "Welcome to Orbit", category: "Help", systemImage: "sparkles"
        ) { [weak host] in
            if let host { Onboarding.shared.show(in: host) }
        })
        host.commands.register(OrbitCommand(
            id: "shell.shortcuts", title: "Keyboard Shortcuts", category: "Help", systemImage: "keyboard"
        ) { [weak host] in
            CheatSheetState.shared.shownFor = host?.commands
        })
        host.commands.register(OrbitCommand(
            id: "shell.newWindow", title: "New Window", category: "File", systemImage: "macwindow.badge.plus",
            // ⇧⌘N is New Agent Session (D210).
            shortcut: KeyboardShortcut("n", modifiers: [.command, .control])
        ) { [weak self] in self?.newWindow() })
        let workspace = host.workspace
        host.commands.register(OrbitCommand(
            id: "workspace.closeFolder", title: "Close Folder", category: "File", systemImage: "folder.badge.minus",
            isEnabled: { workspace.root != nil }
        ) { [weak self] in self?.closeFolder(in: id) })
    }
}

/// Asks before a window closes (unsaved edits) by standing in front of
/// SwiftUI's own window delegate, which gets everything else.
@MainActor
final class WindowCloseGuard: NSObject, NSWindowDelegate {
    nonisolated(unsafe) private weak var original: NSWindowDelegate?
    private let shouldClose: @MainActor () -> Bool
    private static var guards: [ObjectIdentifier: WindowCloseGuard] = [:]
    private var closeObserver: NSObjectProtocol?

    private init(original: NSWindowDelegate?, shouldClose: @escaping @MainActor () -> Bool) {
        self.original = original
        self.shouldClose = shouldClose
    }

    static func install(on window: NSWindow, shouldClose: @escaping @MainActor () -> Bool) {
        guard !(window.delegate is WindowCloseGuard) else { return }
        let closeGuard = WindowCloseGuard(original: window.delegate, shouldClose: shouldClose)
        guards[ObjectIdentifier(window)] = closeGuard
        window.delegate = closeGuard
        let key = ObjectIdentifier(window)
        closeGuard.closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                if let closed = guards.removeValue(forKey: key), let observer = closed.closeObserver {
                    NotificationCenter.default.removeObserver(observer)
                }
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard shouldClose() else { return false }
        return original?.windowShouldClose?(sender) ?? true
    }

    nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || original?.responds(to: selector) == true
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
    }
}

/// Puts the window into `ProjectWindows` once it's on screen.
struct ProjectWindowReader: NSViewRepresentable {
    let id: UUID

    func makeNSView(context: Context) -> ReaderView { ReaderView(id: id) }
    func updateNSView(_ view: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        let id: UUID

        init(id: UUID) {
            self.id = id
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // After SwiftUI has set up the window and its delegate.
            DispatchQueue.main.async { [id] in ProjectWindows.shared.attach(window, to: id) }
        }
    }
}
