import AppKit
import CoreServices
import OrbitAPI

/// Picks up what changes in the open folder outside Orbit (Finder, a terminal,
/// another editor): the tree, git badges and open files follow (D126).
@MainActor
final class FolderWatcher {
    private let workspace: Workspace
    private var stream: FSEventStreamRef?
    private var root: String?
    private var realRoot: String?
    private var lastRefresh = Date.distantPast
    private var scheduled: DispatchWorkItem?
    private var activationObserver: NSObjectProtocol?

    /// Git's own files (our `git status` rewrites the index: watching it would loop)
    /// and folders that churn by the thousand while installing or building. The
    /// folder itself appearing or going is still seen.
    nonisolated static let skipped = ["/.git/", "/node_modules/", "/.build/"]

    init(workspace: Workspace) {
        self.workspace = workspace
        watch()
        observeRoot()
    }

    isolated deinit {
        stop()
    }

    private func observeRoot() {
        withObservationTracking {
            _ = workspace.root
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.watch()
                if !self.workspace.isClosed { self.observeRoot() }
            }
        }
    }

    private func watch() {
        let path = workspace.isClosed ? nil : workspace.root?.standardizedFileURL.path
        guard path != root else { return }
        stop()
        root = path
        guard let path else { return }
        // FSEvents reports real paths and doesn't follow a symlinked folder.
        // realpath, not `resolvingSymlinksInPath`: that one turns /private/var back into /var.
        let real = realpath(path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? path
        realRoot = real
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
            nil, callback, &context, [real] as CFArray,
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

    private func handle(_ paths: [String]) {
        guard let realRoot, paths.contains(where: { Self.matters($0, under: realRoot) }) else { return }
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
        let interval: TimeInterval = NSApp.isActive ? 1 : 3
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
