import Foundation
import OrbitACP
import OrbitAPI

/// A conversation an agent can open again (ACP `session/load`).
struct SavedSession: Codable, Hashable, Identifiable, Sendable {
    var providerID: String
    var sessionID: String
    var title: String
    /// Project folder path.
    var cwd: String
    var updatedAt: Date
    /// The session's own copy of the project, if it's isolated.
    var isolated: IsolatedCopy? = nil
    /// Restore points of the user's messages, oldest first.
    var checkpoints: [MessageCheckpoint]? = nil
    /// Messages waiting to be sent (D88), kept across launches (D131).
    var queued: [SavedQueuedMessage]? = nil

    var id: String { "\(providerID):\(sessionID)" }
}

/// A queued message: its text and attached files (images and editor
/// selections are left out; they'd bloat the saved tabs).
struct SavedQueuedMessage: Codable, Hashable, Sendable {
    var text: String
    var files: [String]
}

/// The project as it was before a message was sent (a `ChangeTracking` restore point).
/// Matched to the replayed transcript by the message's text.
struct MessageCheckpoint: Codable, Hashable, Sendable {
    var message: String
    var checkpoint: String
}

/// Per project folder: the agent tabs that were open, and recent conversations,
/// both Orbit's own and those the agents list (e.g. started in their CLI).
@MainActor
@Observable
final class SessionHistory {
    private struct Stored: Codable {
        var open: [String: [SavedSession]] = [:]
        var selected: [String: String] = [:]
        var recent: [String: [SavedSession]] = [:]
        /// Orbit's own hidden sessions (commit messages…), by `SavedSession.id`.
        var hidden: [String] = []
        /// New chats Orbit opened that nothing was sent in: the agent still
        /// lists them, but they're nothing to go back to. Optional: older saves lack it.
        var blank: [String]?
    }

    private static let recentLimit = 50
    private static let hiddenLimit = 500
    private let settings: PluginSettings
    private var stored: Stored
    /// From `session/list`, per folder and provider; not persisted, the agents keep them.
    private var listed: [String: [String: [SavedSession]]] = [:]

    init(settings: PluginSettings) {
        self.settings = settings
        stored = settings.data("history").flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
        migrateProviderIDs()
    }

    /// Conversations with agents Orbit used to ship belong to their registry ids now (D52).
    private func migrateProviderIDs() {
        func migrated(_ sessions: [SavedSession]) -> [SavedSession] {
            sessions.map { var session = $0; session.providerID = AgentProvider.migratedID(session.providerID); return session }
        }
        stored.open = stored.open.mapValues(migrated)
        stored.recent = stored.recent.mapValues(migrated)
        stored.hidden = stored.hidden.map { id in
            guard let colon = id.firstIndex(of: ":") else { return id }
            return AgentProvider.migratedID(String(id[..<colon])) + id[colon...]
        }
    }

    func openTabs(in folder: URL) -> (sessions: [SavedSession], selected: String?) {
        (stored.open[folder.path] ?? [], stored.selected[folder.path])
    }

    func saveOpenTabs(_ sessions: [SavedSession], selected: String?, in folder: URL) {
        stored.open[folder.path] = sessions
        stored.selected[folder.path] = selected
        save()
    }

    func record(_ session: SavedSession) {
        stored.blank?.removeAll { $0 == session.id }
        var recent = stored.recent[session.cwd] ?? []
        recent.removeAll { $0.id == session.id }
        recent.insert(session, at: 0)
        stored.recent[session.cwd] = Array(recent.prefix(Self.recentLimit))
        save()
    }

    /// Isolated copies that open tabs (in any folder) still use.
    var copiesInUse: [IsolatedCopy] {
        stored.open.values.joined().compactMap(\.isolated)
    }

    func hide(_ id: String) {
        stored.hidden.append(id)
        if stored.hidden.count > Self.hiddenLimit { stored.hidden.removeFirst(stored.hidden.count - Self.hiddenLimit) }
        save()
    }

    func markBlank(_ id: String) {
        var blank = stored.blank ?? []
        guard !blank.contains(id) else { return }
        blank.append(id)
        stored.blank = Array(blank.suffix(Self.hiddenLimit))
        save()
    }

    func hasListed(_ providerID: String, in folder: URL) -> Bool {
        listed[folder.path]?[providerID] != nil
    }

    func forgetListed(_ providerID: String, in folder: URL) {
        listed[folder.path]?[providerID] = nil
    }

    func setListed(_ sessions: [SavedSession], for providerID: String, in folder: URL) {
        listed[folder.path, default: [:]][providerID] = sessions
    }

    /// Newest first; Orbit's own record wins over an agent's listing of the same conversation.
    func recent(in folder: URL) -> [SavedSession] {
        var byID: [String: SavedSession] = [:]
        for session in (listed[folder.path] ?? [:]).values.joined() where !Self.isPlaceholder(session.title) {
            byID[session.id] = session
        }
        for session in stored.recent[folder.path] ?? [] { byID[session.id] = session }
        for id in stored.hidden + (stored.blank ?? []) { byID[id] = nil }
        return byID.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Claude Code titles a session "New session - <ISO date>" until its first
    /// prompt, so one still named that was never written in (including ones
    /// opened before Orbit kept track of blank chats).
    private nonisolated static func isPlaceholder(_ title: String) -> Bool {
        title.range(of: #"^New session - \d{4}-\d{2}-\d{2}T"#, options: .regularExpression) != nil
    }

    private func save() {
        if let data = try? JSONEncoder().encode(stored) { settings.set(data, for: "history") }
    }

    /// Entries of an ACP `session/list` result.
    nonisolated static func parseList(_ result: JSONValue, providerID: String, folder: URL) -> [SavedSession] {
        (result["sessions"]?.array ?? []).compactMap { item in
            guard let id = item["sessionId"]?.string else { return nil }
            let title = item["title"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
            return SavedSession(
                providerID: providerID,
                sessionID: id,
                title: title.flatMap { $0.isEmpty ? nil : String($0.prefix(80)) } ?? "Untitled conversation",
                cwd: folder.path,
                updatedAt: item["updatedAt"]?.string.flatMap(parseDate) ?? .distantPast
            )
        }
    }

    private nonisolated static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
