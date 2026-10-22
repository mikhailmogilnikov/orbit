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
    private var loadedExclusions: [String] = []
    private var loading: Task<Void, Never>?

    init(workspace: Workspace) {
        self.workspace = workspace
    }

    /// Cheap to call often: reloads only when the root or generation moved.
    func refreshIfNeeded() {
        let exclusions = Preferences.shared.excludedFiles
        guard root != workspace.root || loadedGeneration != workspace.fileSystemGeneration || loadedExclusions != exclusions else { return }
        loadedGeneration = workspace.fileSystemGeneration
        loadedExclusions = exclusions
        let filter = Preferences.shared.fileExclusions
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
                let paths = FileLister.list(root: root).filter(filter.allows)
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

    /// Huge folders without git (e.g. a home directory) shouldn't stall indexing.
    static let limit = 200_000

    /// Uses git when the folder is a repository so `.gitignore` is honoured.
    /// Symlinks leading out of the project are listed under the link, as in the
    /// explorer (D238); ones into it aren't: their files are listed already (D239).
    nonisolated static func list(root: URL) -> [String] {
        var walk = Walk(root: root)
        // An empty list also means the folder is ignored by an enclosing repository.
        if !walk.addGitFiles(in: root, as: "") { walk.add(folder: root, as: "") }
        return walk.paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private struct Walk {
        let realRoot: String
        var paths: [String] = []
        /// Real paths of the folders listed so far through links: each is listed
        /// once, so links pointing at each other can't loop.
        var followed: Set<String>

        init(root: URL) {
            realRoot = root.realPath ?? root.standardizedFileURL.path
            followed = [realRoot]
        }

        /// What git lists in `folder` (tracked and untracked, ignores honoured);
        /// false when it lists nothing or `folder` isn't in a repository.
        mutating func addGitFiles(in folder: URL, as prefix: String) -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", folder.path, "ls-files", "--cached", "--others", "--exclude-standard", "-z"]
            var env = ProcessInfo.processInfo.environment
            env["GIT_OPTIONAL_LOCKS"] = "0"
            process.environment = env
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return false }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, !data.isEmpty else { return false }

            let folderPath = folder.standardizedFileURL.path
            var seen = Set<String>()
            for bytes in data.split(separator: 0) where paths.count < limit {
                let path = String(decoding: bytes, as: UTF8.self)
                guard seen.insert(path).inserted, !path.split(separator: "/").contains(where: { ignoredNames.contains(String($0)) }) else { continue }
                let full = folderPath + "/" + path
                // One lstat per file: the index still lists deleted files, submodules
                // show up as directories, and a symlink is one entry whatever it points to.
                var info = stat()
                guard lstat(full, &info) == 0 else { continue }
                switch info.st_mode & S_IFMT {
                case S_IFREG: paths.append(prefix + path)
                case S_IFLNK: add(link: URL(fileURLWithPath: full), as: prefix + path)
                default: continue
                }
            }
            return true
        }

        /// Everything under `folder`, its paths starting with `prefix`.
        mutating func add(folder: URL, as prefix: String) {
            guard let enumerator = FileManager.default.enumerator(
                at: folder,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsPackageDescendants]
            ) else { return }
            let folderPath = folder.standardizedFileURL.path + "/"
            for case let url as URL in enumerator {
                guard paths.count < limit else { return }
                if ignoredNames.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(folderPath) else { continue }
                let relative = prefix + path.dropFirst(folderPath.count)
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true {
                    add(link: url, as: relative)
                } else if values?.isDirectory != true {
                    paths.append(relative)
                }
            }
        }

        /// A link out of the project to a file is that file; one to a folder lists
        /// it under the link (by git when it's a repository), unless the folder
        /// holds the link (it would nest forever) or was listed already. Broken
        /// links are left out.
        mutating func add(link: URL, as relative: String) {
            guard let target = link.realPath, target != realRoot, !target.hasPrefix(realRoot + "/") else { return }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: target, isDirectory: &isDirectory) else { return }
            guard isDirectory.boolValue else {
                paths.append(relative)
                return
            }
            let holder = link.deletingLastPathComponent().realPath ?? ""
            guard holder != target, !holder.hasPrefix(target + "/"), followed.insert(target).inserted else { return }
            let folder = URL(fileURLWithPath: target, isDirectory: true)
            if !addGitFiles(in: folder, as: relative + "/") { add(folder: folder, as: relative + "/") }
        }
    }
}
