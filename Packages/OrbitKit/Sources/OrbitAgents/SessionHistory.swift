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

    var id: String { "\(providerID):\(sessionID)" }
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
        var recent = stored.recent[session.cwd] ?? []
        recent.removeAll { $0.id == session.id }
        recent.insert(session, at: 0)
        stored.recent[session.cwd] = Array(recent.prefix(Self.recentLimit))
        save()
    }

    func hide(_ id: String) {
        stored.hidden.append(id)
        if stored.hidden.count > Self.hiddenLimit { stored.hidden.removeFirst(stored.hidden.count - Self.hiddenLimit) }
        save()
    }

    func hasListed(_ providerID: String, in folder: URL) -> Bool {
        listed[folder.path]?[providerID] != nil
    }

    func setListed(_ sessions: [SavedSession], for providerID: String, in folder: URL) {
        listed[folder.path, default: [:]][providerID] = sessions
    }

    /// Newest first; Orbit's own record wins over an agent's listing of the same conversation.
    func recent(in folder: URL) -> [SavedSession] {
        var byID: [String: SavedSession] = [:]
        for session in (listed[folder.path] ?? [:]).values.joined() { byID[session.id] = session }
        for session in stored.recent[folder.path] ?? [] { byID[session.id] = session }
        for id in stored.hidden { byID[id] = nil }
        return byID.values.sorted { $0.updatedAt > $1.updatedAt }
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
