import AppKit
import OrbitAPI

/// Launched from outside Applications (the Desktop, Downloads, a disk
/// image), Orbit offers to move itself there (D221): Sparkle can't replace
/// an app in an iCloud-synced folder (`renamex_np` fails with EDEADLK), so
/// updates downloaded and then silently didn't install.
@MainActor
enum MoveToApplications {
    private static let suppressedKey = "orbit.moveToApplicationsSuppressed"

    static func offerIfNeeded() {
        #if !DEBUG
        let running = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard !UserDefaults.standard.bool(forKey: suppressedKey), !isInApplications(running) else { return }
        let original = originalURL(of: running)
        guard !isInApplications(original) else { return }
        offer(running: running, original: original)
        #endif
    }

    private static var applicationFolders: [URL] {
        FileManager.default.urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask])
    }

    private static func isInApplications(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return applicationFolders.contains { path.hasPrefix($0.standardizedFileURL.path + "/") }
    }

    private static func offer(running: URL, original: URL) {
        let destination = URL(fileURLWithPath: "/Applications").appendingPathComponent(running.lastPathComponent)
        let folder = FileManager.default.displayName(atPath: original.deletingLastPathComponent().path)
        let alert = NSAlert()
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        if let installed = build(of: destination), installed >= (build(of: running) ?? 0) {
            // An up-to-date copy is there already: this one is a leftover download.
            alert.messageText = "Orbit is already in Applications"
            alert.informativeText = "This copy runs from “\(folder)”, where it can't update itself. Open the one in Applications instead?"
            alert.addButton(withTitle: "Open the Copy in Applications")
            alert.addButton(withTitle: "Not Now")
            let response = alert.runSheetModal()
            remember(alert)
            guard response == .alertFirstButtonReturn else { return }
            relaunch(destination)
            return
        }
        alert.messageText = "Move Orbit to Applications?"
        alert.informativeText = "Orbit runs from “\(folder)”, where its updates can't be installed. In Applications it keeps itself up to date."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        let response = alert.runSheetModal()
        remember(alert)
        guard response == .alertFirstButtonReturn else { return }
        do {
            let moved = try copy(running, to: destination)
            // This copy's original goes to the Trash; a translocated copy runs from a read-only mount.
            try? FileManager.default.trashItem(at: original, resultingItemURL: nil)
            relaunch(moved)
        } catch {
            let failure = NSAlert(error: error)
            failure.messageText = "Orbit couldn't be moved to Applications"
            failure.informativeText = "Drag Orbit to the Applications folder in Finder, then open it from there.\n\n\(error.localizedDescription)"
            _ = failure.runSheetModal()
        }
    }

    private static func remember(_ alert: NSAlert) {
        if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: suppressedKey) }
    }

    private static func build(of app: URL) -> Int? {
        (Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(Int.init)
    }

    /// Into /Applications (replacing an older Orbit, which goes to the Trash),
    /// or ~/Applications for a user who can't write there.
    private static func copy(_ app: URL, to destination: URL) throws -> URL {
        let fileManager = FileManager.default
        func place(at target: URL) throws -> URL {
            if fileManager.fileExists(atPath: target.path) { try fileManager.trashItem(at: target, resultingItemURL: nil) }
            try fileManager.copyItem(at: app, to: target)
            // Already allowed to run (it is running): Gatekeeper needn't ask again for the copy.
            let xattr = Process()
            xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattr.arguments = ["-d", "-r", "com.apple.quarantine", target.path]
            xattr.standardError = FileHandle.nullDevice
            try? xattr.run()
            xattr.waitUntilExit()
            return target
        }
        do {
            return try place(at: destination)
        } catch CocoaError.fileWriteNoPermission {
            let folder = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            return try place(at: folder.appendingPathComponent(app.lastPathComponent))
        }
    }

    /// Opens the copy once this process is gone, so the two never run at once.
    private static func relaunch(_ app: URL) {
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = ["-c", "while /bin/kill -0 \"$0\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$1\"",
                            String(ProcessInfo.processInfo.processIdentifier), app.path]
        do {
            try waiter.run()
            NSApp.terminate(nil)
        } catch {
            NSWorkspace.shared.activateFileViewerSelecting([app])
        }
    }

    /// Where a quarantined app was opened from, when macOS runs it from a
    /// random read-only copy (App Translocation). The calls are Security's,
    /// not in its headers, so they are looked up and skipped if missing.
    private static func originalURL(of url: URL) -> URL {
        typealias IsTranslocated = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Bool
        typealias OriginalPath = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let isTranslocated = dlsym(security, "SecTranslocateIsTranslocatedURL"),
              let originalPath = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return url }
        var translocated = false
        guard unsafeBitCast(isTranslocated, to: IsTranslocated.self)(url as CFURL, &translocated, nil), translocated,
              let original = unsafeBitCast(originalPath, to: OriginalPath.self)(url as CFURL, nil)?.takeRetainedValue() else { return url }
        return original as URL
    }
}
