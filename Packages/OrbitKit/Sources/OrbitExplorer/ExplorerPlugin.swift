import OrbitAPI
import OrbitUI
import SwiftUI

public final class ExplorerPlugin: OrbitPlugin {
    public static let manifest = PluginManifest(
        id: "orbit.explorer",
        name: "Explorer",
        summary: "File tree of the open folder.",
        systemImage: "folder",
        tint: .blue,
        isRequired: true
    )

    private var watcher: FolderWatcher?

    public init() {}

    public func deactivate() { watcher = nil }

    public func activate(_ context: PluginContext) {
        let workspace = context.workspace
        let model = FileTreeModel(workspace: workspace, services: context.services)
        watcher = FolderWatcher(workspace: workspace) { [weak model] in model?.linkedFolders ?? [] }
        context.ui.addSettingsPane(SettingsPane(
            id: "files", title: "Files", systemImage: "doc.on.doc.fill", tint: .blue, group: .code, order: 5,
            summary: "What the file tree shows, and files hidden everywhere.",
            keywords: ["explorer", "file tree", "hidden", "dotfiles", "gitignore", "exclude", "ignore"],
            items: { [
                SettingsItem("hidden", "Show hidden files", keywords: ["dotfiles", "dot files", ".env"]),
                SettingsItem("ignored", "Show git-ignored files", keywords: [".gitignore", "build output", "node_modules"]),
                SettingsItem("excluded", "Excluded files", keywords: ["exclude", "files.exclude", "hide", "glob", "pattern"]),
            ] }
        ) {
            FilesSettingsPane()
        })
        context.ui.addSidebarPanel(PanelContribution(id: "explorer", title: "Explorer", systemImage: "folder", order: 0) {
            ExplorerView(model: model, workspace: workspace, commands: context.commands, services: context.services)
        }.command("explorer.show"))
        context.ui.addEditorProvider(EditorProvider(id: "explorer.compare", accepts: { $0.kind == CompareFiles.kind }) { tab in
            if let (left, right) = CompareFiles.files(of: tab) {
                CompareView(workspace: workspace, left: left, right: right, highlighter: context.services.resolve(SyntaxHighlighting.self))
                    .id(tab.id)
            }
        })
        // Into the folder chosen in the tree, else the active file's (D93).
        context.commands.register(OrbitCommand(
            id: "explorer.newFile",
            title: "New File…",
            category: "File",
            systemImage: "doc.badge.plus",
            shortcut: KeyboardShortcut("n", modifiers: .command)
        ) {
            context.ui.revealSidebarPanel("explorer")
            model.startCreating(in: model.targetFolder, isFolder: false)
        })
        context.commands.register(OrbitCommand(
            id: "explorer.newFolder",
            title: "New Folder…",
            category: "File",
            systemImage: "folder.badge.plus",
            shortcut: KeyboardShortcut("n", modifiers: [.command, .option])
        ) {
            context.ui.revealSidebarPanel("explorer")
            model.startCreating(in: model.targetFolder, isFolder: true)
        })
        // VS Code's key, next to ⌃⇧G for Source Control.
        context.commands.register(OrbitCommand(
            id: "explorer.show",
            title: "Show Explorer",
            category: "File",
            systemImage: "folder",
            shortcut: KeyboardShortcut("e", modifiers: [.command, .shift])
        ) {
            context.ui.revealSidebarPanel("explorer")
            model.focusList()
        })
        // On the selected row, else the active file (VS Code's keys, D98).
        context.commands.register(OrbitCommand(
            id: "file.revealInFinder",
            title: "Reveal in Finder",
            category: "File",
            systemImage: "folder",
            shortcut: KeyboardShortcut("r", modifiers: [.command, .option])
        ) {
            if let item = model.selectedItem { NSWorkspace.shared.activateFileViewerSelecting(model.targets(for: item)) }
        })
        context.commands.register(OrbitCommand(
            id: "file.copyPath",
            title: "Copy Path",
            category: "File",
            systemImage: "doc.on.clipboard",
            shortcut: KeyboardShortcut("c", modifiers: [.command, .option])
        ) {
            if let item = model.selectedItem { model.copyPaths(model.targets(for: item), relative: false) }
        })
        context.commands.register(OrbitCommand(
            id: "file.copyRelativePath",
            title: "Copy Relative Path",
            category: "File",
            systemImage: "doc.on.clipboard",
            shortcut: KeyboardShortcut("c", modifiers: [.command, .option, .shift])
        ) {
            if let item = model.selectedItem { model.copyPaths(model.targets(for: item), relative: true) }
        })
        context.commands.register(OrbitCommand(
            id: "workspace.openFolder",
            title: "Open Folder…",
            category: "File",
            systemImage: "folder.badge.plus",
            shortcut: KeyboardShortcut("o", modifiers: .command)
        ) {
            workspace.presentOpenFolderPanel()
        })
        context.commands.register(OrbitCommand(
            id: "explorer.refresh",
            title: "Refresh Explorer",
            category: "File",
            systemImage: "arrow.clockwise"
        ) {
            workspace.fileSystemDidChange()
        })
        #if DEBUG
        ExplorerStress.register(context, model: model)
        #endif
    }
}

@MainActor
@Observable
final class FileNode: Identifiable {
    let url: URL
    /// A symlink to a folder is one too: it opens like one.
    let isDirectory: Bool
    let link: Link?
    var isExpanded = false {
        didSet { if isExpanded != oldValue { onExpansionChange?(url, isExpanded) } }
    }
    private(set) var children: [FileNode]?
    /// Passed down the tree: the model remembers which folders are open.
    @ObservationIgnored var onExpansionChange: (@MainActor (URL, Bool) -> Void)?

    nonisolated var id: URL { url }
    var name: String { url.lastPathComponent }

    /// A symlink: where it points, as written in it, and whether that's gone.
    struct Link {
        let destination: String
        let isBroken: Bool

        var help: String { "\(isBroken ? "Broken symbolic link" : "Symbolic link") to \(destination)" }
    }

    init(url: URL, isDirectory: Bool, link: Link? = nil) {
        self.url = url
        self.isDirectory = isDirectory
        self.link = link
    }

    private static func make(_ url: URL, isSymlink: Bool, isDirectory: Bool) -> FileNode {
        guard isSymlink, let target = url.symlinkTarget else { return FileNode(url: url, isDirectory: isDirectory) }
        var isFolder: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: target.path, isDirectory: &isFolder)
        let destination = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? target.path
        return FileNode(url: url, isDirectory: exists && isFolder.boolValue, link: Link(destination: destination, isBroken: !exists))
    }

    // Build output and dependencies stay visible, dimmed as git-ignored.
    static let ignored: Set<String> = [".git", ".DS_Store"]

    func loadChildren(force: Bool = false) {
        guard isDirectory, children == nil || force else { return }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let urls = FileManager.default.entries(of: url, includingPropertiesForKeys: keys)
        let previous = Dictionary(uniqueKeysWithValues: (children ?? []).map { ($0.url, $0) })
        let loaded = urls
            .filter { !Self.ignored.contains($0.lastPathComponent) }
            .map { url in
                if let existing = previous[url] { return existing }
                let values = try? url.resourceValues(forKeys: Set(keys))
                let node = Self.make(url, isSymlink: values?.isSymbolicLink ?? false, isDirectory: values?.isDirectory ?? false)
                node.onExpansionChange = onExpansionChange
                return node
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        // Unchanged folders keep their array: every disk change reloads the open ones,
        // and a new array redraws the whole tree.
        if children.map({ $0.map(ObjectIdentifier.init) }) != loaded.map(ObjectIdentifier.init) { children = loaded }
        if force {
            for child in children ?? [] where child.isExpanded { child.loadChildren(force: true) }
        }
    }
}

@MainActor
@Observable
final class FileTreeModel {
    let workspace: Workspace
    private(set) var root: FileNode?
    private var loadedRoot: URL?
    private var loadedGeneration = -1
    /// The folder a drag is over: its row is highlighted (D92).
    var dropTarget: URL?
    /// The file picked with Select for Compare.
    var compareSelection: URL?

    func compare(with url: URL) {
        guard let selected = compareSelection, selected != url else { return }
        workspace.open(CompareFiles.tab(selected, url))
    }

    func setDropTarget(_ folder: URL, _ isTargeted: Bool) {
        if isTargeted { dropTarget = folder } else if dropTarget == folder { dropTarget = nil }
    }

    /// Files dropped on a folder (or a file in it): the project's own move
    /// there (⌥ copies), others are copied in, as in Finder and Cursor.
    func drop(_ urls: [URL], into folder: URL) -> Bool {
        dropTarget = nil
        guard let projectRoot = workspace.root else { return false }
        let rootPath = projectRoot.standardizedFileURL.path + "/"
        let target = folder.standardizedFileURL.path
        // A folder can't go into itself or its own subfolder, moved or copied (Finder refuses too).
        let files = urls.filter(\.isFileURL).map(\.standardizedFileURL)
            .filter { target != $0.path && !target.hasPrefix($0.path + "/") }
        let copies = NSEvent.modifierFlags.contains(.option)
        let outside = files.filter { !$0.path.hasPrefix(rootPath) }
        let moving = files.filter { $0.path.hasPrefix(rootPath) && (copies || $0.deletingLastPathComponent() != folder.standardizedFileURL) }
        guard !moving.isEmpty || !outside.isEmpty else { return false }
        // After the drag session: the confirmation is a modal alert.
        Task { @MainActor in
            if !copies, !moving.isEmpty, !Self.confirmMove(moving, into: folder) { return }
            let moved = workspace.transferItems(moving, into: folder, copy: copies)
            let copied = workspace.transferItems(outside, into: folder, copy: true)
            followMoves(copies ? [] : moved.items)
            if let node = node(for: folder), node.isDirectory {
                node.isExpanded = true
                node.loadChildren(force: true)
            }
            let copiedItems = (copies ? moved.items : []) + copied.items
            record(.combined([
                copies ? nil : FileStep.move(moved.items, name: "Move"),
                FileStep.trash(copiedItems.map(\.to), name: "Copy"),
            ].compactMap { $0 }, name: copies || moved.items.isEmpty ? "Copy" : "Move"))
            Self.report(moved.problems + copied.problems, "moved")
        }
        return true
    }

    // MARK: Rename, new file / folder, delete, undo (D93)

    /// The row whose name is being edited.
    var renaming: URL?
    /// A folder getting a new item, named in a row at the top of it.
    var creating: NewItem?
    /// A folder clicked or chosen with the arrow keys, highlighted as in
    /// Cursor; otherwise the selection is the active file.
    var selectedFolder: URL?

    func toggle(_ folder: FileNode) {
        setExpanded(folder, !folder.isExpanded)
    }

    /// Instant, as in VS Code: the list's animated row inserts, racing the
    /// highlight moving to the clicked folder, left a stale copy of the
    /// previously selected row drawn over the tree (D123).
    func setExpanded(_ folder: FileNode, _ expanded: Bool) {
        if expanded { folder.loadChildren() }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { folder.isExpanded = expanded }
    }

    /// The highlighted row: drawn by the rows themselves, always gray (D96).
    var selectedRow: URL? { selectedFolder ?? workspace.activeTab?.url }
    /// Rows ⌘- or ⇧-clicked besides the selected one (D111); a plain click clears them.
    var extraSelection: Set<URL> = []

    func isSelected(_ url: URL) -> Bool { selectedRow == url || extraSelection.contains(url) }

    /// What a context-menu or key action applies to: every selected row when
    /// `url` is one of several, else `url` alone. In tree order.
    func targets(for url: URL) -> [URL] {
        guard !extraSelection.isEmpty else { return [url] }
        let all = extraSelection.union([selectedItem].compactMap(\.self))
        guard all.contains(url), all.count > 1 else { return [url] }
        // Nested items go with their folder.
        let sorted = all.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return sorted.filter { item in !sorted.contains { $0 != item && item.path.hasPrefix($0.path + "/") } }
    }
    /// Set once the list's own highlight is turned off; until then it draws.
    var hidesNativeSelection = false

    /// Bumped to put the keyboard in the tree (⇧⌘E).
    private(set) var focusRequest = 0
    func focusList() { focusRequest += 1 }

    /// A click on the already selected folder's row (anywhere in it, the
    /// highlight's edges too); the first click toggles through the selection binding.
    func selectedFolderClicked() {
        guard let selectedFolder, extraSelection.isEmpty, let folder = node(for: selectedFolder), folder.isDirectory else { return }
        toggle(folder)
    }

    /// A double click on the selected file's row keeps its preview tab and goes to it (D94).
    func selectedFileDoubleClicked() {
        guard selectedFolder == nil, extraSelection.isEmpty, let url = selectedItem,
              node(for: url)?.isDirectory == false else { return }
        workspace.openFile(url)
        workspace.pin(EditorTab.file(url).id)
        workspace.focusEditor()
    }
    /// The window's: ⌘Z in the explorer (or with nothing focused) undoes file
    /// operations, while the editor and fields keep their own.
    @ObservationIgnored weak var undoManager: UndoManager?

    struct NewItem: Equatable {
        let folder: URL
        let isFolder: Bool
    }

    /// The selected row: a folder chosen with the keyboard, else the active file.
    var selectedItem: URL? {
        if let selectedFolder { return selectedFolder }
        guard let root = workspace.root, let tab = workspace.activeTab, tab.kind == EditorTab.fileKind,
              let url = tab.url, url.path.hasPrefix(root.standardizedFileURL.path + "/") else { return nil }
        return url
    }

    /// Where New File puts things: the selected folder, or the selected file's.
    var targetFolder: URL? {
        guard let item = selectedItem else { return workspace.root }
        // On disk: a folder just made isn't in the tree yet.
        let isFolder = node(for: item)?.isDirectory ?? ((try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
        return isFolder ? item : item.deletingLastPathComponent()
    }

    func startCreating(in folder: URL?, isFolder: Bool) {
        guard let folder = folder ?? workspace.root else { return }
        renaming = nil
        if let node = node(for: folder), node.isDirectory {
            node.isExpanded = true
            node.loadChildren()
        }
        creating = NewItem(folder: folder.standardizedFileURL, isFolder: isFolder)
    }

    func finishCreating(_ name: String) {
        guard let item = creating else { return }
        creating = nil
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            let created = try workspace.createItem(named: name, in: item.folder, isFolder: item.isFolder)
            record(.trash([created.topmost], name: item.isFolder ? "New Folder" : "New File"))
            sync()
            if item.isFolder {
                selectedFolder = created.url
            } else {
                workspace.openFile(created.url)
            }
        } catch {
            Self.report([error.localizedDescription], "created")
        }
    }

    func startRenaming(_ url: URL?) {
        guard let url, url.standardizedFileURL != workspace.root?.standardizedFileURL else { return }
        creating = nil
        renaming = url
    }

    func finishRenaming(_ url: URL, to name: String) {
        guard renaming == url else { return }
        renaming = nil
        guard name != url.lastPathComponent, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            let renamed = try workspace.renameItem(url, to: name)
            let item = FileTransfer.Item(from: url.standardizedFileURL, to: renamed)
            followMoves([item])
            if selectedFolder == url { selectedFolder = renamed }
            record(.move([item], name: "Rename"))
        } catch {
            Self.report([error.localizedDescription], "renamed")
        }
    }

    func trash(_ urls: [URL]) {
        guard !urls.isEmpty, confirmTrash(urls) else { return }
        let result = workspace.trashItems(urls)
        if let selectedFolder, urls.contains(where: { selectedFolder.path == $0.path || selectedFolder.path.hasPrefix($0.path + "/") }) {
            self.selectedFolder = nil
        }
        record(.restore(result.items, name: "Move to Trash"))
        Self.report(result.problems, "moved to the Trash")
    }

    private static let skipsTrashConfirmationKey = "orbit.explorer.skipTrashConfirmation"

    /// Always asks when unsaved edits would go with the files.
    private func confirmTrash(_ urls: [URL]) -> Bool {
        let dirty = workspace.documents.dirtyDocuments.filter { document in
            urls.contains { document.url.path == $0.path || document.url.path.hasPrefix($0.path + "/") }
        }
        guard !dirty.isEmpty || !UserDefaults.standard.bool(forKey: Self.skipsTrashConfirmationKey) else { return true }
        let alert = NSAlert()
        alert.messageText = urls.count == 1
            ? "Move “\(urls[0].lastPathComponent)” to the Trash?"
            : "Move \(urls.count) items to the Trash?"
        alert.informativeText = dirty.isEmpty
            ? "You can put it back with ⌘Z or from the Trash."
            : "Unsaved changes in \(dirty.count == 1 ? "“\(dirty[0].url.lastPathComponent)”" : "\(dirty.count) files") will be lost."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        if dirty.isEmpty {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't ask again"
        }
        let confirmed = alert.runSheetModal() == .alertFirstButtonReturn
        if confirmed, alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: Self.skipsTrashConfirmationKey) }
        return confirmed
    }

    /// Registers how to take a step back; undoing registers the way forward again.
    private func record(_ step: FileStep?) {
        guard let step, let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                let back = step.revert(model)
                model.sync()
                model.record(back)
            }
        }
        undoManager.setActionName(step.name)
    }

    fileprivate func performMoves(_ items: [FileTransfer.Item]) -> [FileTransfer.Item] {
        var done: [FileTransfer.Item] = [], problems: [String] = []
        for item in items {
            do {
                try workspace.moveItem(item.from, to: item.to)
                done.append(item)
            } catch {
                problems.append("“\(item.from.lastPathComponent)”: \(error.localizedDescription)")
            }
        }
        followMoves(done)
        Self.report(problems, "moved back")
        return done
    }

    fileprivate func performTrash(_ urls: [URL]) -> [FileTransfer.Item] {
        let result = workspace.trashItems(urls)
        Self.report(result.problems, "moved to the Trash")
        return result.items
    }

    fileprivate static func report(_ problems: [String], _ verb: String) {
        guard !problems.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = problems.count == 1 ? "An item couldn't be \(verb)" : "Some items couldn't be \(verb)"
        alert.informativeText = problems.joined(separator: "\n")
        alert.runSheetModal()
    }

    private static let skipsConfirmationKey = "orbit.explorer.skipMoveConfirmation"

    /// Cursor and VS Code ask before a drop moves files: a drag released on
    /// the wrong row is easy to miss. "Don't ask again" turns it off.
    private static func confirmMove(_ urls: [URL], into folder: URL) -> Bool {
        guard !UserDefaults.standard.bool(forKey: skipsConfirmationKey) else { return true }
        let alert = NSAlert()
        alert.messageText = urls.count == 1
            ? "Move “\(urls[0].lastPathComponent)” into “\(folder.lastPathComponent)”?"
            : "Move \(urls.count) items into “\(folder.lastPathComponent)”?"
        alert.informativeText = "Open tabs follow the files. Hold ⌥ while dropping to copy instead."
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        let confirmed = alert.runSheetModal() == .alertFirstButtonReturn
        if confirmed, alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: skipsConfirmationKey) }
        return confirmed
    }

    init(workspace: Workspace, services: ServiceRegistry) {
        self.workspace = workspace
        self.services = services
    }

    // MARK: Context menu actions (D95)

    /// Other plugins' parts, looked up when used (they may activate after this one).
    private let services: ServiceRegistry
    var agentTasks: AgentTasks? { services.resolve(AgentTasks.self) }
    var terminal: TerminalOpening? { services.resolve(TerminalOpening.self) }
    var search: ProjectSearching? { services.resolve(ProjectSearching.self) }
    /// What ⌘X put on the pasteboard: pasting those moves them.
    private var cutItems: [URL] = []
    /// The system's; a test's own.
    var pasteboard = NSPasteboard.general

    func openTerminal(at url: URL) {
        terminal?.openTerminal(in: node(for: url)?.isDirectory == true ? url : url.deletingLastPathComponent())
    }

    /// Cut and Copy put the files on the pasteboard, so Finder can paste them too.
    func copyItems(_ urls: [URL], cut: Bool) {
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        noteCopied(urls, cut: cut)
    }

    func noteCopied(_ urls: [URL], cut: Bool) {
        cutItems = cut ? urls.map(\.standardizedFileURL) : []
    }

    var canPaste: Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    /// Into a folder, or next to a file. Cut items move; others are copied,
    /// "a copy.txt" when the name is taken (the same folder duplicates).
    func paste(into target: URL?) {
        guard let target = target ?? workspace.root,
              let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return }
        let items = urls.map(\.standardizedFileURL)
        // On disk: a folder the tree never loaded is one too.
        var folder = (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? target.standardizedFileURL : target.deletingLastPathComponent()
        // A folder copied and pasted while still selected goes beside itself, as in Finder (D252).
        // By path: a folder's URL off the pasteboard ends in a slash, the target's may not.
        while let item = items.first(where: { folder.path == $0.path || folder.path.hasPrefix($0.path + "/") }) {
            folder = item.deletingLastPathComponent().standardizedFileURL
        }
        if !cutItems.isEmpty, Set(items) == Set(cutItems) {
            cutItems = []
            let moved = workspace.transferItems(items, into: folder)
            followMoves(moved.items)
            record(.move(moved.items, name: "Move"))
            Self.report(moved.problems, "moved")
        } else {
            let copied = workspace.transferItems(items, into: folder, copy: true, keepingBoth: true)
            record(.trash(copied.items.map(\.to), name: "Paste"))
            Self.report(copied.problems, "copied")
        }
        if let node = node(for: folder) {
            node.isExpanded = true
            node.loadChildren(force: true)
        }
    }

    func copyPath(_ url: URL, relative: Bool) { copyPaths([url], relative: relative) }

    /// One per line.
    func copyPaths(_ urls: [URL], relative: Bool) {
        pasteboard.clearContents()
        pasteboard.setString(urls.map { relative ? workspace.relativePath($0) : $0.path }.joined(separator: "\n"), forType: .string)
    }

    func sync() {
        guard let url = workspace.root else {
            root = nil
            loadedRoot = nil
            return
        }
        if loadedRoot != url {
            if loadedRoot != nil { undoManager?.removeAllActions(withTarget: self) }
            renaming = nil
            creating = nil
            selectedFolder = nil
            let node = FileNode(url: url, isDirectory: true)
            node.isExpanded = true
            node.onExpansionChange = { [weak self] url, expanded in self?.expansionChanged(url, expanded) }
            node.loadChildren()
            root = node
            loadedRoot = url
            restoreExpanded()
        } else if loadedGeneration != workspace.fileSystemGeneration {
            root?.loadChildren(force: true)
        }
        loadedGeneration = workspace.fileSystemGeneration
    }

    // MARK: Open folders, per project (D80)

    private static let expandedKey = "orbit.expandedFolders"
    private var expanded: [String] = []
    private var isRestoring = false

    private func expansionChanged(_ url: URL, _ isExpanded: Bool) {
        guard !isRestoring, loadedRoot != nil else { return }
        let path = workspace.relativePath(url)
        expanded.removeAll { $0 == path }
        if isExpanded { expanded.append(path) }
        // Folders nested in a collapsed one stay remembered; the oldest go past a few hundred.
        if expanded.count > 500 { expanded.removeFirst(expanded.count - 500) }
        saveExpanded()
    }

    private func saveExpanded() {
        guard let root = loadedRoot else { return }
        var saved = UserDefaults.standard.dictionary(forKey: Self.expandedKey) ?? [:]
        saved[root.path] = expanded.isEmpty ? nil : expanded
        UserDefaults.standard.set(saved, forKey: Self.expandedKey)
    }

    /// Open folders stay open under their new names and places.
    private func followMoves(_ items: [FileTransfer.Item]) {
        guard !items.isEmpty else { return }
        for item in items {
            let old = workspace.relativePath(item.from), new = workspace.relativePath(item.to)
            expanded = expanded.map { $0 == old ? new : $0.hasPrefix(old + "/") ? new + $0.dropFirst(old.count) : $0 }
        }
        saveExpanded()
        sync()
        expandRemembered()
    }

    private func restoreExpanded() {
        guard let root = loadedRoot else { return }
        expanded = UserDefaults.standard.dictionary(forKey: Self.expandedKey)?[root.path] as? [String] ?? []
        expandRemembered()
    }

    /// Parents first, so each folder's children are loaded by the time its subfolders open.
    private func expandRemembered() {
        isRestoring = true
        defer { isRestoring = false }
        for path in expanded.sorted(by: { $0.split(separator: "/").count < $1.split(separator: "/").count }) {
            guard let node = node(for: workspace.resolve(path: path)), node.isDirectory else { continue }
            node.isExpanded = true
            node.loadChildren()
        }
    }

    /// Symlinked folders loaded in the tree.
    var linkedFolders: [URL] {
        var folders: [URL] = []
        func visit(_ node: FileNode) {
            for child in node.children ?? [] where child.isDirectory {
                if child.link != nil { folders.append(child.url) }
                visit(child)
            }
        }
        if let root { visit(root) }
        return folders
    }

    /// A loaded node by URL, walking down only the matching branch.
    func node(for url: URL) -> FileNode? {
        let path = url.standardizedFileURL.path
        var node = root
        while let current = node {
            let currentPath = current.url.standardizedFileURL.path
            if currentPath == path { return current }
            node = current.children?.first { path.hasPrefix($0.url.standardizedFileURL.path + "/") || $0.url.standardizedFileURL.path == path }
        }
        return nil
    }
}

/// An undoable file operation: `revert` takes it back and returns the step
/// that redoes it (nil when nothing could be reverted).
struct FileStep: Sendable {
    let name: String
    let revert: @MainActor @Sendable (FileTreeModel) -> FileStep?

    /// Undoes moves and renames by moving each item back.
    static func move(_ items: [FileTransfer.Item], name: String) -> FileStep? {
        guard !items.isEmpty else { return nil }
        return FileStep(name: name) { model in
            let back = model.performMoves(items.reversed().map { .init(from: $0.to, to: $0.from) })
            return .move(back, name: name)
        }
    }

    /// Undoes new and copied items: they go to the Trash, and come back on redo.
    static func trash(_ urls: [URL], name: String) -> FileStep? {
        guard !urls.isEmpty else { return nil }
        return FileStep(name: name) { model in .restore(model.performTrash(urls), name: name) }
    }

    /// Undoes a move to the Trash: items go back where they were.
    static func restore(_ trashed: [FileTransfer.Item], name: String) -> FileStep? {
        guard !trashed.isEmpty else { return nil }
        return FileStep(name: name) { model in
            let back = model.performMoves(trashed.map { .init(from: $0.to, to: $0.from) })
            return .trash(back.map(\.to), name: name)
        }
    }

    static func combined(_ steps: [FileStep], name: String) -> FileStep? {
        guard steps.count > 1 else { return steps.first }
        return FileStep(name: name) { model in .combined(steps.reversed().compactMap { $0.revert(model) }, name: name) }
    }
}

struct ExplorerView: View {
    let model: FileTreeModel
    let workspace: Workspace
    let commands: CommandRegistry
    let services: ServiceRegistry
    /// Git status colors; nil when the Git plugin is disabled. Looked up, not
    /// kept: the list's selection binding holds the view, and a model kept
    /// there outlived Source Control turned off (D246).
    private var decorations: FileStatusProviding? { services.resolve(FileStatusProviding.self) }

    var body: some View {
        Group {
            if let root = model.root {
                List(selection: multipleSelection) {
                    Section {
                        FileChildren(node: root, model: model, workspace: workspace, decorations: decorations)
                    } header: {
                        ExplorerHeader(root: root, model: model, commands: commands)
                    }
                }
                .listStyle(.sidebar)
                .focused($isListFocused)
                .task(id: model.focusRequest) {
                    guard model.focusRequest > handledFocusRequest else { return }
                    handledFocusRequest = model.focusRequest
                    isListFocused = true
                }
                .modifier(FileKeys(model: model))
                .background(NativeSelectionHider(model: model, selection: model.selectedRow))
                // Below the rows (or between them): into the project's top folder.
                .dropDestination(for: URL.self) { urls, _ in
                    model.drop(urls, into: root.url)
                } isTargeted: { model.setDropTarget(root.url, $0) }
                .overlay {
                    if model.dropTarget == root.url {
                        RoundedRectangle(cornerRadius: Theme.corner)
                            .strokeBorder(Theme.dropBorder, lineWidth: 1.5)
                            .padding(4)
                            .allowsHitTesting(false)
                    }
                }
            } else {
                VStack(spacing: 14) {
                    EmptyStateView("No Folder Open", systemImage: "folder", message: "Open a project to start working with agents.")
                        .frame(maxHeight: 180)
                    Button("Open Folder…") { workspace.presentOpenFolderPanel() }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            model.undoManager = undoManager
            model.sync()
        }
        .onChange(of: undoManager) { model.undoManager = undoManager }
        .onChange(of: workspace.root) { model.sync() }
        .onChange(of: workspace.fileSystemGeneration) { model.sync() }
        .onChange(of: workspace.activeTab?.id) {
            model.selectedFolder = nil
            model.extraSelection = []
        }
    }

    @Environment(\.undoManager) private var undoManager
    @FocusState private var isListFocused: Bool
    @State private var handledFocusRequest = 0

    /// The list's own ⌘- and ⇧-click; one row selected goes the usual way.
    private var multipleSelection: Binding<Set<URL>> {
        Binding(
            get: { model.extraSelection.union([model.selectedFolder ?? workspace.activeTab?.url].compactMap(\.self)) },
            set: { urls in
                guard urls.count > 1 else {
                    model.extraSelection = []
                    selectionBinding.wrappedValue = urls.first
                    return
                }
                let primary = model.selectedFolder ?? workspace.activeTab?.url
                model.extraSelection = urls.subtracting([primary].compactMap(\.self))
            }
        )
    }

    private var selectionBinding: Binding<URL?> {
        Binding(
            get: { model.selectedFolder ?? workspace.activeTab?.url },
            set: { url in
                guard let url else { return }
                if let folder = model.node(for: url), folder.isDirectory {
                    // The list sets its selection again when it reappears (back from
                    // another panel, mid-click on the panel's button): no toggle then.
                    guard model.selectedFolder != url else { return }
                    // The folder stays selected; a click toggles it, arrow keys don't.
                    model.selectedFolder = url
                    if let event = NSApp.currentEvent, event.type == .leftMouseDown || event.type == .leftMouseUp {
                        model.toggle(folder)
                    }
                    return
                }
                model.selectedFolder = nil
                // A broken link's file would be created on save; its tooltip says where it pointed.
                guard !url.hasDirectoryPath, !url.isFolderFollowingLinks, model.node(for: url)?.link?.isBroken != true else { return }
                // A click or an arrow key previews in one reused tab, leaving the keys
                // in the tree (D94, D98); a double click keeps it and goes to it.
                workspace.openFile(url, preview: true, focus: false)
            }
        )
    }
}

struct FileChildren: View {
    let node: FileNode
    let model: FileTreeModel
    let workspace: Workspace
    let decorations: FileStatusProviding?

    // Rows drag as their file (D91) to the editor, the agent chat or another
    // app. The default image, a snapshot of the row, drew the name in black
    // in dark mode, hence `DragPreview` in the window's color scheme.
    @Environment(\.colorScheme) private var colorScheme

    /// What Settings → Files leaves out (D178), re-read when it changes.
    private var visibleChildren: [FileNode] {
        let preferences = Preferences.shared
        let rootPath = workspace.root.map { $0.standardizedFileURL.path + "/" }
        return (node.children ?? []).filter { child in
            if !preferences.showsHiddenFiles, child.name.hasPrefix(".") { return false }
            if !preferences.showsIgnoredFiles, decorations?.isIgnored(child.url) == true { return false }
            guard !preferences.fileExclusions.isEmpty, let rootPath else { return true }
            let path = child.url.standardizedFileURL.path
            return !path.hasPrefix(rootPath) || preferences.fileExclusions.allows(String(path.dropFirst(rootPath.count)))
        }
    }


    var body: some View {
        if let item = model.creating, item.folder == node.url.standardizedFileURL {
            HStack(spacing: 4) {
                Label {
                    NameField(name: "", selectsExtension: true) { model.finishCreating($0) } cancel: { model.creating = nil }
                        .padding(.leading, -3)
                } icon: {
                    Image(systemName: item.isFolder ? "folder" : "doc")
                        .foregroundStyle(.secondary)
                }
            }
            .id(item.folder.appendingPathComponent(item.isFolder ? ".orbit-new-folder" : ".orbit-new-file"))
        }
        ForEach(visibleChildren) { child in
            if child.isDirectory {
                DisclosureGroup(isExpanded: Binding(
                    get: { child.isExpanded },
                    set: { model.setExpanded(child, $0) }
                )) {
                    FileChildren(node: child, model: model, workspace: workspace, decorations: decorations)
                } label: {
                    FileLabel(url: child.url, kind: decorations?.folderStatus(of: child.url), isFolder: true, isExpanded: child.isExpanded, isIgnored: decorations?.isIgnored(child.url) ?? false, link: child.link, model: model)
                        .modifier(RowHighlight(url: child.url, model: model))
                        .contextMenu { FileContextMenu(url: child.url, isFolder: true, model: model) }
                        .draggable(child.url) { DragPreview(url: child.url, isFolder: true, colorScheme: colorScheme) }
                        .modifier(FolderDrop(folder: child.url, model: model))
                }
            } else {
                FileLabel(url: child.url, kind: decorations?.status(of: child.url), isFolder: false, isIgnored: decorations?.isIgnored(child.url) ?? false, link: child.link, model: model)
                    .modifier(RowHighlight(url: child.url, model: model))
                    .tag(child.url)
                    .contextMenu { FileContextMenu(url: child.url, isFolder: false, model: model) }
                    .draggable(child.url) { DragPreview(url: child.url, isFolder: false, colorScheme: colorScheme) }
                    // A file row passes drops to its folder, as in Cursor.
                    .modifier(FolderDrop(folder: node.url, model: model, highlights: false))
            }
        }
    }
}

/// The selected row's background: the translucent gray of an unfocused
/// sidebar, focused or not. The list's own highlight turned blue whenever it
/// had the focus and could stay on a row the binding had already left (D96).
struct RowHighlight: ViewModifier {
    let url: URL
    let model: FileTreeModel

    func body(content: Content) -> some View {
        content.listRowBackground(
            model.hidesNativeSelection && model.isSelected(url)
                ? Capsule()
                    .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
                    // Wide, so the chevron sits clear of the capsule's curve (D229).
                    .padding(.horizontal, CapsuleRowHighlight.inset.width)
                    .padding(.vertical, CapsuleRowHighlight.inset.height)
                : nil
        )
    }
}

/// Finds the outline view under the list and turns its selection drawing off
/// (the selection itself, keyboard included, keeps working).
struct NativeSelectionHider: NSViewRepresentable {
    let model: FileTreeModel
    /// Passed so a selection change re-applies it, should the list reset it.
    let selection: URL?

    func makeNSView(context: Context) -> NSView { NSView() }

    @MainActor
    final class Coordinator {
        let reclicks: ReclickMonitor
        let staleRows = StaleRowSweeper()
        init(model: FileTreeModel) { reclicks = ReclickMonitor(model: model) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.reclicks.stop()
        coordinator.staleRows.stop()
    }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        // Vibrant, the disclosure chevrons take their color from the sidebar
        // behind the capsule and vanish into it; plain, they blend over it.
        let appearance = NSAppearance(named: context.environment.colorScheme == .dark ? .darkAqua : .aqua)
        Task { @MainActor in
            var ancestor = view.superview
            while let current = ancestor {
                if let outline = Self.outline(in: current) {
                    coordinator.reclicks.watch(outline)
                    coordinator.staleRows.watch(outline)
                    CapsuleRowHighlight.apply(to: outline)
                    if outline.appearance?.name != appearance?.name { outline.appearance = appearance }
                    if outline.selectionHighlightStyle != .none { outline.selectionHighlightStyle = .none }
                    if !model.hidesNativeSelection { model.hidesNativeSelection = true }
                    return
                }
                ancestor = current.superview
            }
        }
    }

    private static func outline(in view: NSView) -> NSOutlineView? {
        if let outline = view as? NSOutlineView { return outline }
        for subview in view.subviews {
            if let outline = outline(in: subview) { return outline }
        }
        return nil
    }
}

/// Sees clicks on the row that's already selected, which the list keeps to
/// itself (its selection doesn't change). A row's tap gesture only covers the
/// label, so a click on the highlight's edge used to do nothing (D197).
/// Double clicks on files too: a double-tap gesture on the row made macOS 26's
/// list miss single clicks (D232).
@MainActor
final class ReclickMonitor {
    private weak var model: FileTreeModel?
    private weak var outline: NSOutlineView?
    private var monitor: Any?
    private var pressed: (row: Int, location: NSPoint)?

    init(model: FileTreeModel) { self.model = model }

    func watch(_ outline: NSOutlineView) {
        self.outline = outline
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        guard let outline, event.window === outline.window else { return }
        if event.type == .leftMouseUp {
            finish(at: event.locationInWindow)
            return
        }
        // Before the list handles the click: was this row already the selection?
        let point = outline.convert(event.locationInWindow, from: nil)
        let row = outline.row(at: point)
        let plain = event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty
        let hit = outline.superview.flatMap { $0.hitTest($0.convert(event.locationInWindow, from: nil)) }
        let onControl = hit is NSButton || hit is NSTextView || hit is NSTextField
        // Only clicks on the tree itself: the outline of a panel switched away
        // from can linger, and a click on the panel's button would land on its rows.
        let inTree = hit?.isDescendant(of: outline) == true && !outline.isHiddenOrHasHiddenAncestor
        guard plain, !onControl, inTree, row >= 0 else {
            pressed = nil
            return
        }
        if event.clickCount == 2 {
            // Once the list has handled the click, the row is the selection.
            DispatchQueue.main.async { [weak self] in
                guard let self, outline.selectedRowIndexes == IndexSet(integer: row) else { return }
                model?.selectedFileDoubleClicked()
            }
        }
        guard outline.selectedRowIndexes == IndexSet(integer: row) else {
            pressed = nil
            return
        }
        pressed = (row, event.locationInWindow)
        finishOnRelease()
    }

    /// The list may track the mouse in a loop of its own and keep the mouse-up
    /// from monitors. On macOS 27 that loop is over by the next pass of the run
    /// loop; on macOS 26 it may not have started yet, the button is still down,
    /// and checking once lost the click: only the disclosure triangle toggled.
    private func finishOnRelease(after delay: TimeInterval = 0, triesLeft: Int = 60) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            // Gone once a mouse-up reached the monitor and finished it.
            guard let self, pressed != nil, let window = outline?.window else { return }
            guard NSEvent.pressedMouseButtons & 1 == 0 else {
                if triesLeft > 0 { finishOnRelease(after: 0.03, triesLeft: triesLeft - 1) } else { pressed = nil }
                return
            }
            finish(at: window.convertPoint(fromScreen: NSEvent.mouseLocation))
        }
    }

    private func finish(at location: NSPoint) {
        guard let pressed, let outline else { return }
        self.pressed = nil
        guard outline.row(at: outline.convert(location, from: nil)) == pressed.row,
              hypot(location.x - pressed.location.x, location.y - pressed.location.y) < 4 else { return }
        model?.selectedFolderClicked()
    }
}

/// Hides row views the outline no longer places at any row once a folder has
/// opened or closed. Instant expansion (D123) didn't stop every stale copy of
/// the previously selected row from staying drawn over the tree.
@MainActor
final class StaleRowSweeper {
    private weak var outline: NSOutlineView?
    private var observers: [NSObjectProtocol] = []
    private var pending: DispatchWorkItem?

    func watch(_ outline: NSOutlineView) {
        guard self.outline !== outline else { return }
        stop()
        self.outline = outline
        for name in [NSOutlineView.itemDidExpandNotification, NSOutlineView.itemDidCollapseNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: outline, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule() }
            })
        }
    }

    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        pending?.cancel()
        pending = nil
    }

    /// After the outline's own row animations, should it have run any.
    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.sweep() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // The outline keeps reusable row views as hidden subviews and unhides them itself.
    private func sweep() {
        guard let outline else { return }
        let visible = outline.visibleRect
        for case let row as NSTableRowView in outline.subviews
        where !row.isHidden && row.frame.intersects(visible) && outline.row(for: row) < 0 {
            row.isHidden = true
        }
    }
}

/// A row that takes files dragged onto it into `folder` (D92); a folder's row
/// lights up while it's the target.
struct FolderDrop: ViewModifier {
    let folder: URL
    let model: FileTreeModel
    var highlights = true

    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self) { urls, _ in
                model.drop(urls, into: folder)
            } isTargeted: { model.setDropTarget(folder, $0) }
            .background {
                if highlights, model.dropTarget == folder {
                    Capsule()
                        .fill(Theme.dropFill)
                        .strokeBorder(Theme.dropBorder, lineWidth: 1)
                        .padding(.horizontal, -6)
                        .padding(.vertical, -2)
                }
            }
    }
}

/// A tree row tinted by its git status: files get a letter, folders a dot;
/// git-ignored rows are dimmed like in VS Code; symlinks get Finder's
/// alias arrow, broken ones are dimmed too.
struct FileLabel: View {
    let url: URL
    let kind: FileChangeKind?
    let isFolder: Bool
    var isExpanded = false
    var isIgnored = false
    var link: FileNode.Link?
    /// Set in the explorer: the name turns into a field while it's renamed.
    var model: FileTreeModel?

    var body: some View {
        HStack(spacing: 4) {
            Label {
                Group {
                    if let model, model.renaming == url {
                        NameField(name: url.lastPathComponent, selectsExtension: isFolder) { model.finishRenaming(url, to: $0) } cancel: { model.renaming = nil }
                    } else {
                        Text(url.lastPathComponent)
                            .foregroundStyle(kind.map { AnyShapeStyle($0.color) } ?? (isDimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary)))
                            .lineLimit(1)
                    }
                }
                // Tighter icon–title gap than the sidebar's; the system label
                // style is kept so the icon keeps its place after the chevron.
                .padding(.leading, -3)
            } icon: {
                FileIconView(url: url, isFolder: isFolder, isExpanded: isExpanded)
                    .opacity(isDimmed ? 0.5 : 1)
            }
            Spacer(minLength: 2)
            if link != nil {
                Image(systemName: "arrow.up.right")
                    .orbitFont(.micro, weight: .semibold)
                    .foregroundStyle(.tertiary)
            }
            if let kind {
                if isFolder {
                    Circle()
                        .fill(kind.color.opacity(0.75))
                        .frame(width: 5, height: 5)
                        .padding(.trailing, 3)
                } else {
                    Text(kind.badge)
                        .orbitFont(.micro, weight: .semibold, design: .monospaced)
                        .foregroundStyle(kind.color)
                }
            }
        }
        // The empty part of the row counts too (drag, right-click).
        .contentShape(.rect)
        .help(ifAny: link?.help)
    }

    private var isDimmed: Bool { isIgnored || link?.isBroken == true }
}

private extension View {
    /// A tooltip only on the rows that have one: an empty `.help` on every
    /// row of a big tree still sets one up for each.
    @ViewBuilder func help(ifAny text: String?) -> some View {
        if let text { help(text) } else { self }
    }
}

/// What follows the pointer while a file is dragged: its icon and name on
/// glass, in the window's appearance (the drag image is drawn outside it).
struct DragPreview: View {
    let url: URL
    let isFolder: Bool
    let colorScheme: ColorScheme

    var body: some View {
        HStack(spacing: 6) {
            FileIconView(url: url, isFolder: isFolder)
            Text(url.lastPathComponent)
                .orbitFont(.body, weight: .medium)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: .capsule)
        .environment(\.colorScheme, colorScheme)
    }
}

/// Keys on the selected row: Finder's Return (rename) and ⌘⌫ (trash),
/// Cursor's ⌃↩ (open to the side), Space keeps the previewed file's tab,
/// Escape goes to the editor (D98). Arrows are the list's own; ⌥⌘R and ⌥⌘C
/// are commands, ⌘X ⌘C ⌘V come through Edit.
struct FileKeys: ViewModifier {
    let model: FileTreeModel

    /// A name field has the keys (its field editor is a text view).
    private var isEditingText: Bool { NSApp.keyWindow?.firstResponder is NSTextView }

    func body(content: Content) -> some View {
        content
            // Only these keys: everything else (arrows) stays the list's.
            .onKeyPress(keys: [.return, .delete, .space, .escape], phases: .down) { _ in
                guard !isEditingText, let event = NSApp.currentEvent, event.type == .keyDown,
                      let item = model.selectedItem else { return .ignored }
                let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
                switch (event.charactersIgnoringModifiers?.lowercased(), modifiers) {
                case ("\r", []):
                    guard model.renaming == nil, model.creating == nil else { return .ignored }
                    model.startRenaming(item)
                case ("\r", [.control]):
                    model.workspace.openBeside(.file(item))
                case ("\u{7f}", [.command]):
                    model.trash(model.targets(for: item))
                case (" ", []):
                    guard model.node(for: item)?.isDirectory != true else { return .ignored }
                    model.workspace.openFile(item, focus: false)
                    model.workspace.pin(EditorTab.file(item).id)
                case ("\u{1b}", []):
                    guard model.renaming == nil, model.creating == nil else { return .ignored }
                    model.workspace.focusEditor()
                default:
                    return .ignored
                }
                return .handled
            }
            // Not `onCopyCommand`: SwiftUI exports its item providers as copies
            // in a cache folder, so Cut didn't move, a folder pasted on itself
            // went into itself and Finder got the copies (D252).
            .onCommand(#selector(NSText.copy(_:))) { copyItems(cut: false) }
            .onCommand(#selector(NSText.cut(_:))) { copyItems(cut: true) }
            // Paste as well: `onPasteCommand` checked the pasteboard late, a paste right after a copy did nothing.
            .onCommand(#selector(NSText.paste(_:))) { if !isEditingText { model.paste(into: model.targetFolder) } }
    }

    private func copyItems(cut: Bool) {
        guard !isEditingText, let item = model.selectedItem else { return }
        model.copyItems(model.targets(for: item), cut: cut)
    }
}

/// The project's name above the tree; New File and New Folder show on hover, as in Cursor.
struct ExplorerHeader: View {
    let root: FileNode
    let model: FileTreeModel
    let commands: CommandRegistry
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            Text(root.name)
                .lineLimit(1)
            Spacer(minLength: 4)
            if isHovered {
                IconButton("doc.badge.plus", help: commands.help("explorer.newFile", "New File")) {
                    model.startCreating(in: root.url, isFolder: false)
                }
                IconButton("folder.badge.plus", help: commands.help("explorer.newFolder", "New Folder")) {
                    model.startCreating(in: root.url, isFolder: true)
                }
            }
        }
        .frame(height: 22)
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .contextMenu { FileContextMenu(url: root.url, isFolder: true, isRoot: true, model: model) }
    }
}

/// A name being typed in a row: Return or clicking away keeps it, Escape
/// cancels. A file's name is selected up to its extension, as in Finder.
struct NameField: View {
    let selectsExtension: Bool
    let commit: (String) -> Void
    let cancel: () -> Void
    @State private var name: String
    @State private var selection: TextSelection?
    @State private var isDone = false
    @FocusState private var isFocused: Bool

    init(name: String, selectsExtension: Bool, commit: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        _name = State(initialValue: name)
        self.selectsExtension = selectsExtension
        self.commit = commit
        self.cancel = cancel
    }

    var body: some View {
        TextField("", text: $name, selection: $selection)
            .textFieldStyle(.plain)
            .focused($isFocused)
            .padding(.horizontal, 6)
            .background(Color(nsColor: .textBackgroundColor), in: .capsule)
            .overlay(Capsule().strokeBorder(Theme.accent, lineWidth: 1))
            .onSubmit { finish(cancelled: false) }
            .onExitCommand { finish(cancelled: true) }
            .onChange(of: isFocused) { _, focused in if !focused { finish(cancelled: false) } }
            .task {
                isFocused = true
                let end = selectsExtension ? name.endIndex : name.lastIndex(of: ".").flatMap { $0 == name.startIndex ? nil : $0 } ?? name.endIndex
                selection = TextSelection(range: name.startIndex..<end)
            }
    }

    private func finish(cancelled: Bool) {
        guard !isDone else { return }
        isDone = true
        if cancelled { cancel() } else { commit(name) }
    }
}

/// Cursor's menu, what of it Orbit has: open, reveal, agents, the clipboard,
/// paths, then rename and delete (D95).
struct FileContextMenu: View {
    let url: URL
    let isFolder: Bool
    var isRoot = false
    let model: FileTreeModel

    private var targets: [URL] { model.targets(for: url) }

    var body: some View {
        if isFolder {
            Button("New File…") { model.startCreating(in: url, isFolder: false) }
            Button("New Folder…") { model.startCreating(in: url, isFolder: true) }
        } else {
            Button("Open to the Side") { model.workspace.openBeside(.file(url)) }
                .keyboardShortcut(.return, modifiers: .control)
            OpenWithMenu(url: url)
            Divider()
            if targets.count == 2 {
                Button("Compare Selected") { model.workspace.open(CompareFiles.tab(targets[0], targets[1])) }
            } else if let selected = model.compareSelection, selected != url {
                Button("Compare with “\(selected.lastPathComponent)”") { model.compare(with: url) }
            }
            Button("Select for Compare") { model.compareSelection = url }
        }
        Divider()
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            .keyboardShortcut("r", modifiers: [.option, .command])
        if model.terminal != nil {
            Button("Open in Integrated Terminal") { model.openTerminal(at: url) }
        }
        if isFolder, let search = model.search {
            Button("Find in Folder…") { search.findInFolder(url) }
        }
        if let agents = model.agentTasks {
            Divider()
            Button(targets.count > 1 ? "Add \(targets.count) Items to Agent Chat" : "Add to Agent Chat") {
                for target in targets { agents.attachFile(target) }
            }
            Button("Add to New Agent Chat") {
                agents.attachFileToNewChat(targets[0])
                for target in targets.dropFirst() { agents.attachFile(target) }
            }
        }
        Divider()
        if !isRoot {
            Button("Cut") { model.copyItems(targets, cut: true) }
                .keyboardShortcut("x", modifiers: .command)
            Button("Copy") { model.copyItems(targets, cut: false) }
                .keyboardShortcut("c", modifiers: .command)
        }
        Button("Paste") { model.paste(into: url) }
            .keyboardShortcut("v", modifiers: .command)
            .disabled(!model.canPaste)
        Divider()
        Button(targets.count > 1 ? "Copy \(targets.count) Paths" : "Copy Path") { model.copyPaths(targets, relative: false) }
            .keyboardShortcut("c", modifiers: [.option, .command])
        Button(targets.count > 1 ? "Copy \(targets.count) Relative Paths" : "Copy Relative Path") { model.copyPaths(targets, relative: true) }
            .keyboardShortcut("c", modifiers: [.shift, .option, .command])
        if !isRoot {
            Divider()
            if targets.count == 1 {
                Button("Rename…") { model.startRenaming(url) }
                    .keyboardShortcut(.return, modifiers: [])
            }
            Button(targets.count > 1 ? "Move \(targets.count) Items to Trash" : "Move to Trash") { model.trash(targets) }
                .keyboardShortcut(.delete, modifiers: .command)
        }
    }
}

/// The apps that open the file, the default one first, as in Finder.
struct OpenWithMenu: View {
    let url: URL

    var body: some View {
        Menu("Open With") {
            let preferred = NSWorkspace.shared.urlForApplication(toOpen: url)
            let others = NSWorkspace.shared.urlsForApplications(toOpen: url)
                .filter { $0 != preferred }
                .sorted { name(of: $0).localizedStandardCompare(name(of: $1)) == .orderedAscending }
            if let preferred {
                app(preferred, title: "\(name(of: preferred)) (default)")
                if !others.isEmpty { Divider() }
            }
            ForEach(others, id: \.self) { app($0, title: name(of: $0)) }
            Divider()
            Button("Other…") { chooseApp() }
        }
    }

    private func app(_ app: URL, title: String) -> some View {
        Button {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(nsImage: icon(of: app))
            }
        }
    }

    private func name(of app: URL) -> String {
        FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    private func icon(of app: URL) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: app.path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Open"
        guard panel.runSheetModal() == .OK, let app = panel.url else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
