import AppKit
import CoreServices
import OrbitAPI

/// Picks up what changes in the open folder outside Orbit (Finder, a terminal,
/// another editor): the tree, git badges and open files follow (D126).
@MainActor
final class FolderWatcher {
    private let workspace: Workspace
    private var stream: FSEventStreamRef?
    private var realRoot: String?
    /// The real root first, then folders outside it that symlinks bring in.
    private var watched: [String] = []
    private let linkedFolders: @MainActor () -> [URL]
    private var lastRefresh = Date.distantPast
    private var scheduled: DispatchWorkItem?
    private var activationObserver: NSObjectProtocol?

    /// Git's own files (our `git status` rewrites the index: watching it would loop)
    /// and folders that churn by the thousand while installing or building. The
    /// folder itself appearing or going is still seen.
    nonisolated static let skipped = ["/.git/", "/node_modules/", "/.build/"]

    /// `linkedFolders`: symlinked folders shown in the tree.
    init(workspace: Workspace, linkedFolders: @escaping @MainActor () -> [URL] = { [] }) {
        self.workspace = workspace
        self.linkedFolders = linkedFolders
        watch()
        observeRoot()
    }

    isolated deinit {
        stop()
    }

    private func observeRoot() {
        withObservationTracking {
            _ = workspace.root
            _ = workspace.documents.open
            _ = linkedFolders()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.watch()
                if !self.workspace.isClosed { self.observeRoot() }
            }
        }
    }

    private func watch() {
        let root = workspace.isClosed ? nil : workspace.root?.standardizedFileURL
        // FSEvents reports real paths and doesn't follow a symlinked folder.
        let real = root.map { $0.realPath ?? $0.path }
        let paths = real.map { [$0] + linkedPaths(outside: $0) } ?? []
        guard paths != watched else { return }
        stop()
        realRoot = real
        watched = paths
        guard !paths.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            let changed = Array(list.prefix(count))
            MainActor.assumeIsolated {
                Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().handle(changed)
            }
        }
        let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, FSEventStreamCreateFlags(flags)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIfScheduled() }
        }
    }

    private func stop() {
        watched = []
        scheduled?.cancel()
        scheduled = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Folders outside the project that symlinks bring in (open in the tree, or
    /// holding an open file): FSEvents doesn't follow the links (D239).
    private func linkedPaths(outside root: String) -> [String] {
        let folders = linkedFolders() + workspace.documents.open.keys.map { $0.deletingLastPathComponent() }
        let outside = Set(folders.compactMap(\.realPath).filter { $0 != root && !$0.hasPrefix(root + "/") })
        return outside.filter { path in !outside.contains { path.hasPrefix($0 + "/") } }.sorted()
    }

    private func handle(_ paths: [String]) {
        guard paths.contains(where: { path in
            Self.matters(path, under: watched.first { path.hasPrefix($0 + "/") } ?? realRoot ?? "")
        }) else { return }
        schedule()
    }

    nonisolated static func matters(_ path: String, under root: String) -> Bool {
        let relative = path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
        return !skipped.contains { relative.contains($0) } && !relative.hasSuffix("/.DS_Store")
    }

    /// At most once a second while Orbit is in front, every few seconds behind
    /// (a build in a terminal shouldn't keep git busy), right away on coming back.
    private func schedule() {
        guard scheduled == nil else { return }
        // No NSApp in the test runner.
        let interval: TimeInterval = (NSApp as NSApplication?)?.isActive ?? true ? 1 : 3
        let delay = max(0, interval - Date().timeIntervalSince(lastRefresh))
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        scheduled = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func refreshIfScheduled() {
        guard let scheduled else { return }
        scheduled.cancel()
        refresh()
    }

    private func refresh() {
        scheduled = nil
        guard !workspace.isClosed, workspace.root != nil else { return }
        lastRefresh = Date()
        workspace.fileSystemDidChange()
    }
}
