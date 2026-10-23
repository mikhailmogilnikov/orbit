import Foundation
import Observation

/// A launch that didn't last (D242): Orbit died seconds after starting, most
/// likely on what it reopened, and would again on every launch, before it could
/// even update itself to a fixed version (0.4.0 on macOS 27). The next launch is
/// a safe start: the welcome window instead of the last projects, with a notice
/// to check for updates or reopen them, and an update check right away.
@MainActor
@Observable
final class LaunchGuard {
    static let shared = LaunchGuard()

    private(set) var isSafeStart = false
    /// The projects open at the last quit, not reopened by this safe start.
    private(set) var skippedFolders: [URL] = []

    private static let unfinishedKey = "orbit.unfinishedLaunches"
    /// Longer than a crash while restoring takes, short enough that a crash
    /// later on (opening some file) doesn't count as one at launch.
    private static let stableAfter: Duration = .seconds(20)

    /// Release builds only: a debug build is killed by `make run` and Xcode all the time.
    private static var isEnabled: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "orbit.debugLaunchGuard")
        #else
        true
        #endif
    }

    private init() {}

    /// Before any window.
    func begin() {
        guard Self.isEnabled else { return }
        let defaults = UserDefaults.standard
        let unfinished = defaults.integer(forKey: Self.unfinishedKey)
        isSafeStart = unfinished > 0
        defaults.set(unfinished + 1, forKey: Self.unfinishedKey)
        Task { [weak self] in
            try? await Task.sleep(for: Self.stableAfter)
            self?.finish()
        }
        if isSafeStart, Updater.isEnabled {
            // A fixed version may be out already; Sparkle shows or installs it as set.
            Updater.shared.controller.updater.checkForUpdatesInBackground()
        }
    }

    /// The launch lasted, or Orbit quits normally.
    func finish() {
        UserDefaults.standard.removeObject(forKey: Self.unfinishedKey)
    }

    /// What ProjectWindows reopens: nothing on a safe start, the folders kept for the notice.
    func foldersToReopen(_ saved: [URL]) -> [URL] {
        guard isSafeStart else { return saved }
        skippedFolders = saved
        return []
    }

    func reopenSkipped() {
        let folders = skippedFolders
        skippedFolders = []
        isSafeStart = false
        for folder in folders { ProjectWindows.shared.open(folder) }
    }

    func dismiss() {
        isSafeStart = false
    }
}
