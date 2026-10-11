import Foundation

/// Tracks files changed by agents against a baseline so the user can review,
/// keep or revert each change right in the editor. Implemented by the Review plugin.
@MainActor
public protocol ChangeTracking: AnyObject {
    /// Files with unreviewed changes, in the order they were first touched.
    var changedFiles: [URL] { get }

    /// Call before an agent turn starts: snapshots the workspace.
    func beginAgentTurn() async

    /// Call while/after an agent works: picks up every file changed since the
    /// snapshot, however the agent changed it (tools, shell, scripts).
    func refreshAgentChanges() async

    /// Call when a turn finishes (successfully or not).
    func endAgentTurn() async

    /// Records pre-change contents directly (e.g. from `fs/write_text_file`).
    /// Ignored when the file is already tracked.
    func recordBaseline(_ text: String?, for url: URL)

    func hasChanges(_ url: URL) -> Bool
    func stats(for url: URL) -> (added: Int, removed: Int)

    /// Unreviewed change blocks of a file: baseline → current contents.
    func hunks(for url: URL) -> [DiffHunk]
    /// Accepts one block (it becomes part of the baseline).
    func keep(_ hunk: DiffHunk, in url: URL)
    /// Restores one block from the baseline.
    func revert(_ hunk: DiffHunk, in url: URL)
    func accept(_ url: URL)
    func reject(_ url: URL)

    /// Opens the file and scrolls to its first change.
    func openReview(for url: URL)
    func acceptAll()
    func rejectAll()
}

/// One-off questions to the user's agent without a visible session (commit
/// messages, summaries…). Implemented by the Agents plugin.
@MainActor
public protocol AgentCompletion: AnyObject {
    /// Display name of the agent that will answer, e.g. "Codex".
    var agentName: String { get }

    /// Starts the agent ahead of time when a request is likely soon (startup takes seconds).
    func prewarm()

    /// Runs `prompt` in a hidden, read-only session started in `directory` and
    /// returns the agent's reply text. Throws on failure or cancellation.
    func complete(_ prompt: String, in directory: URL) async throws -> String
}

/// How a file differs from version control, for decorations (explorer colors, badges).
public enum FileChangeKind: Int, Sendable, Comparable {
    // Raw values rank importance: a folder takes its most important child's kind.
    case added, untracked, renamed, modified, deleted, conflicted

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The letter shown next to a file name.
    public var badge: String {
        switch self {
        case .added: "A"
        case .untracked: "U"
        case .renamed: "R"
        case .modified: "M"
        case .deleted: "D"
        case .conflicted: "!"
        }
    }
}

/// Version-control status of files in the workspace. Implemented by the Git
/// plugin; observable, so views reading it update when the status changes.
@MainActor
public protocol FileStatusProviding: AnyObject {
    func status(of url: URL) -> FileChangeKind?
    /// The most important status among the files inside `url`.
    func folderStatus(of url: URL) -> FileChangeKind?
}

/// Project files for pickers such as @-mentions. Implemented by the Search plugin.
@MainActor
public protocol ProjectFileIndex: AnyObject {
    /// Best matches for `query` as project-relative paths, file names first;
    /// recently opened files when the query is empty.
    func search(_ query: String, limit: Int) -> [String]
}

/// Text selected in the editor, e.g. to show an agent.
public struct EditorSelection: Sendable, Hashable {
    public var url: URL
    public var text: String
    /// 1-based, inclusive.
    public var lines: ClosedRange<Int>

    public init(url: URL, text: String, lines: ClosedRange<Int>) {
        self.url = url
        self.text = text
        self.lines = lines
    }
}

public struct EditorCursor: Sendable, Hashable {
    public var url: URL
    /// 0-based.
    public var line: Int

    public init(url: URL, line: Int) {
        self.url = url
        self.line = line
    }
}

/// The selection of the editor that last had focus. Implemented by the Editor plugin.
@MainActor
public protocol EditorSelectionProviding: AnyObject {
    /// Nil when nothing is selected.
    var selection: EditorSelection? { get }
    /// Where the insertion point is; observable, settles shortly after it moves.
    var cursor: EditorCursor? { get }
}

/// The version-control copy of files, for change markers in the editor.
/// Implemented by the Git plugin.
@MainActor
public protocol VersionControlBaseline: AnyObject {
    /// Changes whenever baselines may have (commit, stage, checkout, pull…); observable.
    var baselineGeneration: Int { get }
    /// The file as staged in the index; nil when untracked, ignored, binary or not in a repository.
    func baseline(for url: URL) async -> String?
}
