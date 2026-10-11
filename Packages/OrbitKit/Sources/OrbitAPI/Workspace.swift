import AppKit
import Observation

/// A tab in the editor area. `kind` decides which `EditorProvider` renders it.
public struct EditorTab: Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: String
    public var title: String
    public var systemImage: String
    public var url: URL?

    public init(id: String, kind: String, title: String, systemImage: String, url: URL? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.systemImage = systemImage
        self.url = url
    }

    public static let fileKind = "file"

    public static func file(_ url: URL) -> EditorTab {
        EditorTab(id: "file:\(url.path)", kind: fileKind, title: url.lastPathComponent, systemImage: FileIcon.systemImage(for: url), url: url)
    }
}

@MainActor
@Observable
public final class Workspace {
    public private(set) var root: URL?
    public private(set) var tabs: [EditorTab] = []
    public var activeTabID: EditorTab.ID? {
        didSet {
            if activeTabID != oldValue, let tab = activeTab, tab.kind == EditorTab.fileKind, let url = tab.url { noteRecent(url) }
        }
    }
    public let documents = DocumentStore()

    /// Files most recently made active, newest first; remembered per project folder.
    public private(set) var recentFiles: [URL] = []

    /// Bumped whenever files on disk may have changed (agent finished a tool call, etc.).
    public private(set) var fileSystemGeneration = 0

    private static let lastRootKey = "orbit.lastWorkspaceRoot"
    private static let recentFilesKey = "orbit.recentFiles"
    private static let recentFilesLimit = 50

    init() {
        if let path = UserDefaults.standard.string(forKey: Self.lastRootKey),
           FileManager.default.fileExists(atPath: path) {
            root = URL(fileURLWithPath: path).standardizedFileURL
        }
        loadRecentFiles()
    }

    public var name: String { root?.lastPathComponent ?? "Orbit" }

    public var activeTab: EditorTab? { tabs.first { $0.id == activeTabID } }

    public func openFolder(_ url: URL) {
        root = url.standardizedFileURL
        tabs.removeAll()
        activeTabID = nil
        documents.closeAll()
        UserDefaults.standard.set(url.path, forKey: Self.lastRootKey)
        loadRecentFiles()
        fileSystemGeneration += 1
    }

    public func presentOpenFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url { openFolder(url) }
    }

    public func open(_ tab: EditorTab) {
        if !tabs.contains(where: { $0.id == tab.id }) {
            if let index = tabs.firstIndex(where: { $0.id == activeTabID }) {
                tabs.insert(tab, at: index + 1)
            } else {
                tabs.append(tab)
            }
        }
        activeTabID = tab.id
    }

    public func openFile(_ url: URL) { open(.file(url)) }

    /// A request for the editor to scroll to a 0-based line; the editor clears it.
    public var pendingReveal: (url: URL, line: Int)?

    public func openFile(_ url: URL, line: Int) {
        openFile(url)
        pendingReveal = (url.standardizedFileURL, line)
    }

    public func close(_ tabID: EditorTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let tab = tabs.remove(at: index)
        if let url = tab.url, tab.kind == EditorTab.fileKind, !tabs.contains(where: { $0.url == url }) {
            documents.close(url)
        }
        if activeTabID == tabID {
            activeTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
    }

    public func closeActiveTab() {
        if let activeTabID { close(activeTabID) }
    }

    public func relativePath(_ url: URL) -> String {
        guard let root else { return url.path }
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path.hasPrefix(rootPath) ? String(url.path.dropFirst(rootPath.count)) : url.path
    }

    public func resolve(path: String) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        return (root ?? URL(fileURLWithPath: NSHomeDirectory())).appendingPathComponent(path).standardizedFileURL
    }

    private func noteRecent(_ url: URL) {
        let url = url.standardizedFileURL
        guard recentFiles.first != url else { return }
        recentFiles.removeAll { $0 == url }
        recentFiles.insert(url, at: 0)
        if recentFiles.count > Self.recentFilesLimit { recentFiles.removeLast(recentFiles.count - Self.recentFilesLimit) }
        guard let root else { return }
        var saved = UserDefaults.standard.dictionary(forKey: Self.recentFilesKey) ?? [:]
        saved[root.path] = recentFiles.map(relativePath)
        UserDefaults.standard.set(saved, forKey: Self.recentFilesKey)
    }

    private func loadRecentFiles() {
        let saved = root.flatMap { UserDefaults.standard.dictionary(forKey: Self.recentFilesKey)?[$0.path] as? [String] }
        recentFiles = (saved ?? []).map(resolve(path:))
    }

    /// Call after something outside the editor touched the disk.
    public func fileSystemDidChange() {
        documents.reloadCleanDocumentsFromDisk()
        fileSystemGeneration += 1
    }
}

public enum FileIcon {
    public static func systemImage(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "swift": "swift"
        case "md", "markdown", "txt": "doc.plaintext"
        case "json", "yml", "yaml", "toml", "plist": "curlybraces"
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "heic": "photo"
        case "sh", "zsh", "bash": "terminal"
        case "html", "css": "globe"
        default: "doc.text"
        }
    }
}
