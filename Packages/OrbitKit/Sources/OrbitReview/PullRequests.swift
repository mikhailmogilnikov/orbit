import Foundation
import OrbitAPI

/// Isolated copies become pull requests (D133). The copy is a whole clone of
/// the project, `.git` included, so the branch, commit and push happen in it
/// and the project itself is never touched. Only the files the agent changed
/// are committed: the user's uncommitted work copied along stays out.
extension IsolatedCopies {
    func baseBranch(of copy: IsolatedCopy) async -> String? {
        let directory = copy.directory
        return await Task.detached {
            guard let branch = try? Shell.run("/usr/bin/git", ["rev-parse", "--abbrev-ref", "HEAD"], in: directory).trimmingCharacters(in: .whitespacesAndNewlines),
                  !branch.isEmpty, branch != "HEAD" else { return nil }
            return branch
        }.value
    }

    func publish(_ copy: IsolatedCopy, branch: String, title: String, body: String, environment: [String: String]) async throws -> URL {
        guard let base = await baseBranch(of: copy) else { throw Shell.Failure("The copy isn't a git repository on a branch.") }
        let directory = copy.directory
        let paths = await Self.changedPaths(in: copy)
        guard !paths.isEmpty else { throw Shell.Failure("The agent hasn't changed any files in the copy.") }
        return try await Task.detached {
            _ = try Shell.run("/usr/bin/env", ["gh", "auth", "status"], in: directory, environment: environment,
                              failure: "GitHub CLI isn't installed or logged in: install it (brew install gh) and run gh auth login.")
            let git = { (arguments: [String]) in try Shell.run("/usr/bin/git", arguments, in: directory, environment: environment) }
            _ = try git(["checkout", "-b", branch])
            _ = try git(["add", "-A", "--"] + paths)
            _ = try git(["commit", "-m", title] + (body.isEmpty ? [] : ["-m", body]))
            _ = try git(["push", "-u", "origin", branch])
            let output = try Shell.run("/usr/bin/env", ["gh", "pr", "create", "--base", base, "--head", branch, "--title", title, "--body", body],
                                       in: directory, environment: environment)
            guard let line = output.split(separator: "\n").last(where: { $0.hasPrefix("https://") }), let url = URL(string: String(line)) else {
                throw Shell.Failure("gh didn't return the pull request's address.")
            }
            return url
        }.value
    }

    func pullRequestStatus(_ url: URL, in copy: IsolatedCopy, environment: [String: String]) async -> PullRequestStatus? {
        let directory = FileManager.default.fileExists(atPath: copy.directory.path) ? copy.directory : copy.project
        return await Task.detached {
            guard let json = try? Shell.run("/usr/bin/env", ["gh", "pr", "view", url.absoluteString, "--json", "number,state,statusCheckRollup"],
                                            in: directory, environment: environment) else { return nil }
            return Self.parseStatus(json)
        }.value
    }

    func unpushedChanges(in copy: IsolatedCopy) async -> Int {
        let directory = copy.directory
        let paths = await Self.changedPaths(in: copy)
        guard !paths.isEmpty else { return 0 }
        return await Task.detached {
            let status = (try? Shell.run("/usr/bin/git", ["status", "--porcelain", "--"] + paths, in: directory)) ?? ""
            return status.split(separator: "\n").count
        }.value
    }

    /// Later turns' changes: committed on the branch made by `publish` and pushed, which updates the pull request.
    func pushUpdate(_ copy: IsolatedCopy, message: String, environment: [String: String]) async throws {
        let directory = copy.directory
        let paths = await Self.changedPaths(in: copy)
        guard !paths.isEmpty else { return }
        try await Task.detached {
            let git = { (arguments: [String]) in try Shell.run("/usr/bin/git", arguments, in: directory, environment: environment) }
            _ = try git(["add", "-A", "--"] + paths)
            // Nothing new staged: only a push left over from a failed attempt, if any.
            if (try? git(["diff", "--cached", "--quiet"])) == nil {
                _ = try git(["commit", "-m", message])
            }
            _ = try git(["push"])
        }.value
    }

    private static func changedPaths(in copy: IsolatedCopy) async -> [String] {
        await Task.detached {
            let root = copy.directory.standardizedFileURL.path + "/"
            let changes = (try? Checkpoints(root: copy.directory).changes(since: copy.checkpoint)) ?? []
            return changes.compactMap { change in
                change.url.path.hasPrefix(root) ? String(change.url.path.dropFirst(root.count)) : nil
            }
        }.value
    }

    /// `gh pr view --json number,state,statusCheckRollup`: check runs report
    /// status + conclusion, commit statuses a state.
    nonisolated static func parseStatus(_ json: String) -> PullRequestStatus? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let number = object["number"] as? Int else { return nil }
        let state: PullRequestStatus.State = switch object["state"] as? String {
        case "MERGED": .merged
        case "CLOSED": .closed
        default: .open
        }
        let rollup = object["statusCheckRollup"] as? [[String: Any]] ?? []
        var checks = PullRequestStatus.Checks.none
        let failed: Set<String> = ["FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"]
        for check in rollup {
            let conclusion = (check["conclusion"] as? String) ?? (check["state"] as? String) ?? ""
            let status = check["status"] as? String
            if failed.contains(conclusion) { checks = .failing; break }
            if conclusion == "PENDING" || conclusion == "EXPECTED" || (status != nil && status != "COMPLETED") {
                checks = .pending
            } else if checks == .none {
                checks = .passing
            }
        }
        return PullRequestStatus(number: number, state: state, checks: checks)
    }
}

/// A command's output, or its error output as the failure.
enum Shell {
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static func run(_ executable: String, _ arguments: [String], in directory: URL,
                    environment: [String: String]? = nil, failure: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        if let environment { process.environment = environment }
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(failure ?? (message.isEmpty ? "\(arguments.first ?? executable) failed" : message))
        }
        return String(decoding: out, as: UTF8.self)
    }
}
