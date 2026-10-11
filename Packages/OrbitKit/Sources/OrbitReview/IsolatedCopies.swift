import Foundation
import OrbitAPI

/// Isolated copies are APFS clones of the whole project folder: made in one
/// syscall, sharing disk blocks until either side changes, and complete —
/// uncommitted work, untracked files, `node_modules` and `.env` included, so
/// the agent can build and run tests. A shadow-git snapshot of the copy
/// (`Checkpoints`) tells what the agent changed.
@MainActor
final class IsolatedCopies: AgentIsolation {
    private let workspace: Workspace
    private let tracker: ChangeTracker

    init(workspace: Workspace, tracker: ChangeTracker) {
        self.workspace = workspace
        self.tracker = tracker
    }

    nonisolated static var storage: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Orbit/isolated", isDirectory: true)
    }

    func makeCopy(of project: URL) async throws -> IsolatedCopy {
        let project = project.standardizedFileURL
        // The folder keeps the project's name: agents mention it.
        let directory = Self.storage
            .appendingPathComponent(String(UUID().uuidString.prefix(8)).lowercased(), isDirectory: true)
            .appendingPathComponent(project.lastPathComponent, isDirectory: true)
        let checkpoint = try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.clone(project, to: directory)
            return try Checkpoints(root: directory).snapshot()
        }.value
        return IsolatedCopy(project: project, directory: directory, checkpoint: checkpoint)
    }

    private nonisolated static func clone(_ source: URL, to destination: URL) throws {
        if clonefile(source.path, destination.path, 0) == 0 { return }
        // Not APFS, or another volume: a real copy.
        try FileManager.default.copyItem(at: source, to: destination)
    }

    func unappliedChanges(in copy: IsolatedCopy) async -> [URL] {
        await Self.changes(in: copy).compactMap { change in
            let target = copy.project.appendingPathComponent(change.path).standardizedFileURL
            return isApplied(change, to: target) ? nil : target
        }
    }

    func apply(_ copy: IsolatedCopy) async -> IsolatedApplyResult {
        var result = IsolatedApplyResult()
        let fileManager = FileManager.default
        for change in await Self.changes(in: copy) {
            let target = copy.project.appendingPathComponent(change.path).standardizedFileURL
            guard !isApplied(change, to: target) else { continue }
            let current = workspace.documents.currentText(of: target)
            do {
                if let data = change.contents, let theirs = String(data: data, encoding: .utf8) {
                    // The project may have moved on since the copy was made: merge when it's on other lines.
                    let merged: String? = current == change.baseline ? theirs
                        : change.baseline.flatMap { base in current.flatMap { LineDiff.merge(base: base, mine: $0, theirs: theirs) } }
                    guard let merged else {
                        result.conflicts.append(target)
                        continue
                    }
                    tracker.recordBaseline(current, for: target)
                    try workspace.documents.write(merged, to: target)
                } else if let data = change.contents {
                    // Binary: no review, no merge.
                    try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: target, options: .atomic)
                } else {
                    guard current == change.baseline else {
                        result.conflicts.append(target)
                        continue
                    }
                    tracker.recordBaseline(current, for: target)
                    try fileManager.trashItem(at: target, resultingItemURL: nil)
                    workspace.close("file:\(target.path)")
                }
                result.applied.append(target)
            } catch {
                result.conflicts.append(target)
            }
        }
        workspace.fileSystemDidChange()
        return result
    }

    func discard(_ copy: IsolatedCopy) {
        let folder = copy.directory.deletingLastPathComponent().standardizedFileURL
        // Only ever delete what we made.
        guard folder.path.hasPrefix(Self.storage.standardizedFileURL.path + "/") else { return }
        let shadow = Checkpoints(root: copy.directory).gitDir
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: shadow)
        }
    }

    func discardCopies(except kept: [IsolatedCopy]) {
        let storage = Self.storage
        let keep = Set(kept.map { $0.directory.deletingLastPathComponent().standardizedFileURL.lastPathComponent })
        Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            guard let folders = try? fileManager.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil) else { return }
            for folder in folders where !keep.contains(folder.lastPathComponent) {
                let copies = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                for copy in copies { try? fileManager.removeItem(at: Checkpoints(root: copy).gitDir) }
                try? fileManager.removeItem(at: folder)
            }
        }
    }

    // MARK: Changes in a copy

    private struct Change: Sendable {
        /// Relative to the copy (and so to the project).
        var path: String
        /// At the time of the copy; nil for a new file.
        var baseline: String?
        /// Now; nil when deleted.
        var contents: Data?
    }

    private nonisolated static func changes(in copy: IsolatedCopy) async -> [Change] {
        await Task.detached(priority: .userInitiated) {
            let root = copy.directory.standardizedFileURL.path + "/"
            guard let changes = try? Checkpoints(root: copy.directory).changes(since: copy.checkpoint) else { return [] }
            return changes.compactMap { change in
                guard change.url.path.hasPrefix(root) else { return nil }
                return Change(path: String(change.url.path.dropFirst(root.count)), baseline: change.baseline, contents: try? Data(contentsOf: change.url))
            }
        }.value
    }

    /// The project already has the agent's changes to this file (applied earlier,
    /// possibly merged with the user's own edits, or made the same way).
    private func isApplied(_ change: Change, to target: URL) -> Bool {
        guard let data = change.contents else { return !FileManager.default.fileExists(atPath: target.path) }
        guard let text = String(data: data, encoding: .utf8) else { return (try? Data(contentsOf: target)) == data }
        guard let current = workspace.documents.currentText(of: target) else { return false }
        if current == text { return true }
        // Merging again would add nothing.
        guard let base = change.baseline else { return false }
        return LineDiff.merge(base: base, mine: current, theirs: text) == current
    }
}
