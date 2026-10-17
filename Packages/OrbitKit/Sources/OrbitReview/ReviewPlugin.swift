import OrbitAPI
import OrbitUI
import SwiftUI

public final class ReviewPlugin: OrbitPlugin {
    public static let manifest = PluginManifest(
        id: "orbit.review",
        name: "Change Review",
        summary: "Review agent edits: keep or revert each change.",
        systemImage: "checklist"
    )

    public init() {}

    public func activate(_ context: PluginContext) {
        let tracker = ChangeTracker(workspace: context.workspace)
        context.services.register(ChangeTracking.self, tracker)
        context.services.register(AgentIsolation.self, IsolatedCopies(workspace: context.workspace, tracker: tracker))

        // The changed-files list lives above the agent chat's composer (Agents
        // plugin, through ChangeTracking): edits are reviewed where they're made.

        #if DEBUG
        let workspace = context.workspace
        context.commands.register(OrbitCommand(
            id: "debug.simulateAgentEdit",
            title: "Debug: Simulate Agent Edit",
            category: "Debug",
            isEnabled: { workspace.activeTab?.url != nil }
        ) {
            guard let url = workspace.activeTab?.url, let text = workspace.documents.currentText(of: url) else { return }
            tracker.recordBaseline(text, for: url)
            var lines = LineDiff.lines(text)
            // A modification, a pure deletion, a pure insertion and a change at the end.
            if lines.count > 6 {
                lines[1] = "// edited by a pretend agent"
                lines[3] = lines[3] + " // tweaked"
                lines.remove(at: 4)
                lines.insert(contentsOf: ["    // inserted line A", "    // inserted line B"], at: 6)
            }
            lines.append("// appended at the end")
            try? workspace.documents.write(lines.joined(separator: "\n"), to: url)
            workspace.fileSystemDidChange()
        })
        #endif

        context.commands.register(OrbitCommand(
            id: "review.acceptAll",
            title: "Accept All Agent Changes",
            category: "Review",
            systemImage: "checkmark.circle",
            shortcut: KeyboardShortcut(.return, modifiers: [.command, .shift]),
            isEnabled: { !tracker.changedFiles.isEmpty }
        ) { tracker.acceptAll() })

        context.commands.register(OrbitCommand(
            id: "review.rejectAll",
            title: "Reject All Agent Changes",
            category: "Review",
            systemImage: "arrow.uturn.backward.circle",
            shortcut: KeyboardShortcut(.delete, modifiers: [.command, .shift]),
            isEnabled: { !tracker.changedFiles.isEmpty }
        ) { tracker.rejectAll() })
    }
}

@MainActor
@Observable
final class ChangeTracker: ChangeTracking {
    private let workspace: Workspace
    /// Contents of each file before the agent first touched it. `nil` = file didn't exist.
    private var baselines: [URL: String?] = [:]
    private var order: [URL] = []
    var lastError: String?

    init(workspace: Workspace) {
        self.workspace = workspace
    }

    var changedFiles: [URL] {
        // Re-read when the disk changes so files that converged drop out.
        _ = workspace.fileSystemGeneration
        return order.filter(hasChanges)
    }

    // MARK: Checkpoints

    private var turnTree: String?
    private var checkpointRoot: URL?
    private var activeTurns = 0

    func beginAgentTurn() async -> String? {
        activeTurns += 1
        // Parallel sessions share one baseline so a running turn's isn't lost;
        // each turn still gets its own restore point.
        let isFirstTurn = activeTurns == 1 || turnTree == nil
        guard let root = workspace.root else { return nil }
        let checkpoints = Checkpoints(root: root)
        do {
            let tree = try await serialized {
                await Task.detached(priority: .userInitiated) { Result { try checkpoints.snapshot() } }.value
            }.get()
            if isFirstTurn {
                turnTree = tree
                checkpointRoot = root
            }
            lastError = nil
            return tree
        } catch {
            lastError = "Couldn't snapshot workspace: \(error.localizedDescription)"
            return nil
        }
    }

    func restore(_ checkpoint: String) async throws -> [URL] {
        guard activeTurns == 0 else {
            throw CocoaError(.userCancelled, userInfo: [NSLocalizedDescriptionKey: "An agent is working; wait for it to finish."])
        }
        guard let root = workspace.root else { return [] }
        let checkpoints = Checkpoints(root: root)
        let files = try await serialized {
            await Task.detached(priority: .userInitiated) { Result { try checkpoints.snapshotContents(since: checkpoint) } }.value
        }.get()
        let fm = FileManager.default
        for (url, contents) in files {
            let current = current(for: url)
            let exists = fm.fileExists(atPath: url.path)
            let text = contents.flatMap { $0.contains(0) ? nil : String(data: $0, encoding: .utf8) }
            // Binary files can't be reviewed inline: they're just put back.
            let isReviewable = (contents == nil || text != nil) && (!exists || current != nil)
            if isReviewable { recordBaseline(exists ? current : nil, for: url) }
            if let text {
                try workspace.documents.write(text, to: url)
            } else if let contents {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try contents.write(to: url, options: .atomic)
            } else {
                try fm.trashItem(at: url, resultingItemURL: nil)
                workspace.close("file:\(url.path)")
            }
            if isReviewable { cleanUp(url) }
        }
        workspace.fileSystemDidChange()
        return files.map(\.url)
    }

    @ObservationIgnored private var gitQueue: Task<Void, Never>?

    /// The shadow repository's git work, one batch at a time: two `git add`s on
    /// one index fail on its lock, and a refresh that failed left changes unseen.
    private func serialized<T: Sendable>(_ work: @escaping @MainActor () async -> T) async -> T {
        let previous = gitQueue
        let task = Task { @MainActor in
            await previous?.value
            return await work()
        }
        gitQueue = Task { _ = await task.value }
        return await task.value
    }

    func endAgentTurn() async {
        await refreshAgentChanges()
        activeTurns = max(0, activeTurns - 1)
    }

    func refreshAgentChanges() async {
        guard let tree = turnTree, let root = checkpointRoot, root == workspace.root else { return }
        let checkpoints = Checkpoints(root: root)
        let changes = await serialized {
            // Read when the run starts: the runs before it may have recorded more.
            let known = Set(self.baselines.keys)
            return await Task.detached(priority: .userInitiated) { try? checkpoints.changes(since: tree, skipping: known) }.value
        }
        guard let changes else { return }
        for change in changes {
            recordBaseline(change.baseline, for: change.url)
        }
        workspace.fileSystemDidChange()
    }

    func recordBaseline(_ text: String?, for url: URL) {
        let url = url.standardizedFileURL
        guard baselines[url] == nil else { return }
        // Git has the bytes; buffers have `\n` line breaks (TextFile).
        baselines[url] = .some(text.map(TextFile.normalized))
        order.append(url)
    }

    func baseline(for url: URL) -> String? {
        baselines[url.standardizedFileURL] ?? nil
    }

    /// Changed files that aren't open, as last read: the changes list, gutters
    /// and commands ask on every redraw, and a stat is far cheaper than a read.
    @ObservationIgnored private var diskTexts: [URL: (stamp: DiskStamp?, text: String?)] = [:]
    /// The last diff of each file, reused while neither side changed.
    @ObservationIgnored private var diffs: [URL: (old: String, new: String, hunks: [DiffHunk])] = [:]

    func current(for url: URL) -> String? {
        let url = url.standardizedFileURL
        if let document = workspace.documents.existingDocument(for: url) { return document.text }
        let stamp = DiskStamp(url)
        if let cached = diskTexts[url], cached.stamp == stamp, stamp != nil { return cached.text }
        let text = workspace.documents.currentText(of: url)
        if baselines[url] != nil { diskTexts[url] = (stamp, text) }
        return text
    }

    func hasChanges(_ url: URL) -> Bool {
        let url = url.standardizedFileURL
        guard let entry = baselines[url] else { return false }
        _ = workspace.documents.existingDocument(for: url)?.revision
        let current = current(for: url)
        return (entry ?? "") != (current ?? "") || (entry == nil) != (current == nil)
    }

    func stats(for url: URL) -> (added: Int, removed: Int) {
        // One hunk per change block: the same counts as `LineDiff.stats`, from the cached diff.
        hunks(for: url).reduce(into: (0, 0)) { total, hunk in
            total.0 += hunk.added
            total.1 += hunk.removed
        }
    }

    func hunks(for url: URL) -> [DiffHunk] {
        let url = url.standardizedFileURL
        guard hasChanges(url) else { return [] }
        let old = baseline(for: url) ?? "", new = current(for: url) ?? ""
        if let cached = diffs[url], cached.old == old, cached.new == new { return cached.hunks }
        let hunks = LineDiff.hunks(old: old, new: new, context: 3)
        diffs[url] = (old, new, hunks)
        return hunks
    }

    func openReview(for url: URL) {
        let url = url.standardizedFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            workspace.openFile(url, line: hunks(for: url).first?.newRange.lowerBound ?? 0)
        }
    }

    func keep(_ hunk: DiffHunk, in url: URL) {
        let url = url.standardizedFileURL
        let newBaseline = LineDiff.keep(hunk, current: current(for: url) ?? "", baseline: baseline(for: url) ?? "")
        baselines[url] = .some(newBaseline)
        cleanUp(url)
    }

    func revert(_ hunk: DiffHunk, in url: URL) {
        let url = url.standardizedFileURL
        let reverted = LineDiff.revert(hunk, current: current(for: url) ?? "", baseline: baseline(for: url) ?? "")
        write(reverted, to: url)
        cleanUp(url)
    }

    func accept(_ url: URL) {
        let url = url.standardizedFileURL
        baselines[url] = nil
        diskTexts[url] = nil
        diffs[url] = nil
        order.removeAll { $0 == url }
    }

    func reject(_ url: URL) {
        let url = url.standardizedFileURL
        guard let entry = baselines[url] else { return }
        if let text = entry {
            write(text, to: url)
        } else {
            // Agent created this file: rejecting deletes it.
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            workspace.close("file:\(url.path)")
        }
        accept(url)
        workspace.fileSystemDidChange()
    }

    func acceptAll() {
        for url in order { accept(url) }
    }

    func rejectAll() {
        for url in order { reject(url) }
    }

    private func write(_ text: String, to url: URL) {
        do {
            try workspace.documents.write(text, to: url)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func cleanUp(_ url: URL) {
        if !hasChanges(url) { accept(url) }
    }
}

/// What changes whenever a file's contents do: size, inode (atomic saves
/// replace the file) and modification time to the nanosecond.
private struct DiskStamp: Equatable {
    let size: Int64
    let inode: UInt64
    let seconds: Int
    let nanoseconds: Int

    init?(_ url: URL) {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        size = Int64(info.st_size)
        inode = UInt64(info.st_ino)
        seconds = info.st_mtimespec.tv_sec
        nanoseconds = info.st_mtimespec.tv_nsec
    }
}
