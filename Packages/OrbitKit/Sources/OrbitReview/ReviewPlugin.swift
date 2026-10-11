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

        context.ui.addSidebarPanel(PanelContribution(id: "changes", title: "Changes", systemImage: "plusminus", order: 10) {
            ChangesListView(tracker: tracker)
        })

        context.ui.addStatusItem(StatusItem(
            id: "review.pending", placement: .leading, order: 10,
            isVisible: { !tracker.changedFiles.isEmpty }
        ) {
            PendingChangesStatus(tracker: tracker)
        })

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

    func beginAgentTurn() async {
        activeTurns += 1
        // Parallel sessions share one snapshot so a running turn's baseline isn't lost.
        guard activeTurns == 1 || turnTree == nil, let root = workspace.root else { return }
        let checkpoints = Checkpoints(root: root)
        do {
            let tree = try await Task.detached(priority: .userInitiated) { try checkpoints.snapshot() }.value
            turnTree = tree
            checkpointRoot = root
            lastError = nil
        } catch {
            lastError = "Couldn't snapshot workspace: \(error.localizedDescription)"
        }
    }

    func endAgentTurn() async {
        await refreshAgentChanges()
        activeTurns = max(0, activeTurns - 1)
    }

    func refreshAgentChanges() async {
        guard let tree = turnTree, let root = checkpointRoot, root == workspace.root else { return }
        let checkpoints = Checkpoints(root: root)
        guard let changes = try? await Task.detached(priority: .userInitiated, operation: { try checkpoints.changes(since: tree) }).value else {
            return
        }
        for change in changes {
            recordBaseline(change.baseline, for: change.url)
        }
        workspace.fileSystemDidChange()
    }

    func recordBaseline(_ text: String?, for url: URL) {
        let url = url.standardizedFileURL
        guard baselines[url] == nil else { return }
        baselines[url] = .some(text)
        order.append(url)
    }

    func baseline(for url: URL) -> String? {
        baselines[url.standardizedFileURL] ?? nil
    }

    func current(for url: URL) -> String? {
        workspace.documents.currentText(of: url)
    }

    func hasChanges(_ url: URL) -> Bool {
        let url = url.standardizedFileURL
        guard let entry = baselines[url] else { return false }
        _ = workspace.documents.existingDocument(for: url)?.revision
        return (entry ?? "") != (current(for: url) ?? "") || (entry == nil) != (current(for: url) == nil)
    }

    func stats(for url: URL) -> (added: Int, removed: Int) {
        guard hasChanges(url) else { return (0, 0) }
        return LineDiff.stats(old: baseline(for: url) ?? "", new: current(for: url) ?? "")
    }

    func hunks(for url: URL) -> [DiffHunk] {
        guard hasChanges(url) else { return [] }
        return LineDiff.hunks(old: baseline(for: url) ?? "", new: current(for: url) ?? "", context: 3)
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
