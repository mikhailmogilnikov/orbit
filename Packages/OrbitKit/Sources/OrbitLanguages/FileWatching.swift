#if canImport(CoreServices)
import CoreServices
#endif
import Foundation
import OrbitACP

/// What happened to a file on disk, in LSP's numbering (`FileChangeType`).
enum FileChange: Int, Sendable {
    case created = 1, changed, deleted
}

/// The files a server asked to hear about (`workspace/didChangeWatchedFiles`,
/// registered dynamically): servers like SourceKit-LSP, gopls, Pyright and
/// ESLint don't watch the disk themselves, so files the agent writes through
/// the shell would stay unknown to them (D77).
struct FileWatcher: Sendable {
    let pattern: NSRegularExpression
    /// A relative pattern's folder; nil matches against the server's root (and the full path).
    let base: String?
    /// LSP's `WatchKind` bits: 1 create, 2 change, 4 delete.
    let kinds: Int

    static func parse(_ options: JSONValue?) -> [FileWatcher] {
        (options?["watchers"]?.array ?? []).compactMap { watcher in
            let glob = watcher["globPattern"]
            let pattern = glob?.string ?? glob?["pattern"]?.string
            // `baseUri` is a URI or a WorkspaceFolder.
            let baseURI = glob?["baseUri"]?.string ?? glob?["baseUri"]?["uri"]?.string
            guard let pattern, let regex = Glob.regex(pattern) else { return nil }
            let base = baseURI.flatMap { LanguageServer.fileURL($0)?.path }
            return FileWatcher(pattern: regex, base: base, kinds: watcher["kind"]?.int ?? 7)
        }
    }

    func matches(_ path: String, _ change: FileChange, root: String) -> Bool {
        let bit = change == .deleted ? 4 : change.rawValue
        guard kinds & bit != 0 else { return false }
        if let base {
            guard let relative = Self.relative(path, to: base) else { return false }
            return Glob.matches(pattern, relative)
        }
        if Glob.matches(pattern, path) { return true }
        return Self.relative(path, to: root).map { Glob.matches(pattern, $0) } ?? false
    }

    private static func relative(_ path: String, to base: String) -> String? {
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
    }
}

/// A file or folder moved in Orbit, as language servers hear of it (D255).
struct FileMove: Sendable, Equatable {
    let from: URL
    let to: URL
    let isFolder: Bool
}

/// Which renames a server takes part in (`FileOperationFilter`).
struct FileOperationFilter: Sendable {
    let pattern: NSRegularExpression
    /// "file", "folder", or nil for both.
    let kind: String?

    static func parse(_ options: JSONValue?) -> [FileOperationFilter]? {
        guard let filters = options?["filters"]?.array else { return nil }
        return filters.compactMap { filter in
            guard (filter["scheme"]?.string ?? "file") == "file",
                  let glob = filter["pattern"]?["glob"]?.string, let regex = Glob.regex(glob) else { return nil }
            return FileOperationFilter(pattern: regex, kind: filter["pattern"]?["matches"]?.string)
        }
    }

    func matches(_ path: String, isFolder: Bool) -> Bool {
        if let kind, (kind == "folder") != isFolder { return false }
        return Glob.matches(pattern, path)
    }
}

/// LSP's glob syntax: `*`, `**`, `?`, `{a,b}`, `[abc]` / `[!abc]`.
enum Glob {
    static func regex(_ glob: String) -> NSRegularExpression? {
        var out = "^"
        var chars = Array(glob)[...]
        var braces = 0
        while let c = chars.popFirst() {
            switch c {
            case "*":
                if chars.first == "*" {
                    chars.removeFirst()
                    if chars.first == "/" {
                        chars.removeFirst()
                        out += "(?:.*/)?"
                    } else {
                        out += ".*"
                    }
                } else {
                    out += "[^/]*"
                }
            case "?": out += "[^/]"
            case "{":
                braces += 1
                out += "(?:"
            case "}" where braces > 0:
                braces -= 1
                out += ")"
            case "," where braces > 0: out += "|"
            case "[":
                guard let close = chars.firstIndex(of: "]") else {
                    out += "\\["
                    continue
                }
                var set = String(chars[chars.startIndex..<close])
                if set.hasPrefix("!") { set = "^" + set.dropFirst() }
                out += "[" + set.replacingOccurrences(of: "\\", with: "\\\\") + "]"
                chars = chars[chars.index(after: close)...]
            default:
                out += NSRegularExpression.escapedPattern(for: String(c))
            }
        }
        return try? NSRegularExpression(pattern: out + "$")
    }

    static func matches(_ regex: NSRegularExpression, _ path: String) -> Bool {
        regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }
}

#if canImport(CoreServices)
/// FSEvents for every file under a folder, a burst at a time. Paths come back
/// under `root` as given, even when FSEvents reports them by their real path.
@MainActor
final class FileEventStream {
    private var stream: FSEventStreamRef?
    private let onChanges: @MainActor ([(path: String, change: FileChange)]) -> Void
    private let root: String
    private let realRoot: String

    /// Version control, installed packages and SwiftPM's build folder churn by the
    /// thousand (SourceKit-LSP writes its index build there while it works) and no
    /// server we run needs to hear about them from us (tsserver watches its own).
    private static let skipped = ["/.git/", "/node_modules/", "/.build/"]

    init?(root: URL, onChanges: @escaping @MainActor ([(path: String, change: FileChange)]) -> Void) {
        self.root = root.standardizedFileURL.path
        // realpath, not `resolvingSymlinksInPath`: that one turns /private/var back into /var.
        self.realRoot = LanguageServer.realPath(self.root) ?? self.root
        self.onChanges = onChanges
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            let events = (0..<min(count, list.count)).map { (list[$0], flags[$0]) }
            MainActor.assumeIsolated {
                Unmanaged<FileEventStream>.fromOpaque(info).takeUnretainedValue().handle(events)
            }
        }
        let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes
        guard let stream = FSEventStreamCreate(
            // FSEvents doesn't follow a symlinked folder: watch where it points.
            nil, callback, &context, [realRoot] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, FSEventStreamCreateFlags(flags)
        ) else { return nil }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    isolated deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private func handle(_ events: [(String, FSEventStreamEventFlags)]) {
        let created = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
        let renamed = FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)
        let removed = FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved)
        let modified = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
        let relevant = created | renamed | removed | modified
        var changes: [(path: String, change: FileChange)] = []
        var seen = Set<String>()
        for (raw, flags) in events where flags & relevant != 0 {
            var path = raw
            if path.hasPrefix(realRoot + "/"), realRoot != root { path = root + path.dropFirst(realRoot.count) }
            guard path.hasPrefix(root + "/"), !Self.skipped.contains(where: { path.contains($0) }), seen.insert(path).inserted else { continue }
            // FSEvents merges flags over the burst: what's on disk now decides.
            let change: FileChange = if !FileManager.default.fileExists(atPath: path) {
                .deleted
            } else if flags & (created | renamed) != 0 {
                .created
            } else {
                .changed
            }
            changes.append((path, change))
        }
        if !changes.isEmpty { onChanges(changes) }
    }
}
#endif
