import Foundation
import OrbitAPI

/// Settings → Checkpoints (D185): how much the shadow repositories and
/// isolated copies take, and dropping old snapshots. Every snapshot stays
/// otherwise (`gc.auto` is off): chats rewind to them.
enum CheckpointStorage {
    /// Days snapshots are kept; nil keeps them all.
    static let choices: [Int?] = [nil, 90, 30, 7]

    static func title(_ days: Int?) -> String {
        switch days {
        case nil: "Forever"
        case 7: "1 Week"
        case 30: "1 Month"
        case let days?: "\(days / 30) Months"
        }
    }

    /// Bytes on disk under `folder`.
    nonisolated static func size(of folder: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in files {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    /// Deletes snapshot objects older than `days` that nothing but old chats
    /// point to; returns the bytes freed. What a running turn snapshots is newer.
    nonisolated static func prune(olderThan days: Int) -> Int64 {
        let before = size(of: Checkpoints.storage)
        let repositories = (try? FileManager.default.contentsOfDirectory(at: Checkpoints.storage, includingPropertiesForKeys: nil)) ?? []
        for repository in repositories where FileManager.default.fileExists(atPath: repository.appendingPathComponent("HEAD").path) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["--git-dir=\(repository.path)", "prune", "--expire=\(days).days.ago"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { continue }
            process.waitUntilExit()
        }
        return max(0, before - size(of: Checkpoints.storage))
    }
}

/// The kept-for choice and the daily cleanup it implies.
@MainActor
@Observable
final class CheckpointRetention {
    var days: Int? {
        didSet {
            settings.set(days ?? 0, for: "keepDays")
            if days != nil { lastCleanup = nil }
            cleanUpIfDue()
        }
    }

    private(set) var isCleaning = false
    @ObservationIgnored private let settings: PluginSettings
    @ObservationIgnored private var lastCleanup: Date? {
        get { settings.string("lastCleanup").flatMap(Double.init).map(Date.init(timeIntervalSince1970:)) }
        set { settings.set(newValue.map { String($0.timeIntervalSince1970) }, for: "lastCleanup") }
    }

    init(settings: PluginSettings) {
        self.settings = settings
        let stored = Int(settings.string("keepDays") ?? "") ?? 0
        days = CheckpointStorage.choices.contains(stored) ? stored : nil
        cleanUpIfDue()
    }

    /// At most once a day, in the background.
    func cleanUpIfDue() {
        guard let days, !isCleaning, lastCleanup.map({ Date().timeIntervalSince($0) > 86_400 }) ?? true else { return }
        Task { _ = await cleanUp(olderThan: days) }
    }

    func cleanUp(olderThan days: Int) async -> Int64 {
        isCleaning = true
        defer { isCleaning = false }
        lastCleanup = Date()
        return await Task.detached(priority: .utility) { CheckpointStorage.prune(olderThan: days) }.value
    }
}
