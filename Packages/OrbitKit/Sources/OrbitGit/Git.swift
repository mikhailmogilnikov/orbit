import Foundation

struct GitError: Error, LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// A file in `git status`. One file can be both staged and changed in the
/// working tree; the panel shows it in both sections.
struct GitFileStatus: Hashable, Sendable {
    enum Kind: Character, Sendable {
        case modified = "M", added = "A", deleted = "D", renamed = "R", copied = "C"
        case typeChanged = "T", untracked = "U", conflicted = "!"
    }

    let path: String
    var originalPath: String?
    var staged: Kind?
    var unstaged: Kind?
}

struct GitStatus: Sendable, Equatable {
    var branch: String?
    var upstream: String?
    var ahead = 0
    var behind = 0
    var hasCommits = true
    var files: [GitFileStatus] = []

    var staged: [GitFileStatus] { files.filter { $0.staged != nil && $0.staged != .conflicted } }
    var unstaged: [GitFileStatus] { files.filter { $0.unstaged != nil && $0.unstaged != .conflicted } }
    var conflicted: [GitFileStatus] { files.filter { $0.staged == .conflicted } }

    /// Parses `git status --porcelain=v2 --branch -z`.
    static func parse(_ data: Data) -> GitStatus {
        var status = GitStatus()
        let records = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            if record.hasPrefix("# ") {
                let parts = record.split(separator: " ", maxSplits: 2).map(String.init)
                guard parts.count == 3 else { continue }
                switch parts[1] {
                case "branch.oid": status.hasCommits = parts[2] != "(initial)"
                case "branch.head": status.branch = parts[2] == "(detached)" ? nil : parts[2]
                case "branch.upstream": status.upstream = parts[2]
                case "branch.ab":
                    for value in parts[2].split(separator: " ") {
                        if value.hasPrefix("+") { status.ahead = Int(value.dropFirst()) ?? 0 }
                        if value.hasPrefix("-") { status.behind = Int(value.dropFirst()) ?? 0 }
                    }
                default: break
                }
            } else if record.hasPrefix("1 ") || record.hasPrefix("2 ") {
                // "1 XY sub mH mI mW hH hI path"; "2 …  Xscore path" followed by the original path.
                let fieldCount = record.hasPrefix("1 ") ? 8 : 9
                let fields = record.split(separator: " ", maxSplits: fieldCount, omittingEmptySubsequences: false)
                guard fields.count == fieldCount + 1 else { continue }
                let xy = Array(fields[1])
                var file = GitFileStatus(path: String(fields[fieldCount]), staged: kind(xy[0]), unstaged: kind(xy[1]))
                if record.hasPrefix("2 "), index < records.count {
                    file.originalPath = records[index]
                    index += 1
                }
                status.files.append(file)
            } else if record.hasPrefix("u ") {
                let fields = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard fields.count == 11 else { continue }
                status.files.append(GitFileStatus(path: String(fields[10]), staged: .conflicted, unstaged: .conflicted))
            } else if record.hasPrefix("? ") {
                status.files.append(GitFileStatus(path: String(record.dropFirst(2)), unstaged: .untracked))
            }
        }
        status.files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return status
    }

    private static func kind(_ code: Character) -> GitFileStatus.Kind? {
        code == "." ? nil : GitFileStatus.Kind(rawValue: code) ?? .modified
    }
}

/// Runs git in one working tree. Nonisolated and blocking: call off the main actor.
struct GitRepository: Sendable {
    let root: URL
    var environment: [String: String]

    init(root: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.root = root
        var environment = environment
        // Never block on a credential prompt nobody can answer; don't take locks for reads.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["LC_ALL"] = "C"
        self.environment = environment
    }

    @discardableResult
    func run(_ arguments: [String], input: String? = nil) throws(GitError) -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let stdin = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        do { try process.run() } catch { throw GitError(message: "Couldn't run git: \(error.localizedDescription)") }
        if let input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        // Drain stderr concurrently so a chatty command can't fill the pipe and deadlock.
        let errorData = ErrorBuffer()
        let reader = DispatchQueue.global()
        let group = DispatchGroup()
        group.enter()
        reader.async {
            errorData.set(errors.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        group.wait()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData.value, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError(message: message.isEmpty ? "git \(arguments.first ?? "") failed" : message)
        }
        return data
    }

    func isRepository() -> Bool {
        (try? run(["rev-parse", "--is-inside-work-tree"])).map { String(decoding: $0, as: UTF8.self).hasPrefix("true") } ?? false
    }

    func status() throws(GitError) -> GitStatus {
        GitStatus.parse(try run(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"]))
    }

    func stage(_ paths: [String]) throws(GitError) {
        try run(["add", "--all", "--"] + paths)
    }

    func unstage(_ paths: [String], hasCommits: Bool) throws(GitError) {
        if hasCommits {
            try run(["restore", "--staged", "--"] + paths)
        } else {
            try run(["rm", "--cached", "-r", "--quiet", "--"] + paths)
        }
    }

    /// Restores tracked files from the index; untracked files are trashed by the caller.
    func discard(_ paths: [String]) throws(GitError) {
        try run(["restore", "--worktree", "--"] + paths)
    }

    func commit(message: String) throws(GitError) {
        try run(["commit", "--file=-"], input: message)
    }

    func branches() throws(GitError) -> [String] {
        let data = try run(["for-each-ref", "--sort=-committerdate", "--format=%(refname:short)", "refs/heads"])
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    func switchBranch(_ name: String, create: Bool = false) throws(GitError) {
        try run(create ? ["switch", "--create", name] : ["switch", name])
    }

    func pull() throws(GitError) { try run(["pull", "--no-rebase"]) }
    func fetch() throws(GitError) { try run(["fetch", "--prune"]) }

    func push(hasUpstream: Bool) throws(GitError) {
        try run(hasUpstream ? ["push"] : ["push", "--set-upstream", "origin", "HEAD"])
    }

    func initialize() throws(GitError) { try run(["init"]) }

    /// What a commit message is written from: the diff that will be committed
    /// (staged, or everything when nothing is) and recent subjects for style.
    func commitContext(stagedOnly: Bool, hasCommits: Bool, untracked: [String], limit: Int = 24_000) -> (diff: String, recentSubjects: [String]) {
        var diff: String
        if stagedOnly {
            diff = text(["diff", "--cached", "--stat"]) + "\n" + text(["diff", "--cached", "--no-color"])
        } else {
            diff = hasCommits ? text(["diff", "HEAD", "--stat"]) + "\n" + text(["diff", "HEAD", "--no-color"]) : ""
            // New files aren't in `git diff`; include short ones so the agent sees what they are.
            for path in untracked.prefix(20) {
                let url = root.appendingPathComponent(path)
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let head = content.split(separator: "\n", omittingEmptySubsequences: false).prefix(60).joined(separator: "\n")
                diff += "\nNew file: \(path)\n\(head)\n"
            }
        }
        if diff.count > limit { diff = String(diff.prefix(limit)) + "\n… (diff truncated)" }
        let subjects = hasCommits ? text(["log", "-12", "--format=%s"]).split(separator: "\n").map(String.init) : []
        return (diff, subjects)
    }

    enum Side: Sendable, Equatable {
        case text(String)
        case binary
    }

    /// Both sides of a file's change: HEAD → index for staged changes,
    /// index → working tree for the rest. Missing sides are empty (added/deleted files).
    func diffSides(of file: GitFileStatus, staged: Bool) -> (old: Side, new: Side) {
        if staged {
            let old = file.staged == .added ? .text("") : blob("HEAD:\(file.originalPath ?? file.path)")
            let new = file.staged == .deleted ? .text("") : blob(":\(file.path)")
            return (old, new)
        }
        let old = file.unstaged == .untracked ? .text("") : blob(":\(file.path)")
        let new: Side = file.unstaged == .deleted
            ? .text("")
            : (try? Data(contentsOf: root.appendingPathComponent(file.path))).map(Self.side) ?? .text("")
        return (old, new)
    }

    private func blob(_ spec: String) -> Side {
        (try? run(["show", spec])).map(Self.side) ?? .text("")
    }

    private static func side(_ data: Data) -> Side {
        guard !data.prefix(8192).contains(0), let text = String(data: data, encoding: .utf8) else { return .binary }
        return .text(text)
    }

    private func text(_ arguments: [String]) -> String {
        (try? run(arguments)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

private final class ErrorBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    var value: Data { lock.withLock { data } }
    func set(_ data: Data) { lock.withLock { self.data = data } }
}
