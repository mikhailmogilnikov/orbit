import OrbitAPI
import OrbitUI
import SwiftUI

public final class ExplorerPlugin: OrbitPlugin {
    public static let manifest = PluginManifest(
        id: "orbit.explorer",
        name: "Explorer",
        summary: "File tree of the open folder.",
        systemImage: "folder"
    )

    public init() {}

    public func activate(_ context: PluginContext) {
        let workspace = context.workspace
        let model = FileTreeModel(workspace: workspace)
        context.ui.addSidebarPanel(PanelContribution(id: "explorer", title: "Explorer", systemImage: "folder", order: 0) {
            ExplorerView(model: model, workspace: workspace, decorations: context.services.resolve(FileStatusProviding.self))
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
    }
}

@MainActor
@Observable
final class FileNode: Identifiable {
    let url: URL
    let isDirectory: Bool
    var isExpanded = false
    private(set) var children: [FileNode]?

    nonisolated var id: URL { url }
    var name: String { url.lastPathComponent }

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    static let ignored: Set<String> = [".git", ".DS_Store", "node_modules", ".build", "DerivedData", ".swiftpm", "dist", ".next", ".turbo", "Pods"]

    func loadChildren(force: Bool = false) {
        guard isDirectory, children == nil || force else { return }
        let keys: [URLResourceKey] = [.isDirectoryKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])) ?? []
        let previous = Dictionary(uniqueKeysWithValues: (children ?? []).map { ($0.url, $0) })
        children = urls
            .filter { !Self.ignored.contains($0.lastPathComponent) }
            .map { url in
                if let existing = previous[url] { return existing }
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return FileNode(url: url, isDirectory: isDir)
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        if force {
            for child in children ?? [] where child.isExpanded { child.loadChildren(force: true) }
        }
    }
}

@MainActor
@Observable
final class FileTreeModel {
    private let workspace: Workspace
    private(set) var root: FileNode?
    private var loadedRoot: URL?
    private var loadedGeneration = -1

    init(workspace: Workspace) {
        self.workspace = workspace
    }

    func sync() {
        guard let url = workspace.root else {
            root = nil
            loadedRoot = nil
            return
        }
        if loadedRoot != url {
            let node = FileNode(url: url, isDirectory: true)
            node.isExpanded = true
            node.loadChildren()
            root = node
            loadedRoot = url
        } else if loadedGeneration != workspace.fileSystemGeneration {
            root?.loadChildren(force: true)
        }
        loadedGeneration = workspace.fileSystemGeneration
    }
}

struct ExplorerView: View {
    let model: FileTreeModel
    let workspace: Workspace
    /// Git status colors; nil when the Git plugin is disabled.
    let decorations: FileStatusProviding?

    var body: some View {
        Group {
            if let root = model.root {
                List(selection: selectionBinding) {
                    Section(root.name) {
                        FileChildren(node: root, workspace: workspace, decorations: decorations)
                    }
                }
                .listStyle(.sidebar)
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
        .onAppear { model.sync() }
        .onChange(of: workspace.root) { model.sync() }
        .onChange(of: workspace.fileSystemGeneration) { model.sync() }
    }

    private var selectionBinding: Binding<URL?> {
        Binding(
            get: { workspace.activeTab?.url },
            set: { url in
                guard let url, !url.hasDirectoryPath, !isDirectory(url) else { return }
                workspace.openFile(url)
            }
        )
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }
}

struct FileChildren: View {
    let node: FileNode
    let workspace: Workspace
    let decorations: FileStatusProviding?

    var body: some View {
        ForEach(node.children ?? []) { child in
            if child.isDirectory {
                DisclosureGroup(isExpanded: Binding(
                    get: { child.isExpanded },
                    set: { expanded in
                        child.isExpanded = expanded
                        if expanded { child.loadChildren() }
                    }
                )) {
                    FileChildren(node: child, workspace: workspace, decorations: decorations)
                } label: {
                    FileLabel(url: child.url, kind: decorations?.folderStatus(of: child.url), isFolder: true, isExpanded: child.isExpanded)
                        .contextMenu { FileContextMenu(url: child.url) }
                }
            } else {
                FileLabel(url: child.url, kind: decorations?.status(of: child.url), isFolder: false)
                    .tag(child.url)
                    .contextMenu { FileContextMenu(url: child.url) }
            }
        }
    }
}

/// A tree row tinted by its git status: files get a letter, folders a dot.
struct FileLabel: View {
    let url: URL
    let kind: FileChangeKind?
    let isFolder: Bool
    var isExpanded = false

    var body: some View {
        HStack(spacing: 4) {
            Label {
                Text(url.lastPathComponent)
                    .foregroundStyle(kind.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(.primary))
                    .lineLimit(1)
            } icon: {
                FileIconView(url: url, isFolder: isFolder, isExpanded: isExpanded)
            }
            Spacer(minLength: 2)
            if let kind {
                if isFolder {
                    Circle()
                        .fill(kind.color.opacity(0.75))
                        .frame(width: 5, height: 5)
                        .padding(.trailing, 3)
                } else {
                    Text(kind.badge)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(kind.color)
                }
            }
        }
    }
}

struct FileContextMenu: View {
    let url: URL

    var body: some View {
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        }
    }
}
