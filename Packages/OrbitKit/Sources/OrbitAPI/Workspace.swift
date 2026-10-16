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
        // One tab per file however the path is spelled: a language server answers
        // /private/tmp/… for what the file tree opened as /tmp/… .
        let url = url.standardizedFileURL
        return EditorTab(id: "file:\(url.path)", kind: fileKind, title: url.lastPathComponent, systemImage: FileIcon.systemImage(for: url), url: url)
    }
}

/// One side of the editor: its tabs and the one shown (D90).
public struct EditorGroup: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var tabs: [EditorTab]
    public var activeTabID: EditorTab.ID?
    /// The preview tab (D94): the next preview opens in its place.
    public var previewTabID: EditorTab.ID?

    public init(tabs: [EditorTab] = [], activeTabID: EditorTab.ID? = nil) {
        id = UUID()
        self.tabs = tabs
        self.activeTabID = activeTabID
    }

    public var activeTab: EditorTab? { tabs.first { $0.id == activeTabID } }

    public func contains(_ id: EditorTab.ID) -> Bool { tabs.contains { $0.id == id } }

    /// Adds the tab at `index`, else after the shown one (unless it's there), and shows it.
    /// A preview replaces the group's preview tab.
    mutating func insert(_ tab: EditorTab, at index: Int? = nil, preview: Bool = false) {
        if preview, !contains(tab.id), let old = previewTabID, let slot = tabs.firstIndex(where: { $0.id == old }) {
            tabs[slot] = tab
        } else if !contains(tab.id) {
            let index = index.map { min(max(0, $0), tabs.count) }
                ?? tabs.firstIndex { $0.id == activeTabID }.map { $0 + 1 } ?? tabs.count
            tabs.insert(tab, at: index)
        } else {
            activeTabID = tab.id
            return
        }
        if preview { previewTabID = tab.id }
        activeTabID = tab.id
    }

    mutating func remove(_ id: EditorTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if previewTabID == id { previewTabID = nil }
        if activeTabID == id { activeTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

@MainActor
@Observable
public final class Workspace {
    public private(set) var root: URL?
    /// The editor side by side in one or two groups (D90), each with its tabs.
    public private(set) var groups: [EditorGroup] = [EditorGroup()] {
        didSet {
            guard groups != oldValue else { return }
            if let tab = activeTab, tab.id != oldValue[safe: focusedGroup]?.activeTabID,
               tab.kind == EditorTab.fileKind, let url = tab.url { noteRecent(url) }
            activeTabMayHaveChanged()
            saveTabs()
        }
    }
    /// The group commands, Open Quickly and the explorer act on.
    public private(set) var focusedGroup = 0 {
        didSet { activeTabMayHaveChanged() }
    }
    /// The left group's share of the editor's width.
    public var splitFraction = UserDefaults.standard.object(forKey: "orbit.editorSplit") as? Double ?? 0.5 {
        didSet { UserDefaults.standard.set(splitFraction, forKey: "orbit.editorSplit") }
    }
    public var isSplit: Bool { groups.count > 1 }

    /// Clamped: `groups` and `focusedGroup` change one after the other.
    private var focusedIndex: Int { min(focusedGroup, groups.count - 1) }

    /// The focused group's tabs.
    public var tabs: [EditorTab] { groups[focusedIndex].tabs }
    /// Every tab of every group.
    public var allTabs: [EditorTab] { groups.flatMap(\.tabs) }

    /// The focused group's shown tab.
    public var activeTabID: EditorTab.ID? {
        get { groups[focusedIndex].activeTabID }
        set { groups[focusedIndex].activeTabID = newValue }
    }
    /// Set while the saved tabs come back, so restoring doesn't save half of them.
    private var isRestoringTabs = false
    public let documents = DocumentStore()
    /// `.orbit/settings.json` values over Settings (D108).
    public let settings = ProjectSettings()

    /// Files most recently made active, newest first; remembered per project folder.
    public private(set) var recentFiles: [URL] = []

    /// Bumped whenever files on disk may have changed (agent finished a tool call, etc.).
    public private(set) var fileSystemGeneration = 0

    private static let lastRootKey = "orbit.lastWorkspaceRoot"
    private static let recentFilesKey = "orbit.recentFiles"
    private static let recentFilesLimit = 50
    private static let openTabsKey = "orbit.openFileTabs"

    /// Each window has its own (D101); one without a folder shows the welcome screen.
    init(root: URL? = nil) {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            self.root = root.standardizedFileURL
        }
        loadRecentFiles()
        restoreTabs()
        settings.reload(root: self.root)
        documents.onSave = { [weak self] url in
            guard let self, settings.isSettingsFile(url) else { return }
            settings.reload(root: root)
        }
    }

    /// Picks up edits to the settings files made outside Orbit (on activation).
    public func reloadSettings() { settings.reload(root: root) }

    /// Set by the app: opens a folder in another window (or brings forward the
    /// one showing it) and returns true, or false to open it in this one.
    public var openFolderElsewhere: (@MainActor (URL) -> Bool)?

    public var name: String { root?.lastPathComponent ?? "Orbit" }

    public var activeTab: EditorTab? { groups[focusedIndex].activeTab }

    public func openFolder(_ url: URL) {
        root = url.standardizedFileURL
        // The previous folder's tabs are already saved; this mustn't save the new folder's as empty.
        isRestoringTabs = true
        focusedGroup = 0
        groups = [EditorGroup()]
        isRestoringTabs = false
        documents.closeAll()
        closedFiles = []
        resetHistory()
        UserDefaults.standard.set(url.path, forKey: Self.lastRootKey)
        loadRecentFiles()
        restoreTabs()
        settings.reload(root: root)
        fileSystemGeneration += 1
    }

    public func presentOpenFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url { requestOpenFolder(url) }
    }

    /// Opening a folder for the user: in a new window while this one shows a
    /// project (D101), else here, asking about unsaved edits first.
    public func requestOpenFolder(_ url: URL) {
        let url = url.standardizedFileURL
        if let openFolderElsewhere, openFolderElsewhere(url) { return }
        guard url != root, confirmUnsavedChanges(in: documents.dirtyDocuments) else { return }
        openFolder(url)
    }

    /// Shows the tab: where it's already open (focusing that group), else in the focused group.
    /// `preview` (a single click in the explorer, D94): it takes the place of
    /// the group's preview tab, unless that one has unsaved edits.
    /// `focus: false` leaves the keyboard where it is (browsing the explorer, D98).
    public func open(_ tab: EditorTab, preview: Bool = false, focus: Bool = true) {
        quietTabID = focus ? nil : tab.id
        if !groups[focusedIndex].contains(tab.id), let other = groups.firstIndex(where: { $0.contains(tab.id) }) {
            focusedGroup = other
        }
        let replaced = preview && !groups[focusedIndex].contains(tab.id)
            ? groups[focusedIndex].tabs.first { $0.id == groups[focusedIndex].previewTabID } : nil
        if let replaced, let url = replaced.url, documents.existingDocument(for: url)?.isDirty == true {
            groups[focusedIndex].previewTabID = nil
            groups[focusedIndex].insert(tab, preview: true)
            return
        }
        groups[focusedIndex].insert(tab, preview: preview)
        if let replaced, let url = replaced.url, replaced.kind == EditorTab.fileKind,
           !allTabs.contains(where: { $0.url == url && $0.kind == EditorTab.fileKind }) {
            documents.close(url)
        }
    }

    /// The tab stays open (a double click, an edit): it stops being a preview.
    public func pin(_ tabID: EditorTab.ID) {
        for index in groups.indices where groups[index].previewTabID == tabID {
            groups[index].previewTabID = nil
        }
    }

    /// Shows the tab in the other group, splitting the editor if needed; focus stays (a preview beside its source).
    public func openBeside(_ tab: EditorTab) {
        if !isSplit { groups.append(EditorGroup()) }
        let other = focusedGroup == 0 ? 1 : 0
        groups[other].insert(tab)
    }

    /// A click on a tab: shows it in its group and focuses that group.
    public func activate(_ tabID: EditorTab.ID, in group: EditorGroup.ID) {
        guard let index = groups.firstIndex(where: { $0.id == group }) else { return }
        quietTabID = nil
        focusGroup(index)
        groups[index].activeTabID = tabID
    }

    public func focusGroup(_ index: Int) {
        guard groups.indices.contains(index), index != focusedGroup else { return }
        focusedGroup = index
        if let url = activeTab?.url, activeTab?.kind == EditorTab.fileKind { noteRecent(url) }
    }

    /// Split Editor: the active tab also opens in a new group to the right, which gets focus.
    public func splitEditor() {
        guard let tab = activeTab else { return }
        if isSplit {
            groups[focusedGroup == 0 ? 1 : 0].insert(tab)
        } else {
            groups.append(EditorGroup(tabs: [tab], activeTabID: tab.id))
        }
        focusedGroup = focusedGroup == 0 ? 1 : 0
    }

    /// Moves the active tab to the other group (splitting first); the group left empty closes.
    public func moveActiveTabToOtherGroup() {
        guard let tab = activeTab else { return }
        let source = focusedGroup
        if !isSplit { groups.append(EditorGroup()) }
        let target = source == 0 ? 1 : 0
        groups[target].insert(tab)
        groups[source].remove(tab.id)
        focusedGroup = target
        collapseEmptyGroups()
    }

    // MARK: Drag and drop (D91)

    /// Puts a tab into a group at a position (nil: after the shown one), taking
    /// it out of the group it was dragged from; reordering within one group too.
    public func place(_ tab: EditorTab, from source: EditorGroup.ID?, into target: Int, at index: Int? = nil) {
        guard groups.indices.contains(target) else { return }
        let targetID = groups[target].id
        var position = index
        if let source, let sourceIndex = groups.firstIndex(where: { $0.id == source }),
           let old = groups[sourceIndex].tabs.firstIndex(where: { $0.id == tab.id }) {
            if source == targetID, let index, old < index { position = index - 1 }
            groups[sourceIndex].remove(tab.id)
        }
        groups[target].remove(tab.id)
        groups[target].insert(tab, at: position)
        focusedGroup = target
        collapseEmptyGroups()
    }

    public enum Side: Sendable { case leading, trailing }

    /// A drop on an editor's edge: the tab opens in a new group on that side.
    /// A group's only tab is copied there, not moved (it would leave nothing behind).
    public func placeInNewGroup(_ tab: EditorTab, from source: EditorGroup.ID?, side: Side) {
        guard !isSplit else {
            place(tab, from: source, into: side == .leading ? 0 : 1)
            return
        }
        if let source, let index = groups.firstIndex(where: { $0.id == source }), groups[index].tabs.count > 1 {
            groups[index].remove(tab.id)
        }
        let group = EditorGroup(tabs: [tab], activeTabID: tab.id)
        if side == .leading {
            groups.insert(group, at: 0)
            focusedGroup = 0
        } else {
            groups.append(group)
            focusedGroup = 1
        }
    }

    // MARK: Moving files (D92)

    /// Moves (or copies) files and folders into `folder`, as the explorer's
    /// drag and drop does. Open tabs and buffers follow what moved, unsaved
    /// edits included. Returns why items weren't moved (nothing is replaced).
    @discardableResult
    public func moveItems(_ urls: [URL], into folder: URL, copy: Bool = false) -> [String] {
        transferItems(urls, into: folder, copy: copy).problems
    }

    /// `moveItems` that also says what went where, for undo (D93).
    /// `keepingBoth`: a copy whose name is taken gets "a copy.txt", as in
    /// Finder (pasting into the same folder duplicates, D95).
    public func transferItems(_ urls: [URL], into folder: URL, copy: Bool = false, keepingBoth: Bool = false) -> FileTransfer {
        let folder = folder.standardizedFileURL
        let manager = FileManager.default
        var result = FileTransfer()
        for url in urls.map(\.standardizedFileURL) {
            var destination = folder.appendingPathComponent(url.lastPathComponent).standardizedFileURL
            if copy, keepingBoth, manager.fileExists(atPath: destination.path) {
                destination = Self.freeCopyName(for: destination)
            }
            if destination == url { continue }
            if folder == url || folder.path.hasPrefix(url.path + "/") {
                result.problems.append("“\(url.lastPathComponent)” can't go into itself.")
                continue
            }
            if manager.fileExists(atPath: destination.path) {
                result.problems.append("“\(folder.lastPathComponent)” already has an item named “\(url.lastPathComponent)”.")
                continue
            }
            do {
                if copy {
                    try manager.copyItem(at: url, to: destination)
                } else {
                    try manager.moveItem(at: url, to: destination)
                    relocate(from: url, to: destination)
                }
                result.items.append(.init(from: url, to: destination))
            } catch {
                result.problems.append("“\(url.lastPathComponent)”: \(error.localizedDescription)")
            }
        }
        fileSystemDidChange()
        return result
    }

    /// "a copy.txt", then "a copy 2.txt"…
    static func freeCopyName(for url: URL) -> URL {
        let folder = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var number = 1
        while true {
            let name = (number == 1 ? "\(base) copy" : "\(base) copy \(number)") + (ext.isEmpty ? "" : ".\(ext)")
            let candidate = folder.appendingPathComponent(name).standardizedFileURL
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            number += 1
        }
    }

    // MARK: File operations (D93)

    /// Moves one item to an exact place (a rename, undoing a move); tabs and
    /// buffers follow. Never replaces an item; missing folders are created.
    public func moveItem(_ url: URL, to destination: URL) throws {
        let url = url.standardizedFileURL, destination = destination.standardizedFileURL
        guard destination != url else { return }
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path), !Self.isSameItem(url, destination) {
            throw FileOperationError.exists(destination.lastPathComponent)
        }
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if Self.isSameItem(url, destination) {
            // A case-only rename on a case-insensitive disk: by way of a free name.
            let temporary = url.deletingLastPathComponent().appendingPathComponent(".orbit-rename-\(UUID().uuidString)")
            try manager.moveItem(at: url, to: temporary)
            try manager.moveItem(at: temporary, to: destination)
        } else {
            try manager.moveItem(at: url, to: destination)
        }
        relocate(from: url, to: destination)
        fileSystemDidChange()
    }

    /// Renames an item in place; returns its new URL.
    @discardableResult
    public func renameItem(_ url: URL, to name: String) throws -> URL {
        let name = try Self.validatedName(name, allowsFolders: false)
        let destination = url.standardizedFileURL.deletingLastPathComponent().appendingPathComponent(name).standardizedFileURL
        try moveItem(url, to: destination)
        return destination
    }

    /// Creates an empty file or a folder; `name` may be a path ("src/a.ts"),
    /// whose missing folders are created, as in Cursor. `topmost` is the
    /// outermost item that didn't exist before, what undo takes away.
    @discardableResult
    public func createItem(named name: String, in folder: URL, isFolder: Bool) throws -> (url: URL, topmost: URL) {
        let path = try Self.validatedName(name, allowsFolders: true)
        let url = folder.standardizedFileURL.appendingPathComponent(path).standardizedFileURL
        let manager = FileManager.default
        guard !manager.fileExists(atPath: url.path) else { throw FileOperationError.exists(url.lastPathComponent) }
        var topmost = url
        while topmost.deletingLastPathComponent().path != folder.standardizedFileURL.path,
              !manager.fileExists(atPath: topmost.deletingLastPathComponent().path) {
            topmost = topmost.deletingLastPathComponent()
        }
        if isFolder {
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard manager.createFile(atPath: url.path, contents: Data()) else { throw FileOperationError.notCreated(url.lastPathComponent) }
        }
        fileSystemDidChange()
        return (url, topmost)
    }

    /// Moves items to the Trash and closes their tabs (unsaved edits in them
    /// are dropped: ask first). Returns where each went, for undo.
    public func trashItems(_ urls: [URL]) -> FileTransfer {
        var result = FileTransfer()
        for url in urls.map(\.standardizedFileURL) {
            do {
                var trashed: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
                closeItems(under: url)
                result.items.append(.init(from: url, to: (trashed as URL?)?.standardizedFileURL ?? url))
            } catch {
                result.problems.append("“\(url.lastPathComponent)”: \(error.localizedDescription)")
            }
        }
        fileSystemDidChange()
        return result
    }

    /// Tabs and buffers of a deleted item (and of what was inside it).
    private func closeItems(under url: URL) {
        let path = url.path
        func isInside(_ other: URL) -> Bool {
            let other = other.standardizedFileURL.path
            return other == path || other.hasPrefix(path + "/")
        }
        for tab in allTabs where tab.url.map(isInside) == true { close(tab.id) }
        documents.close { isInside($0) }
    }

    /// A file or folder name as typed: trimmed, without "/" (or, for paths,
    /// with no empty, "." or ".." parts).
    static func validatedName(_ name: String, allowsFolders: Bool) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !trimmed.isEmpty, allowsFolders || parts.count == 1,
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains(":") }) else {
            throw FileOperationError.invalidName(trimmed)
        }
        return trimmed
    }

    private static func isSameItem(_ a: URL, _ b: URL) -> Bool {
        let key: URLResourceKey = .fileResourceIdentifierKey
        guard let first = try? a.resourceValues(forKeys: [key]).fileResourceIdentifier,
              let second = try? b.resourceValues(forKeys: [key]).fileResourceIdentifier else { return false }
        return first.isEqual(second)
    }

    private func relocate(from old: URL, to new: URL) {
        let oldPath = old.path, newPath = new.path
        func target(_ url: URL) -> URL? {
            let path = url.standardizedFileURL.path
            if path == oldPath { return new }
            guard path.hasPrefix(oldPath + "/") else { return nil }
            return URL(fileURLWithPath: newPath + path.dropFirst(oldPath.count)).standardizedFileURL
        }
        documents.relocate(target)
        groups = groups.map { group in
            var group = group
            let active = group.activeTabID
            group.tabs = group.tabs.map { tab in
                guard let url = tab.url, let moved = target(url) else { return tab }
                let relocated = tab.kind == EditorTab.fileKind ? EditorTab.file(moved) : EditorTab(
                    id: tab.id.replacingOccurrences(of: url.path, with: moved.path), kind: tab.kind,
                    title: tab.title.replacingOccurrences(of: url.lastPathComponent, with: moved.lastPathComponent),
                    systemImage: tab.systemImage, url: moved
                )
                if tab.id == active { group.activeTabID = relocated.id }
                if tab.id == group.previewTabID { group.previewTabID = relocated.id }
                return relocated
            }
            return group
        }
        recentFiles = recentFiles.map { target($0) ?? $0 }
        func moved(_ location: EditorLocation) -> EditorLocation {
            target(location.url).map { EditorLocation(url: $0, line: location.line, column: location.column) } ?? location
        }
        backLocations = backLocations.map(moved)
        forwardLocations = forwardLocations.map(moved)
        caretLocations = Dictionary(caretLocations.values.map { (moved($0).url, moved($0)) }) { a, _ in a }
        historyFile = historyFile.map { target($0) ?? $0 }
    }

    /// One group again, holding every tab.
    public func joinGroups() {
        guard isSplit else { return }
        var joined = groups[focusedIndex]
        for (index, group) in groups.enumerated() where index != focusedGroup {
            for tab in group.tabs where !joined.contains(tab.id) { joined.tabs.append(tab) }
        }
        focusedGroup = 0
        groups = [joined]
    }

    public func openFile(_ url: URL, preview: Bool = false, focus: Bool = true) { open(.file(url), preview: preview, focus: focus) }

    // MARK: Keyboard navigation (D98)

    /// A tab opened without taking the keyboard focus: its editor leaves it be.
    public private(set) var quietTabID: EditorTab.ID?
    /// The tab whose editor should take the focus; the serial changes per request.
    public private(set) var editorFocusRequest: (tabID: EditorTab.ID, serial: Int)?

    /// Puts the keyboard in the shown editor of a group (the focused one when nil).
    public func focusEditor(group index: Int? = nil) {
        if let index {
            guard groups.indices.contains(index) else { return }
            focusGroup(index)
        }
        quietTabID = nil
        guard let id = activeTabID else { return }
        editorFocusRequest = (id, (editorFocusRequest?.serial ?? 0) + 1)
    }

    /// The next (or previous) tab of the focused group, wrapping around.
    public func showAdjacentTab(_ offset: Int) {
        let tabs = groups[focusedIndex].tabs
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        quietTabID = nil
        activeTabID = tabs[((index + offset) % tabs.count + tabs.count) % tabs.count].id
    }

    /// Files whose tabs the user closed, newest last, for Reopen Closed Tab.
    public private(set) var closedFiles: [URL] = []

    public func reopenClosedTab() {
        while let url = closedFiles.popLast() {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            openFile(url)
            return
        }
    }

    // MARK: Location history (D99)

    /// Where Go Back returns to, newest last.
    public private(set) var backLocations: [EditorLocation] = []
    /// Where Go Forward returns to, newest last.
    public private(set) var forwardLocations: [EditorLocation] = []
    /// Tabs most recently shown, newest first, for the ⌃Tab switcher.
    @ObservationIgnored public private(set) var recentTabIDs: [EditorTab.ID] = []
    /// Each file's last reported caret; updated on every keystroke, so not observed.
    @ObservationIgnored private var caretLocations: [URL: EditorLocation] = [:]
    /// The file the caret is in (it stays while a non-file tab is shown).
    @ObservationIgnored private var historyFile: URL?
    @ObservationIgnored private var lastActiveTabID: EditorTab.ID?
    @ObservationIgnored private var isNavigatingHistory = false
    /// A caret move this far is a jump worth going back to, as in VS Code.
    static let jumpLines = 10
    private static let historyLimit = 50

    /// Open tabs, most recently shown first.
    public var recentTabs: [EditorTab] {
        var seen = Set<EditorTab.ID>()
        let tabs = allTabs.filter { seen.insert($0.id).inserted }
        let order = Dictionary(recentTabIDs.enumerated().map { ($1, $0) }) { a, _ in a }
        return tabs.enumerated().sorted { a, b in
            (order[a.element.id] ?? Int.max, a.offset) < (order[b.element.id] ?? Int.max, b.offset)
        }.map(\.element)
    }

    /// The editor reports where its caret went; a long move is a jump.
    public func caretMoved(to location: EditorLocation) {
        if !isNavigatingHistory, let last = caretLocations[location.url], abs(last.line - location.line) >= Self.jumpLines {
            pushHistory(last)
        }
        caretLocations[location.url] = location
    }

    public func goBack() { moveInHistory(back: true) }
    public func goForward() { moveInHistory(back: false) }

    private var currentLocation: EditorLocation? {
        historyFile.map { caretLocations[$0] ?? EditorLocation(url: $0, line: 0, column: 0) }
    }

    private func pushHistory(_ location: EditorLocation) {
        forwardLocations = []
        guard backLocations.last != location else { return }
        backLocations.append(location)
        if backLocations.count > Self.historyLimit { backLocations.removeFirst() }
    }

    private func moveInHistory(back: Bool) {
        let current = currentLocation
        while let target = back ? backLocations.popLast() : forwardLocations.popLast() {
            guard FileManager.default.fileExists(atPath: target.url.path),
                  target.url != current?.url || target.line != current?.line else { continue }
            if let current {
                if back { forwardLocations.append(current) } else { backLocations.append(current) }
            }
            isNavigatingHistory = true
            defer { isNavigatingHistory = false }
            openFile(target.url, line: target.line, column: target.column)
            return
        }
    }

    private func activeTabMayHaveChanged() {
        guard let tab = activeTab, tab.id != lastActiveTabID else { return }
        lastActiveTabID = tab.id
        recentTabIDs.removeAll { $0 == tab.id }
        recentTabIDs.insert(tab.id, at: 0)
        if recentTabIDs.count > Self.historyLimit { recentTabIDs.removeLast() }
        guard tab.kind == EditorTab.fileKind, let url = tab.url?.standardizedFileURL else { return }
        if let previous = historyFile, previous != url, !isNavigatingHistory, !isRestoringTabs {
            pushHistory(caretLocations[previous] ?? EditorLocation(url: previous, line: 0, column: 0))
        }
        historyFile = url
    }

    private func resetHistory() {
        backLocations = []
        forwardLocations = []
        recentTabIDs = []
        caretLocations = [:]
        historyFile = nil
        lastActiveTabID = nil
    }

    /// A request for the editor to scroll to a 0-based line (and UTF-16 column,
    /// else the line's start); the editor clears it.
    public var pendingReveal: (url: URL, line: Int, column: Int?)?

    public func openFile(_ url: URL, line: Int, column: Int? = nil) {
        let target = EditorLocation(url: url.standardizedFileURL, line: line, column: column ?? 0)
        // A jump within the file: across files, the tab change records it.
        if !isNavigatingHistory, let current = currentLocation, current.url == target.url, current.line != line {
            pushHistory(current)
        }
        caretLocations[target.url] = target
        openFile(url)
        pendingReveal = (target.url, line, column)
    }

    /// Opens a file with the caret at the start of a range (a definition, a reference).
    public func open(_ location: SourceLocation) {
        openFile(location.url, line: location.range.start.line, column: location.range.start.character)
    }

    /// Closes the tab in `group`, or in every group when nil (a deleted file).
    public func close(_ tabID: EditorTab.ID, in group: EditorGroup.ID? = nil) {
        guard let tab = allTabs.first(where: { $0.id == tabID }) else { return }
        for index in groups.indices where group == nil || groups[index].id == group {
            groups[index].remove(tabID)
        }
        if let url = tab.url, tab.kind == EditorTab.fileKind, !allTabs.contains(where: { $0.url == url && $0.kind == EditorTab.fileKind }) {
            documents.close(url)
        }
        collapseEmptyGroups()
    }

    /// Closes a tab for the user: asks first when that would drop unsaved edits.
    /// Programmatic closes (e.g. a deleted file) use `close` and never ask.
    public func requestClose(_ tabID: EditorTab.ID, in group: EditorGroup.ID? = nil) {
        let group = group ?? groups[focusedIndex].id
        guard let tab = allTabs.first(where: { $0.id == tabID }) else { return }
        let elsewhere = groups.contains { $0.id != group && $0.contains(tabID) }
        if tab.kind == EditorTab.fileKind, let url = tab.url, !elsewhere,
           !allTabs.contains(where: { $0.id != tabID && $0.url == url && $0.kind == EditorTab.fileKind }),
           let document = documents.existingDocument(for: url),
           !confirmUnsavedChanges(in: [document]) { return }
        close(tabID, in: group)
        if tab.kind == EditorTab.fileKind, let url = tab.url, !allTabs.contains(where: { $0.url == url }) {
            closedFiles.removeAll { $0 == url }
            closedFiles.append(url)
            if closedFiles.count > 30 { closedFiles.removeFirst() }
        }
    }

    /// A split whose group lost its last tab becomes one group.
    private func collapseEmptyGroups() {
        guard isSplit, let empty = groups.firstIndex(where: \.tabs.isEmpty) else { return }
        let focused = groups[focusedIndex].id
        groups.remove(at: empty)
        focusedGroup = groups.firstIndex { $0.id == focused } ?? 0
    }

    public func closeActiveTab() {
        if let activeTabID { requestClose(activeTabID) }
    }

    /// Asks what to do with unsaved edits that are about to be lost (closing a
    /// tab, opening another folder, quitting) and saves them if asked to.
    /// Returns false when the user cancels or saving fails.
    public func confirmUnsavedChanges(in documents: [TextDocument]) -> Bool {
        let dirty = documents.filter(\.isDirty).sorted { $0.url.path < $1.url.path }
        guard !dirty.isEmpty else { return true }
        let alert = NSAlert()
        if dirty.count == 1 {
            alert.messageText = "Do you want to save the changes you made to “\(dirty[0].url.lastPathComponent)”?"
            alert.informativeText = "Your changes will be lost if you don't save them."
        } else {
            let shown = dirty.prefix(8).map { relativePath($0.url) }
            let more = dirty.count > shown.count ? "\n…and \(dirty.count - shown.count) more" : ""
            alert.messageText = "Do you want to save the changes to \(dirty.count) files?"
            alert.informativeText = "Your changes will be lost if you don't save them.\n\n" + shown.joined(separator: "\n") + more
        }
        alert.addButton(withTitle: dirty.count == 1 ? "Save" : "Save All")
        alert.addButton(withTitle: "Cancel")
        let discard = alert.addButton(withTitle: "Don't Save")
        discard.keyEquivalent = "d"
        discard.keyEquivalentModifierMask = .command
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            do {
                for document in dirty { try document.save() }
            } catch {
                NSAlert(error: error).runModal()
                return false
            }
            return true
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
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

    /// File tabs and the active one, per folder (D80): they come back on launch
    /// and when the folder is opened again. Only titles until a tab is shown.
    private func saveTabs() {
        guard let root, !isRestoringTabs else { return }
        var saved = UserDefaults.standard.dictionary(forKey: Self.openTabsKey) ?? [:]
        let entries: [[String: Any]] = groups.map { group in
            let files = group.tabs.filter { $0.kind == EditorTab.fileKind }.compactMap(\.url)
            var entry: [String: Any] = ["files": files.map(relativePath)]
            if let url = group.activeTab?.url, group.activeTab?.kind == EditorTab.fileKind { entry["active"] = relativePath(url) }
            return entry
        }.filter { !($0["files"] as? [String] ?? []).isEmpty }
        // "files"/"active" of the first group stay readable by older builds.
        var entry = entries.first ?? [:]
        if entries.count > 1 {
            entry["groups"] = entries
            entry["focused"] = focusedGroup
        }
        saved[root.path] = entries.isEmpty ? nil : entry
        UserDefaults.standard.set(saved, forKey: Self.openTabsKey)
    }

    private func restoreTabs() {
        guard let root, let entry = UserDefaults.standard.dictionary(forKey: Self.openTabsKey)?[root.path] as? [String: Any] else { return }
        isRestoringTabs = true
        defer { isRestoringTabs = false }
        let restored: [EditorGroup] = ((entry["groups"] as? [[String: Any]]) ?? [entry]).compactMap { entry in
            let files = (entry["files"] as? [String] ?? []).map(resolve(path:))
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !files.isEmpty else { return nil }
            let tabs = files.map(EditorTab.file)
            let active = (entry["active"] as? String).map(resolve(path:))
            return EditorGroup(tabs: tabs, activeTabID: (active.flatMap { url in tabs.first { $0.url == url } } ?? tabs.last)?.id)
        }
        groups = restored.isEmpty ? [EditorGroup()] : Array(restored.prefix(2))
        focusedGroup = min(entry["focused"] as? Int ?? 0, groups.count - 1)
    }

    private func loadRecentFiles() {
        let saved = root.flatMap { UserDefaults.standard.dictionary(forKey: Self.recentFilesKey)?[$0.path] as? [String] }
        recentFiles = (saved ?? []).map(resolve(path:))
    }

    /// Set when the window closes: plugins following the folder stop re-arming their observers.
    public private(set) var isClosed = false

    /// The window closed (D101): buffers and tabs go (the saved tabs stay), and
    /// the folder changes to none so observers of it fire once more and stop.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        isRestoringTabs = true
        groups = [EditorGroup()]
        documents.closeAll()
        closedFiles = []
        resetHistory()
        root = nil
        fileSystemGeneration += 1
    }

    /// Call after something outside the editor touched the disk.
    public func fileSystemDidChange() {
        documents.syncWithDisk()
        settings.reload(root: root)
        fileSystemGeneration += 1
    }
}

/// A caret position for Go Back / Go Forward (D99): 0-based line and UTF-16 column.
public struct EditorLocation: Hashable, Sendable {
    public var url: URL
    public var line: Int
    public var column: Int

    public init(url: URL, line: Int, column: Int) {
        self.url = url.standardizedFileURL
        self.line = line
        self.column = column
    }
}

/// What a batch of file moves, copies or trashings did (D93).
public struct FileTransfer: Sendable {
    public struct Item: Sendable, Equatable {
        /// Where it was (for copies: the original) and where it is now.
        public let from: URL
        public let to: URL

        public init(from: URL, to: URL) {
            self.from = from
            self.to = to
        }
    }

    public var items: [Item] = []
    public var problems: [String] = []
}

public enum FileOperationError: LocalizedError, Equatable {
    case exists(String)
    case invalidName(String)
    case notCreated(String)

    public var errorDescription: String? {
        switch self {
        case .exists(let name): "An item named “\(name)” already exists here."
        case .invalidName(let name): name.isEmpty ? "A name is needed." : "“\(name)” isn't a valid name."
        case .notCreated(let name): "“\(name)” couldn't be created."
        }
    }
}

/// The symbol for a file when the icon theme has nothing; files' real icons come
/// from the icon theme (`FileIconView`).
public enum FileIcon {
    public static func systemImage(for url: URL) -> String {
        "doc.text"
    }
}
