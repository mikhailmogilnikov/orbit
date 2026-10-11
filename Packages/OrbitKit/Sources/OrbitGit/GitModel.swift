import AppKit
import OrbitACP
import OrbitAPI

/// Git state of the open folder. Commands run off the main actor one at a
/// time, and every operation ends with a fresh `git status`.
@MainActor
@Observable
final class GitModel {
    enum State: Equatable {
        case noFolder, loading, notRepository, ready
    }

    private let workspace: Workspace
    private let services: ServiceRegistry
    private(set) var state: State = .noFolder
    private(set) var status = GitStatus() {
        didSet { if status != oldValue { rebuildDecorations() } }
    }
    /// Absolute paths → decoration, derived from `status`.
    private(set) var fileKinds: [String: FileChangeKind] = [:]
    private(set) var folderKinds: [String: FileChangeKind] = [:]
    private(set) var branches: [String] = []
    private(set) var isBusy = false
    /// Last failure (hook output, push rejection…), shown until dismissed.
    var error: String?
    var commitMessage = ""

    private var environment: [String: String]
    private var root: URL?
    private var queue: [@Sendable () async -> Void] = []
    private var refreshTask: Task<Void, Never>?

    private(set) var isGenerating = false
    private var generateTask: Task<Void, Never>?

    init(workspace: Workspace, services: ServiceRegistry) {
        self.workspace = workspace
        self.services = services
        environment = ShellEnvironment.withoutHostAgentVariables()
        Task {
            // Push/pull may need credential helpers from the user's PATH (gh, brew git…).
            let resolved = await ShellEnvironment.resolve()
            environment = resolved
        }
    }

    private var repository: GitRepository? {
        root.map { GitRepository(root: $0, environment: environment) }
    }

    var branchTitle: String {
        status.branch ?? "Detached HEAD"
    }

    var changeCount: Int {
        Set(status.files.map(\.path)).count
    }

    // MARK: - Decorations

    private func rebuildDecorations() {
        guard let root else {
            fileKinds = [:]
            folderKinds = [:]
            return
        }
        let rootPath = root.standardizedFileURL.path
        var files: [String: FileChangeKind] = [:]
        var folders: [String: FileChangeKind] = [:]
        for file in status.files {
            let kind = file.changeKind
            let path = rootPath + "/" + file.path
            files[path] = kind
            // Folders take the strongest child; a deleted child just means "changed inside".
            let folderKind: FileChangeKind = kind == .deleted ? .modified : kind
            var folder = (path as NSString).deletingLastPathComponent
            while folder.count > rootPath.count {
                if let existing = folders[folder], existing >= folderKind { break }
                folders[folder] = folderKind
                folder = (folder as NSString).deletingLastPathComponent
            }
        }
        if files != fileKinds { fileKinds = files }
        if folders != folderKinds { folderKinds = folders }
    }

    // MARK: - Refresh

    func refresh() {
        if root != workspace.root {
            root = workspace.root
            status = GitStatus()
            branches = []
            state = root == nil ? .noFolder : .loading
        }
        guard let repository else { return }
        refreshTask?.cancel()
        refreshTask = Task {
            let result = await Task.detached(priority: .utility) { () -> (GitStatus, [String])? in
                guard repository.isRepository(), let status = try? repository.status() else { return nil }
                return (status, (try? repository.branches()) ?? [])
            }.value
            guard !Task.isCancelled, repository.root == root else { return }
            if let (status, branches) = result {
                if self.status != status { self.status = status }
                if self.branches != branches { self.branches = branches }
                state = .ready
            } else {
                status = GitStatus()
                state = .notRepository
            }
        }
    }

    // MARK: - Operations

    func stage(_ files: [GitFileStatus]) {
        let paths = files.map(\.path)
        perform { try $0.stage(paths) }
    }

    func unstage(_ files: [GitFileStatus]) {
        let paths = files.map(\.path)
        let hasCommits = status.hasCommits
        perform { try $0.unstage(paths, hasCommits: hasCommits) }
    }

    func discard(_ files: [GitFileStatus]) {
        guard let root, confirmDiscard(files) else { return }
        let tracked = files.filter { $0.unstaged != .untracked }.map(\.path)
        let untracked = files.filter { $0.unstaged == .untracked }.map { root.appendingPathComponent($0.path) }
        perform(changesFiles: true) { repository in
            if !tracked.isEmpty { try repository.discard(tracked) }
            // Untracked files have no copy in git: move them to the Trash instead of deleting.
            for url in untracked {
                do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } catch {
                    throw GitError(message: "Couldn't move \(url.lastPathComponent) to the Trash: \(error.localizedDescription)")
                }
            }
        }
    }

    var canCommit: Bool {
        !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !status.files.isEmpty && status.conflicted.isEmpty
    }

    /// Commits what's staged, or everything when nothing is.
    func commit() {
        guard canCommit else { return }
        let message = commitMessage
        let stageAll = status.staged.isEmpty
        perform(onSuccess: { [weak self] in self?.commitMessage = "" }) { repository in
            if stageAll { try repository.stage(["."]) }
            try repository.commit(message: message)
        }
    }

    // MARK: - Generated commit message

    /// The agent that writes commit messages; nil when the Agents plugin is off.
    var messageAgent: AgentCompletion? { services.resolve(AgentCompletion.self) }

    func generateMessage() {
        if isGenerating {
            generateTask?.cancel()
            return
        }
        guard let agent = messageAgent, let repository, !status.files.isEmpty else { return }
        let status = status
        isGenerating = true
        error = nil
        generateTask = Task {
            defer {
                isGenerating = false
                generateTask = nil
            }
            let context = await Task.detached(priority: .userInitiated) {
                repository.commitContext(
                    stagedOnly: !status.staged.isEmpty,
                    hasCommits: status.hasCommits,
                    untracked: status.unstaged.filter { $0.unstaged == .untracked }.map(\.path)
                )
            }.value
            do {
                let reply = try await agent.complete(Self.messagePrompt(diff: context.diff, recentSubjects: context.recentSubjects), in: repository.root)
                guard !Task.isCancelled else { return }
                commitMessage = Self.cleanMessage(reply)
            } catch {
                guard !Task.isCancelled else { return }
                self.error = "\(agent.agentName) couldn't write a commit message: \(error.localizedDescription)"
            }
        }
    }

    static func messagePrompt(diff: String, recentSubjects: [String]) -> String {
        var prompt = """
        Write a git commit message for the changes below.
        - First line: imperative summary, at most 72 characters.
        - If the change isn't trivial, add a blank line and a short body explaining what and why.
        - Match the style and language of the recent commits if there are any.
        - Do not run tools or edit files. Reply with the commit message only: no quotes, no code fences, no preamble.
        """
        if !recentSubjects.isEmpty {
            prompt += "\n\nRecent commits:\n" + recentSubjects.map { "- \($0)" }.joined(separator: "\n")
        }
        prompt += "\n\nChanges:\n" + diff
        return prompt
    }

    /// Agents sometimes wrap the answer anyway.
    static func cleanMessage(_ reply: String) -> String {
        var lines = reply.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        if lines.first?.hasPrefix("```") == true { lines.removeFirst() }
        if lines.last?.hasPrefix("```") == true { lines.removeLast() }
        var message = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if message.count > 1, let first = message.first, first == message.last, "\"'`".contains(first) {
            message = String(message.dropFirst().dropLast())
        }
        return message
    }

    func switchBranch(_ name: String, create: Bool = false) {
        perform(changesFiles: true) { try $0.switchBranch(name, create: create) }
    }

    func pull() { perform(changesFiles: true) { try $0.pull() } }
    func fetch() { perform { try $0.fetch() } }

    func push() {
        let hasUpstream = status.upstream != nil
        perform { try $0.push(hasUpstream: hasUpstream) }
    }

    func initialize() { perform { try $0.initialize() } }

    static let diffKind = "git.diff"
    static let stagedDiffKind = "git.diff.staged"

    /// Opens a tab with the file's changes (like VS Code's diff editor).
    func openDiff(_ file: GitFileStatus, staged: Bool) {
        guard let root else { return }
        if file.staged == .conflicted { return open(file) }
        let url = root.appendingPathComponent(file.path)
        let name = url.lastPathComponent
        workspace.open(EditorTab(
            id: "\(staged ? Self.stagedDiffKind : Self.diffKind):\(file.path)",
            kind: staged ? Self.stagedDiffKind : Self.diffKind,
            title: "\(name) (\(staged ? "Staged" : "Working Tree"))",
            systemImage: "plusminus",
            url: url
        ))
    }

    func file(at url: URL) -> GitFileStatus? {
        guard let root else { return nil }
        let prefix = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(prefix) else { return nil }
        let relative = String(path.dropFirst(prefix.count))
        return status.files.first { $0.path == relative }
    }

    func diffSides(of file: GitFileStatus, staged: Bool) async -> (old: GitRepository.Side, new: GitRepository.Side)? {
        guard let repository else { return nil }
        return await Task.detached(priority: .userInitiated) { repository.diffSides(of: file, staged: staged) }.value
    }

    func openFile(_ url: URL) { workspace.openFile(url) }

    func reveal(_ file: GitFileStatus) {
        guard let root else { return }
        let url = root.appendingPathComponent(file.path)
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
    func relativePath(_ url: URL) -> String { workspace.relativePath(url) }

    func open(_ file: GitFileStatus) {
        guard let root else { return }
        let url = root.appendingPathComponent(file.path)
        if FileManager.default.fileExists(atPath: url.path) { workspace.openFile(url) }
    }

    /// Serializes operations: git takes an index lock, so two at once would fail.
    private func perform(
        changesFiles: Bool = false,
        onSuccess: @escaping @MainActor () -> Void = {},
        _ operation: @escaping @Sendable (GitRepository) throws -> Void
    ) {
        guard let repository else { return }
        queue.append { [weak self] in
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try operation(repository)
                    return nil
                } catch {
                    return (error as? GitError)?.message ?? error.localizedDescription
                }
            }.value
            await MainActor.run {
                guard let self else { return }
                if let failure { self.error = failure } else { onSuccess() }
                // A checkout or pull rewrites files: reload clean buffers, the tree, search.
                if changesFiles { self.workspace.fileSystemDidChange() }
                self.refresh()
            }
        }
        if !isBusy { drain() }
    }

    private func drain() {
        guard !queue.isEmpty else {
            isBusy = false
            return
        }
        isBusy = true
        let next = queue.removeFirst()
        Task {
            await next()
            drain()
        }
    }

    private func confirmDiscard(_ files: [GitFileStatus]) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = files.count == 1
            ? "Discard changes in \((files[0].path as NSString).lastPathComponent)?"
            : "Discard changes in \(files.count) files?"
        alert.informativeText = files.contains { $0.unstaged == .untracked }
            ? "Changes will be lost. New files will be moved to the Trash."
            : "Changes will be lost."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }
}

extension GitModel: FileStatusProviding {
    func status(of url: URL) -> FileChangeKind? { fileKinds[url.standardizedFileURL.path] }
    func folderStatus(of url: URL) -> FileChangeKind? { folderKinds[url.standardizedFileURL.path] }
}

extension GitFileStatus {
    /// One decoration per file even when it's both staged and changed again.
    var changeKind: FileChangeKind {
        if staged == .conflicted { return .conflicted }
        if unstaged == .untracked { return .untracked }
        if staged == .added { return .added }
        if staged == .deleted || unstaged == .deleted { return .deleted }
        if staged == .renamed || staged == .copied { return .renamed }
        return .modified
    }
}
