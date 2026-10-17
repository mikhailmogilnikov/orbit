import CryptoKit
import Foundation

/// Snapshots the workspace into a private "shadow" git repository so we can
/// see every change an agent makes — including edits done through shell
/// commands, which never show up as structured diffs in ACP.
///
/// The shadow repo lives in Application Support and never touches the
/// project's own `.git`. Project `.gitignore` files are honoured.
struct Checkpoints: Sendable {
    let root: URL
    let gitDir: URL

    init(root: URL) {
        self.root = root
        let digest = SHA256.hash(data: Data(root.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        gitDir = support.appendingPathComponent("Orbit/checkpoints/\(digest)", isDirectory: true)
    }

    struct Change: Sendable {
        var url: URL
        /// File contents at the snapshot; `nil` when the file didn't exist.
        var baseline: String?
    }

    private static let excludes = """
    .git
    node_modules/
    .build/
    DerivedData/
    .swiftpm/
    dist/
    .next/
    .turbo/
    Pods/
    *.log
    .DS_Store
    """

    /// Stages the current working tree into the shadow index and returns its tree hash.
    func snapshot() throws -> String {
        try prepare()
        _ = try git(["add", "-A", "--ignore-errors", "."])
        return try git(["write-tree"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Files that differ between `tree` and the working tree, with their baseline contents.
    /// `known` files are left out: each would cost a `git show` for a baseline already recorded.
    func changes(since tree: String, skipping known: Set<URL> = []) throws -> [Change] {
        try changedPaths(since: tree).compactMap { path, existed in
            let url = url(of: path)
            guard !known.contains(url) else { return nil }
            let baseline: String? = existed ? (try? git(["show", "\(tree):\(path)"])) : nil
            return Change(url: url, baseline: baseline)
        }
    }

    /// The bytes `tree` holds for every file that differs from it now; `nil`
    /// for files the tree doesn't have (created since).
    func snapshotContents(since tree: String) throws -> [(url: URL, contents: Data?)] {
        try changedPaths(since: tree).map { path, existed in
            (url(of: path), try existed ? gitData(["cat-file", "blob", "\(tree):\(path)"]) : nil)
        }
    }

    private func changedPaths(since tree: String) throws -> [(path: String, existed: Bool)] {
        _ = try git(["add", "-A", "--ignore-errors", "."])
        let output = try git(["diff", "--cached", "--name-status", "--no-renames", "-z", tree])
        let fields = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        return stride(from: 0, to: fields.count - 1, by: 2).map { (fields[$0 + 1], !fields[$0].hasPrefix("A")) }
    }

    private func url(of path: String) -> URL {
        root.appendingPathComponent(path).standardizedFileURL
    }

    private func prepare() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: gitDir.appendingPathComponent("HEAD").path) {
            try fm.createDirectory(at: gitDir, withIntermediateDirectories: true)
            _ = try git(["init", "--quiet"])
            _ = try git(["config", "core.autocrlf", "false"])
            _ = try git(["config", "core.quotepath", "false"])
            _ = try git(["config", "core.bigFileThreshold", "5m"])
            // Snapshot trees are referenced by nothing but Orbit's chats (restore points).
            _ = try git(["config", "gc.auto", "0"])
        }
        let exclude = gitDir.appendingPathComponent("info/exclude")
        try fm.createDirectory(at: exclude.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.excludes.write(to: exclude, atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func git(_ arguments: [String]) throws -> String {
        String(decoding: try gitData(arguments), as: UTF8.self)
    }

    private func gitData(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--git-dir=\(gitDir.path)", "--work-tree=\(root.path)"] + arguments
        process.currentDirectoryURL = root
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = env
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "git \(arguments.first ?? "") failed"])
        }
        return data
    }
}
