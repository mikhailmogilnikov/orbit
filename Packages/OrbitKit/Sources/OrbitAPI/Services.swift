import Foundation

/// Tracks files changed by agents against a baseline so the user can review,
/// keep or revert each change right in the editor. Implemented by the Review plugin.
@MainActor
public protocol ChangeTracking: AnyObject {
    /// Files with unreviewed changes, in the order they were first touched.
    var changedFiles: [URL] { get }

    /// Call before an agent turn starts: snapshots the workspace. Returns the
    /// snapshot as a restore point for `restore(_:)`.
    @discardableResult
    func beginAgentTurn() async -> String?

    /// Brings the project's files back to a restore point from `beginAgentTurn`.
    /// What it changes shows as unreviewed changes, so it can be undone block
    /// by block. Returns the files it changed.
    func restore(_ checkpoint: String) async throws -> [URL]

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

/// Hands a task to the agent chat, implemented by the Agents plugin: a chat
/// in the open folder with `prompt` in its composer, for the user to read and
/// send. False when there's no agent to ask.
@MainActor
public protocol AgentTasks: AnyObject {
    func draftTask(_ prompt: String) -> Bool
    /// Attaches a file to the message being written in the current chat (a tab dropped on it).
    func attachFile(_ url: URL)
    /// Attaches a file (or folder) to a new chat's message (the explorer's menu).
    func attachFileToNewChat(_ url: URL)
}

/// Who last changed a line, for the editor's blame column (D135).
public struct LineBlame: Sendable, Equatable {
    public var hash: String
    public var author: String
    public var date: Date
    public var summary: String

    public init(hash: String, author: String, date: Date, summary: String) {
        self.hash = hash
        self.author = author
        self.date = date
        self.summary = summary
    }

    /// Lines only in the working copy blame to the all-zero hash.
    public var isCommitted: Bool { hash.contains { $0 != "0" } }
}

/// Line-by-line blame of the editor's text, implemented by the Git plugin.
@MainActor
public protocol LineBlaming: AnyObject {
    /// Nil when git doesn't track the file.
    func blame(_ url: URL, contents: String) async -> [LineBlame]?
    /// Opens what the commit changed in the file.
    func showCommit(_ hash: String, file url: URL)
}

/// Marks a file's merge conflict resolved (`git add`), implemented by the Git
/// plugin; the editor offers it once the file has no conflict markers left (D134).
@MainActor
public protocol ConflictResolving: AnyObject {
    func markResolved(_ url: URL)
}

/// Opens a shell in a folder, implemented by the Terminal plugin.
@MainActor
public protocol TerminalOpening: AnyObject {
    func openTerminal(in directory: URL)
}

/// Find in Project limited to a folder (the explorer's Find in Folder).
@MainActor
public protocol ProjectSearching: AnyObject {
    func findInFolder(_ folder: URL)
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
    /// Matched by `.gitignore` (itself or an enclosing folder); shown dimmed.
    func isIgnored(_ url: URL) -> Bool
}

/// Project files for pickers such as @-mentions. Implemented by the Search plugin.
@MainActor
public protocol ProjectFileIndex: AnyObject {
    /// Best matches for `query` as project-relative paths, file names first;
    /// recently opened files when the query is empty.
    func search(_ query: String, limit: Int) -> [String]
    /// Every project file, project-relative; waits for the index to load.
    func allPaths() async -> [String]
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
    /// The insertion point right now, as language servers count it (not observable).
    var caret: SourceLocation? { get }
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

/// A private copy of the project an agent session works in, so parallel
/// agents don't trip over each other or over the user's edits.
public struct IsolatedCopy: Codable, Hashable, Sendable {
    public var project: URL
    public var directory: URL
    /// Snapshot of the copy when it was made; the agent's changes are measured from it.
    public var checkpoint: String
    /// The pull request made from the copy's changes (D133).
    public var pullRequest: URL?

    public init(project: URL, directory: URL, checkpoint: String, pullRequest: URL? = nil) {
        self.project = project
        self.directory = directory
        self.checkpoint = checkpoint
        self.pullRequest = pullRequest
    }
}

/// A pull request and its checks, as `gh` reports them (D133).
public struct PullRequestStatus: Sendable, Equatable {
    public enum State: Sendable { case open, merged, closed }
    public enum Checks: Sendable { case none, pending, passing, failing }

    public var number: Int
    public var state: State
    public var checks: Checks

    public init(number: Int, state: State, checks: Checks) {
        self.number = number
        self.state = state
        self.checks = checks
    }
}

public struct IsolatedApplyResult: Sendable {
    /// Project files written (or deleted).
    public var applied: [URL] = []
    /// Project files left alone: changed in the project too, on the same lines.
    public var conflicts: [URL] = []

    public init() {}
}

/// Makes isolated copies and brings their changes back as agent changes
/// (inline review). Implemented by the Change Review plugin.
@MainActor
public protocol AgentIsolation: AnyObject {
    func makeCopy(of project: URL) async throws -> IsolatedCopy
    /// Project files the agent changed in the copy that the project doesn't have yet.
    func unappliedChanges(in copy: IsolatedCopy) async -> [URL]
    func apply(_ copy: IsolatedCopy) async -> IsolatedApplyResult
    /// Deletes the copy.
    func discard(_ copy: IsolatedCopy)
    /// The branch the copy was on when it was made; nil when it isn't a git repo on a branch.
    func baseBranch(of copy: IsolatedCopy) async -> String?
    /// The agent's changes in the copy as a branch, a commit, a push and a
    /// GitHub pull request (`gh`); returns its URL. `environment` gives `gh` the user's PATH.
    func publish(_ copy: IsolatedCopy, branch: String, title: String, body: String, environment: [String: String]) async throws -> URL
    func pullRequestStatus(_ url: URL, in copy: IsolatedCopy, environment: [String: String]) async -> PullRequestStatus?
    /// Deletes every copy except these (left behind by a crash, or by a
    /// session whose agent never started).
    func discardCopies(except kept: [IsolatedCopy])
}
