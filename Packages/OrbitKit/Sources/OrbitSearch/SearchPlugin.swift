import Foundation
import OrbitAPI
import SwiftUI

public final class SearchPlugin: OrbitPlugin {
    public static let manifest = PluginManifest(
        id: "orbit.search",
        name: "Search",
        summary: "Open Quickly (⌘P) and find in project.",
        systemImage: "magnifyingglass"
    )

    public init() {}

    public func activate(_ context: PluginContext) {
        let workspace = context.workspace
        let ui = context.ui
        let files = ProjectFiles(workspace: workspace)
        let search = SearchModel(workspace: workspace, files: files)
        context.services.register(ProjectFileIndex.self, SearchFileIndex(workspace: workspace, files: files))

        ui.addSidebarPanel(PanelContribution(id: "search", title: "Search", systemImage: "magnifyingglass", order: 5) {
            SearchPanel(model: search, workspace: workspace)
        }.command("search.findInProject"))

        context.commands.register(OrbitCommand(
            id: "search.quickOpen",
            title: "Open Quickly…",
            category: "File",
            systemImage: "doc.text.magnifyingglass",
            shortcut: KeyboardShortcut("p", modifiers: .command),
            isEnabled: { workspace.root != nil }
        ) {
            files.refreshIfNeeded()
            ui.toggleQuickPick(QuickOpen.pick(workspace: workspace, files: files))
        })

        context.commands.register(OrbitCommand(
            id: "search.findInProject",
            title: "Find in Project…",
            category: "File",
            systemImage: "text.magnifyingglass",
            shortcut: KeyboardShortcut("f", modifiers: [.command, .shift]),
            isEnabled: { workspace.root != nil }
        ) {
            ui.revealSidebarPanel("search")
            search.focusRequest += 1
        })
    }
}

/// The ⌘P index and ranking, for other plugins' file pickers.
@MainActor
final class SearchFileIndex: ProjectFileIndex {
    private let workspace: Workspace
    private let files: ProjectFiles

    init(workspace: Workspace, files: ProjectFiles) {
        self.workspace = workspace
        self.files = files
    }

    func search(_ query: String, limit: Int) -> [String] {
        files.refreshIfNeeded()
        let recent = QuickOpen.recentPaths(workspace: workspace)
        if query.trimmingCharacters(in: .whitespaces).isEmpty { return Array(recent.prefix(limit)) }
        let bonus = Dictionary(recent.enumerated().map { ($0.element, $0.offset < 10 ? 15 : 5) }, uniquingKeysWith: max)
        return QuickOpen.rank(query, entries: files.entries, recentBonus: bonus, limit: limit).map(\.path)
    }

    func allPaths() async -> [String] {
        await files.current()?.paths ?? []
    }
}

/// ⌘P: fuzzy file finder over the project index.
@MainActor
enum QuickOpen {
    static func pick(workspace: Workspace, files: ProjectFiles) -> QuickPick {
        QuickPick(id: "search.quickOpen", placeholder: "Open file by name") { query in
            guard let root = files.root else { return [] }
            let recent = recentPaths(workspace: workspace)
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                // The current file is left out so ⌘P ↩ jumps back to the previous one.
                let current = workspace.activeTab?.url.map(workspace.relativePath)
                return recent.filter { $0 != current }.map { path in
                    item(path: path, root: root, positions: [], workspace: workspace)
                }
            }
            let bonus = Dictionary(recent.enumerated().map { ($0.element, $0.offset < 10 ? 15 : 5) }, uniquingKeysWith: max)
            return rank(query, entries: files.entries, recentBonus: bonus).map { path, positions in
                item(path: path, root: root, positions: positions, workspace: workspace)
            }
        }
    }

    /// Recently active project files that still exist, newest first.
    static func recentPaths(workspace: Workspace) -> [String] {
        workspace.recentFiles.compactMap { url in
            let path = workspace.relativePath(url)
            return path != url.path && FileManager.default.fileExists(atPath: url.path) ? path : nil
        }
    }

    /// File-name matches beat path matches; within a tier higher scores and shorter paths win.
    /// Recently opened files get a small nudge so they win near-ties.
    nonisolated static func rank(
        _ query: String,
        entries: [IndexedPath],
        recentBonus: [String: Int] = [:],
        limit: Int = 80
    ) -> [(path: String, namePositions: [Int])] {
        let needle = PathMatcher.needle(query)
        var scored: [(path: String, score: Int, positions: [Int])] = []
        for entry in entries {
            guard let (score, positions) = match(query, needle: needle, entry: entry) else { continue }
            scored.append((entry.path, score + (recentBonus[entry.path] ?? 0), positions))
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.path.utf8.count != rhs.path.utf8.count { return lhs.path.utf8.count < rhs.path.utf8.count }
            return lhs.path < rhs.path
        }
        return scored.prefix(limit).map { ($0.path, $0.positions) }
    }

    private nonisolated static func match(_ query: String, needle: [UInt8]?, entry: IndexedPath) -> (score: Int, namePositions: [Int])? {
        let nameStart: Int
        let nameMatch: FuzzyMatch.Result?
        let pathMatch: () -> FuzzyMatch.Result?
        if let needle, entry.isASCII {
            nameStart = entry.nameStart
            nameMatch = PathMatcher.match(needle, in: entry, from: nameStart)
            pathMatch = { PathMatcher.match(needle, in: entry, from: 0) }
        } else {
            let name = (entry.path as NSString).lastPathComponent
            nameStart = entry.path.count - name.count
            nameMatch = FuzzyMatch.match(query, in: name)
            pathMatch = { FuzzyMatch.match(query, in: entry.path) }
        }
        if let nameMatch { return (nameMatch.score + 1000, nameMatch.positions) }
        guard let match = pathMatch() else { return nil }
        return (match.score, match.positions.filter { $0 >= nameStart }.map { $0 - nameStart })
    }

    private static func item(path: String, root: URL, positions: [Int], workspace: Workspace) -> QuickPickItem {
        let url = root.appendingPathComponent(path)
        let folder = (path as NSString).deletingLastPathComponent
        return QuickPickItem(
            id: path,
            title: FuzzyMatch.highlighted(url.lastPathComponent, positions: positions),
            subtitle: folder.isEmpty ? nil : folder,
            systemImage: FileIcon.systemImage(for: url),
            fileURL: url
        ) {
            workspace.openFile(url)
        }
    }
}
