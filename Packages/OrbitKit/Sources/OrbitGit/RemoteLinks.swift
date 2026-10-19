import AppKit
import OrbitAPI

/// Links to a file's lines on the repository's host (D150): GitHub, GitLab,
/// Bitbucket, or anything shaped like GitHub (Gitea, Forgejo).
enum RemoteLink {
    /// `git@github.com:me/app.git`, `ssh://git@host:22/me/app`, `https://host/me/app.git` → `https://host/me/app`.
    static func web(remote: String) -> URL? {
        var text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(".git") { text.removeLast(4) }
        if text.hasSuffix("/") { text.removeLast() }
        if let components = URLComponents(string: text), let scheme = components.scheme, let host = components.host {
            guard ["https", "http", "ssh", "git"].contains(scheme) else { return nil }
            return URL(string: "https://\(host)\(components.path)")
        }
        // scp-like: [user@]host:path
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let host = text[..<colon].split(separator: "@").last.map(String.init) ?? ""
        let path = text[text.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !host.isEmpty, !path.isEmpty else { return nil }
        return URL(string: "https://\(host)/\(path)")
    }

    /// `lines` 1-based.
    static func file(in repository: URL, commit: String, path: String, lines: ClosedRange<Int>?) -> URL? {
        let host = repository.host() ?? ""
        let encoded = path.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        let base = repository.absoluteString
        if host.contains("gitlab") {
            let anchor = lines.map { $0.count == 1 ? "#L\($0.lowerBound)" : "#L\($0.lowerBound)-\($0.upperBound)" } ?? ""
            return URL(string: "\(base)/-/blob/\(commit)/\(encoded)\(anchor)")
        }
        if host.contains("bitbucket") {
            let anchor = lines.map { $0.count == 1 ? "#lines-\($0.lowerBound)" : "#lines-\($0.lowerBound):\($0.upperBound)" } ?? ""
            return URL(string: "\(base)/src/\(commit)/\(encoded)\(anchor)")
        }
        let anchor = lines.map { $0.count == 1 ? "#L\($0.lowerBound)" : "#L\($0.lowerBound)-L\($0.upperBound)" } ?? ""
        return URL(string: "\(base)/blob/\(commit)/\(encoded)\(anchor)")
    }
}

extension GitRepository {
    /// A permalink: at HEAD when a remote branch has it, else at the upstream's commit
    /// (unpushed commits aren't on the host); nil without a remote.
    func remoteLink(for file: URL, lines: ClosedRange<Int>?) -> URL? {
        func text(_ arguments: [String]) -> String? {
            (try? run(arguments)).map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        let remotes = text(["remote"])?.split(separator: "\n").map(String.init) ?? []
        guard let name = remotes.contains("origin") ? "origin" : remotes.first,
              let remote = text(["remote", "get-url", name]).flatMap(RemoteLink.web),
              let top = text(["rev-parse", "--show-toplevel"]),
              let head = text(["rev-parse", "HEAD"]) else { return nil }
        let pushed = text(["branch", "-r", "--contains", head]) != nil
        let commit = pushed ? head : text(["rev-parse", "@{upstream}"]) ?? head
        let topPath = URL(fileURLWithPath: top).resolvingSymlinksInPath().path
        let filePath = file.resolvingSymlinksInPath().path
        guard filePath.hasPrefix(topPath + "/") else { return nil }
        return RemoteLink.file(in: remote, commit: commit, path: String(filePath.dropFirst(topPath.count + 1)), lines: lines)
    }
}

extension GitModel {
    func remoteLink(for file: URL, lines: ClosedRange<Int>?) async -> URL? {
        guard let repository = repositoryForLinks else { return nil }
        return await Task.detached(priority: .userInitiated) { repository.remoteLink(for: file, lines: lines) }.value
    }
}
