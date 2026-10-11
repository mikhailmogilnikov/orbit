import Foundation
@testable import OrbitAgents
@testable import OrbitAPI
import Testing

@MainActor
@Suite struct SessionHistoryTests {
    private let folder = URL(fileURLWithPath: "/tmp/orbit-project")

    private func makeSettings() -> PluginSettings {
        PluginSettings(pluginID: "test.history.\(UUID().uuidString)")
    }

    @Test func mergesOwnRecordsWithAgentListsAndHidesHelpers() {
        let history = SessionHistory(settings: makeSettings())
        let listed = SessionHistory.parseList([
            "sessions": [
                ["sessionId": "a", "title": "From CLI", "updatedAt": "2026-10-01T10:00:00Z"],
                ["sessionId": "b", "updatedAt": "2026-10-02T10:00:00.123Z"],
                ["sessionId": "helper", "title": "Write a commit message"],
            ],
        ], providerID: "codex", folder: folder)
        #expect(listed.map(\.title) == ["From CLI", "Untitled conversation", "Write a commit message"])
        #expect(listed[1].updatedAt > listed[0].updatedAt)

        history.setListed(listed, for: "codex", in: folder)
        history.record(SavedSession(providerID: "codex", sessionID: "a", title: "Renamed in Orbit", cwd: folder.path, updatedAt: Date()))
        history.hide("codex:helper")
        // Orbit's record wins over the agent's listing and is newest; helpers never show.
        #expect(history.recent(in: folder).map(\.title) == ["Renamed in Orbit", "Untitled conversation"])
        #expect(history.recent(in: URL(fileURLWithPath: "/tmp/other")).isEmpty)
    }

    @Test func openTabsSurviveARelaunch() {
        let settings = makeSettings()
        let tabs = [
            SavedSession(providerID: "claude-code", sessionID: "1", title: "Fix tests", cwd: folder.path, updatedAt: Date()),
            SavedSession(providerID: "codex", sessionID: "2", title: "Docs", cwd: folder.path, updatedAt: Date()),
        ]
        SessionHistory(settings: settings).saveOpenTabs(tabs, selected: "2", in: folder)

        let restored = SessionHistory(settings: settings).openTabs(in: folder)
        #expect(restored.sessions.map(\.sessionID) == ["1", "2"])
        #expect(restored.selected == "2")
    }
}
