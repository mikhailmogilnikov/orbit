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

    /// Ignored paths relative to the root; a wholly ignored folder is one entry ending in "/".
    func ignoredPaths() -> [String] {
        let data = (try? run(["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"])) ?? Data()
        return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
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
            let old: Side = file.staged == .added ? .text("") : blob("HEAD:\(file.originalPath ?? file.path)") ?? .text("")
            let new: Side = file.staged == .deleted ? .text("") : blob(":\(file.path)") ?? .text("")
            return (old, new)
        }
        let old: Side = file.unstaged == .untracked ? .text("") : blob(":\(file.path)") ?? .text("")
        let new: Side = file.unstaged == .deleted
            ? .text("")
            : (try? Data(contentsOf: root.appendingPathComponent(file.path))).map(Self.side) ?? .text("")
        return (old, new)
    }

    /// A blob's contents; `missing` when it doesn't exist (e.g. a file new in this side).
    func blob(_ spec: String, missing: Side? = .text("")) -> Side? {
        (try? run(["show", spec])).map(Self.side) ?? missing
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

// MARK: - Stash, history, blame

struct GitStash: Identifiable, Hashable, Sendable {
    let index: Int
    let message: String
    let date: Date
    /// Its commit: what the panel lists the files of (D154).
    var hash = ""

    var id: Int { index }
    var ref: String { "stash@{\(index)}" }
}

struct GitCommit: Identifiable, Hashable, Sendable {
    let hash: String
    let shortHash: String
    let author: String
    let date: Date
    let subject: String
    /// For the graph (D136).
    var parents: [String] = []
    /// Branch and tag names pointing at it ("HEAD -> main", "origin/main", "tag: v1").
    var refs: [String] = []

    var id: String { hash }
}

struct GitCommitFile: Identifiable, Hashable, Sendable {
    let status: GitFileStatus.Kind
    let path: String
    /// For renames and copies.
    let oldPath: String?

    var id: String { path }
}

struct GitBlameLine: Hashable, Sendable {
    let hash: String
    let author: String
    let date: Date
    let summary: String

    /// Lines that exist only in the working copy blame to the all-zero hash.
    var isCommitted: Bool { hash.contains { $0 != "0" } }
}

extension GitRepository {
    func stashes() -> [GitStash] {
        GitParse.stashes(String(decoding: (try? run(["stash", "list", "--format=%gd%x1f%ct%x1f%H%x1f%gs"])) ?? Data(), as: UTF8.self))
    }

    /// Untracked files go into the stash too, so "stash, switch, pop" moves everything.
    func stash(message: String) throws(GitError) {
        var arguments = ["stash", "push", "--include-untracked"]
        if !message.isEmpty { arguments += ["--message", message] }
        try run(arguments)
    }

    func applyStash(_ stash: GitStash, drop: Bool) throws(GitError) {
        try run(["stash", drop ? "pop" : "apply", stash.ref])
    }

    func dropStash(_ stash: GitStash) throws(GitError) {
        try run(["stash", "drop", stash.ref])
    }

    private static let logFormat = ["%H", "%h", "%an", "%ct", "%P", "%D", "%s"].joined(separator: "%x1f")

    /// The newest commits of `revisions` (none: the current branch; `--all`: every
    /// branch), parents before children's siblings so the graph reads (D136).
    func log(revisions: [String] = [], limit: Int = 200) -> [GitCommit] {
        let arguments = ["log", "-n", "\(limit)", "--topo-order", "--format=\(Self.logFormat)"] + revisions + ["--"]
        return GitParse.commits(String(decoding: (try? run(arguments)) ?? Data(), as: UTF8.self))
    }

    /// The commits that changed a file, across renames, or a range of its
    /// lines (1-based, as committed): GitLens's file and line history (D189).
    func fileLog(path: String, lines: ClosedRange<Int>? = nil, limit: Int = 300) -> [GitCommit] {
        var arguments = ["log", "-n", "\(limit)", "--format=\(Self.logFormat)"]
        if let lines {
            arguments += ["-L", "\(lines.lowerBound),\(lines.upperBound):\(path)", "--no-patch"]
        } else {
            arguments += ["--follow", "--", path]
        }
        return GitParse.commits(String(decoding: (try? run(arguments)) ?? Data(), as: UTF8.self))
    }

    /// A file as `revision` has it (a branch, a tag, a commit).
    func contents(of path: String, at revision: String) -> Side? {
        blob("\(revision):\(path)")
    }

    /// Commits whose message or author contains `query` (any case), or whose hash starts with it.
    func searchLog(_ query: String, revisions: [String] = [], limit: Int = 300) -> [GitCommit] {
        func search(_ option: String) -> [GitCommit] {
            let arguments = ["log", "-n", "\(limit)", "--regexp-ignore-case", "--fixed-strings", "\(option)=\(query)", "--format=\(Self.logFormat)"] + revisions + ["--"]
            return GitParse.commits(String(decoding: (try? run(arguments)) ?? Data(), as: UTF8.self))
        }
        var found = search("--grep") + search("--author")
        if query.count >= 4, query.allSatisfy(\.isHexDigit),
           let data = try? run(["log", "-1", "--format=\(Self.logFormat)", query, "--"]) {
            found += GitParse.commits(String(decoding: data, as: UTF8.self)).filter { $0.hash.hasPrefix(query.lowercased()) }
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0.hash).inserted }.sorted { $0.date > $1.date }
    }

    /// Merges show what they brought in relative to their first parent.
    func files(in commit: String) -> [GitCommitFile] {
        let data = (try? run(["show", "--format=", "--name-status", "-z", "-M", "--diff-merges=first-parent", commit])) ?? Data()
        return GitParse.nameStatus(data)
    }

    /// Both sides of a file in a commit: its parent's copy → the commit's copy.
    func commitSides(_ commit: String, file: GitCommitFile) -> (old: Side, new: Side) {
        let old: Side = file.status == .added ? .text("") : blob("\(commit)^:\(file.oldPath ?? file.path)") ?? .text("")
        let new: Side = file.status == .deleted ? .text("") : blob("\(commit):\(file.path)") ?? .text("")
        return (old, new)
    }

    /// Blame of `contents` (the editor's text, unsaved edits included) against
    /// history; one entry per line.
    func blame(path: String, contents: String) -> [GitBlameLine]? {
        guard let data = try? run(["blame", "--porcelain", "--contents", "-", "--", path], input: contents) else { return nil }
        return GitParse.blame(data)
    }
}

enum GitParse {
    private static let field: Character = "\u{1F}"

    static func stashes(_ text: String) -> [GitStash] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: field, maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4,
                  let open = parts[0].firstIndex(of: "{"), let close = parts[0].firstIndex(of: "}"),
                  let index = Int(parts[0][parts[0].index(after: open)..<close]) else { return nil }
            var message = String(parts[3])
            // "On main: wip" / "WIP on main: 1a2b3c subject": the branch is noise in a list.
            if let colon = message.range(of: ": "), message.hasPrefix("On ") || message.hasPrefix("WIP on ") {
                message = String(message[colon.upperBound...])
            }
            return GitStash(index: index, message: message, date: Date(timeIntervalSince1970: TimeInterval(parts[1]) ?? 0), hash: String(parts[2]))
        }
    }

    static func commits(_ text: String) -> [GitCommit] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: field, maxSplits: 6, omittingEmptySubsequences: false)
            guard parts.count == 7 else { return nil }
            return GitCommit(
                hash: String(parts[0]),
                shortHash: String(parts[1]),
                author: String(parts[2]),
                date: Date(timeIntervalSince1970: TimeInterval(parts[3]) ?? 0),
                subject: String(parts[6]),
                parents: parts[4].split(separator: " ").map(String.init),
                refs: parts[5].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            )
        }
    }

    /// `--name-status -z`: a status, then one path (two for renames and copies).
    static func nameStatus(_ data: Data) -> [GitCommitFile] {
        var tokens = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }[...]
        var files: [GitCommitFile] = []
        while let code = tokens.popFirst() {
            let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let letter = trimmed.first, let kind = GitFileStatus.Kind(rawValue: letter) else { continue }
            if kind == .renamed || kind == .copied {
                guard let old = tokens.popFirst(), let new = tokens.popFirst() else { break }
                files.append(GitCommitFile(status: kind, path: new, oldPath: old))
            } else {
                guard let path = tokens.popFirst() else { break }
                files.append(GitCommitFile(status: kind, path: path, oldPath: nil))
            }
        }
        return files
    }

    /// `git blame --porcelain`: each line starts with "<hash> <orig> <final> [<count>]";
    /// a commit's details come once, the first time it appears.
    static func blame(_ data: Data) -> [GitBlameLine] {
        struct Info { var author = ""; var time: TimeInterval = 0; var summary = "" }
        var infos: [String: Info] = [:]
        var lines: [Int: String] = [:]
        var current: String?
        for raw in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false) {
            if raw.hasPrefix("\t") { continue }
            let words = raw.split(separator: " ", maxSplits: 1)
            guard let key = words.first else { continue }
            if key.count == 40, key.allSatisfy(\.isHexDigit) {
                let hash = String(key)
                current = hash
                let numbers = words.count > 1 ? words[1].split(separator: " ") : []
                if numbers.count >= 2, let final = Int(numbers[1]) { lines[final] = hash }
                if infos[hash] == nil { infos[hash] = Info() }
            } else if let hash = current, words.count == 2 {
                let value = String(words[1])
                switch key {
                case "author": infos[hash]?.author = value
                case "author-time": infos[hash]?.time = TimeInterval(value) ?? 0
                case "summary": infos[hash]?.summary = value
                default: break
                }
            }
        }
        guard let last = lines.keys.max() else { return [] }
        return (1...last).map { number in
            let hash = lines[number] ?? String(repeating: "0", count: 40)
            let info = infos[hash] ?? Info()
            return GitBlameLine(hash: hash, author: info.author, date: Date(timeIntervalSince1970: info.time), summary: info.summary)
        }
    }
}
