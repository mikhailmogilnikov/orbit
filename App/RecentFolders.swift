import AppKit
import OrbitKit

/// Folders opened lately, newest first, for the Dock icon's menu and
/// File → Open Recent, as in Cursor (D100).
@MainActor
@Observable
final class RecentFolders {
    static let shared = RecentFolders()
    private static let key = "orbit.recentFolders"
    private static let limit = 10

    private(set) var folders: [URL] = (UserDefaults.standard.stringArray(forKey: key) ?? [])
        .map { URL(fileURLWithPath: $0).standardizedFileURL }

    /// The ones still on disk.
    var existing: [URL] { folders.filter { FileManager.default.fileExists(atPath: $0.path) } }

    /// A window opened a folder.
    func note(_ url: URL) {
        let url = url.standardizedFileURL
        guard folders.first != url else { return }
        folders.removeAll { $0 == url }
        folders.insert(url, at: 0)
        if folders.count > Self.limit { folders.removeLast(folders.count - Self.limit) }
        save()
    }

    func remove(_ url: URL) {
        folders.removeAll { $0 == url.standardizedFileURL }
        save()
    }

    /// Keeps the folders windows show.
    func clear() {
        let open = Set(ProjectWindows.shared.allHosts.compactMap(\.workspace.root))
        folders = folders.filter(open.contains)
        save()
    }

    private func save() {
        UserDefaults.standard.set(folders.map(\.path), forKey: Self.key)
    }

    /// Its window if one shows it, else a new one (or the welcome window it's asked from, D101).
    func open(_ url: URL) { ProjectWindows.shared.open(url) }

    /// The Dock icon's menu: recent folders (open ones checked), then
    /// New Window, Open Folder… and a new agent chat. AppKit adds the window list and Quit.
    func dockMenu(host: PluginHost?) -> NSMenu {
        let menu = NSMenu()
        let target = DockMenuTarget.shared
        target.host = host
        let open = Set(ProjectWindows.shared.allHosts.compactMap { $0.workspace.root?.standardizedFileURL })
        let current = host?.workspace.root
        for folder in existing {
            let item = NSMenuItem(title: folder.lastPathComponent, action: #selector(DockMenuTarget.openFolder(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = folder
            item.image = NSWorkspace.shared.icon(forFile: folder.path)
            item.image?.size = NSSize(width: 16, height: 16)
            item.state = open.contains(folder) ? .on : .off
            item.toolTip = (folder.path as NSString).abbreviatingWithTildeInPath
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let newWindow = NSMenuItem(title: "New Window", action: #selector(DockMenuTarget.run(_:)), keyEquivalent: "")
        newWindow.target = target
        newWindow.representedObject = "shell.newWindow"
        menu.addItem(newWindow)
        let openFolder = NSMenuItem(title: "Open Folder…", action: #selector(DockMenuTarget.run(_:)), keyEquivalent: "")
        openFolder.target = target
        openFolder.representedObject = "workspace.openFolder"
        menu.addItem(openFolder)
        if current != nil {
            let chat = NSMenuItem(title: "New Agent Chat", action: #selector(DockMenuTarget.run(_:)), keyEquivalent: "")
            chat.target = target
            chat.representedObject = "agents.new"
            menu.addItem(chat)
        }
        return menu
    }
}

/// A Dock menu item needs an Objective-C target.
@MainActor
final class DockMenuTarget: NSObject {
    static let shared = DockMenuTarget()
    weak var host: PluginHost?

    @objc func openFolder(_ item: NSMenuItem) {
        guard let url = item.representedObject as? URL else { return }
        RecentFolders.shared.open(url)
    }

    @objc func run(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        NSApp.activate()
        if let host {
            host.commands.run(id)
        } else if id == "shell.newWindow" {
            ProjectWindows.shared.newWindow()
        } else if id == "workspace.openFolder" {
            ProjectWindows.shared.presentOpenFolderPanel()
        }
    }
}
