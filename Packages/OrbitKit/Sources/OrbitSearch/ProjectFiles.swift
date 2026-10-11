import Foundation
import OrbitAPI

/// Project-relative paths of every searchable file, refreshed in the background
/// when the folder or the files on disk change.
@MainActor
@Observable
final class ProjectFiles {
    private let workspace: Workspace
    private(set) var paths: [String] = []
    /// The same paths prepared for fast fuzzy matching (⌘P runs on every keystroke).
    private(set) var entries: [IndexedPath] = []
    private(set) var root: URL?
    private var loadedGeneration = -1
    private var loading: Task<Void, Never>?

    init(workspace: Workspace) {
        self.workspace = workspace
    }

    /// Cheap to call often: reloads only when the root or generation moved.
    func refreshIfNeeded() {
        guard root != workspace.root || loadedGeneration != workspace.fileSystemGeneration else { return }
        loadedGeneration = workspace.fileSystemGeneration
        guard let root = workspace.root else {
            self.root = nil
            paths = []
            entries = []
            return
        }
        if self.root != root {
            paths = []
            entries = []
        }
        self.root = root
        loading?.cancel()
        loading = Task {
            let (paths, entries) = await Task.detached(priority: .userInitiated) {
                let paths = FileLister.list(root: root)
                return (paths, paths.map(IndexedPath.init))
            }.value
            guard !Task.isCancelled, self.root == root else { return }
            self.paths = paths
            self.entries = entries
        }
    }

    /// Waits for an in-flight reload, for callers that need the full list (search).
    func current() async -> (root: URL, paths: [String])? {
        refreshIfNeeded()
        await loading?.value
        guard let root else { return nil }
        return (root, paths)
    }
}

enum FileLister {
    /// Directories never worth listing even outside git (build output, dependencies).
    static let ignoredNames: Set<String> = [".git", ".DS_Store", "node_modules", ".build", "DerivedData", ".swiftpm", "dist", ".next", ".turbo", "Pods"]

    /// Uses git when the folder is a repository so `.gitignore` is honoured.
    nonisolated static func list(root: URL) -> [String] {
        // An empty list also means the folder is ignored by an enclosing repository.
        let fromGit = gitFiles(root: root) ?? []
        let paths = fromGit.isEmpty ? walk(root: root) : fromGit
        return paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private nonisolated static func gitFiles(root: URL) -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "ls-files", "--cached", "--others", "--exclude-standard", "-z"]
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = env
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let fileManager = FileManager.default
        var seen = Set<String>()
        return data.split(separator: 0).compactMap { bytes in
            let path = String(decoding: bytes, as: UTF8.self)
            guard seen.insert(path).inserted, !path.split(separator: "/").contains(where: { ignoredNames.contains(String($0)) }) else { return nil }
            // The index still lists deleted files, and submodules show up as directories.
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: root.appendingPathComponent(path).path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { return nil }
            return path
        }
    }

    private nonisolated static func walk(root: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else { return [] }
        let rootPath = root.standardizedFileURL.path + "/"
        var paths: [String] = []
        for case let url as URL in enumerator {
            if ignoredNames.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let path = url.standardizedFileURL.path
            if !isDirectory, path.hasPrefix(rootPath) { paths.append(String(path.dropFirst(rootPath.count))) }
            // Huge folders without git (e.g. a home directory) shouldn't stall indexing.
            if paths.count >= 200_000 { break }
        }
        return paths
    }
}
