import Foundation
@testable import OrbitAPI
import OrbitKit
import Testing

/// Plugins turn on and off without a restart (D194): off takes away all a
/// plugin added and frees it, along with what requires it; on brings it back once.
@MainActor
@Suite(.serialized) struct PluginTogglingTests {
    private static let disabledKey = "orbit.disabledPlugins"

    @Test func everyOptionalPluginTurnsOffAndOnLive() async throws {
        let saved = UserDefaults.standard.object(forKey: Self.disabledKey)
        UserDefaults.standard.removeObject(forKey: Self.disabledKey)
        defer { UserDefaults.standard.set(saved, forKey: Self.disabledKey) }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-toggle-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "hello".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let host = PluginHost(plugins: BuiltinPlugins.all, root: root)
        defer { host.shutdown() }
        try await Task.sleep(for: .milliseconds(200))
        let commandCount = host.commands.all.count

        for entry in host.entries where !entry.manifest.isRequired {
            let id = entry.id
            let dependents = host.entries.filter { $0.manifest.requires.contains(id) }.map(\.id)
            weak var plugin = host.active[id]
            #expect(plugin != nil, "\(id) starts on")
            // Its models are what it registers as services: they must go too.
            // (Not one a plugin that stays on registered too: Git Lens hands on Source Control's model.)
            let staying = host.services.state.services.values
                .filter { !Set([id] + dependents).contains($0.owner ?? "") }
                .map { ObjectIdentifier($0.service as AnyObject) }
            let models = host.services.state.services.values
                .filter { Set([id] + dependents).contains($0.owner ?? "") && !staying.contains(ObjectIdentifier($0.service as AnyObject)) }
                .map { Weak($0.service as AnyObject) }

            host.setEnabled(false, pluginID: id)
            try await settle()
            #expect(!host.isActive(id), "\(id) is off")
            for dependent in dependents { #expect(!host.isActive(dependent), "\(dependent) goes with \(id)") }
            let gone = Set([id] + dependents)
            #expect(!host.commands.all.contains { $0.pluginID.map(gone.contains) == true }, "\(id)'s commands are gone")
            #expect(!host.ui.state.sidebarPanels.contains { $0.pluginID == id })
            #expect(!host.ui.state.bottomPanels.contains { $0.pluginID == id })
            #expect(!host.ui.state.statusItems.contains { $0.pluginID == id })
            #expect(!host.ui.state.settingsPanes.contains { $0.pluginID == id })
            #expect(!host.services.state.services.values.contains { $0.owner == id })
            // A git or server call in flight holds its model until it returns: slow when every suite runs.
            for _ in 0..<200 where plugin != nil || models.contains(where: { $0.object != nil }) {
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(plugin == nil, "\(id) is freed")
            for model in models where model.object != nil {
                Issue.record("\(id): \(model.name) is still alive")
            }

            host.setEnabled(true, pluginID: id)
            try await settle()
            #expect(host.isActive(id), "\(id) is back")
            for dependent in dependents { #expect(host.isActive(dependent), "\(dependent) comes back with \(id)") }
            #expect(host.commands.all.count == commandCount, "\(id) came back once")
        }
    }

    @Test func requiredPluginsHaveNoSwitch() {
        let host = PluginHost(plugins: BuiltinPlugins.all)
        defer { host.shutdown() }
        for entry in host.entries where entry.manifest.isRequired {
            host.setEnabled(false, pluginID: entry.id)
            #expect(host.isActive(entry.id), "\(entry.id) stays on")
        }
        #expect(UserDefaults.standard.stringArray(forKey: Self.disabledKey)?.contains("orbit.editor") != true)
    }

    private final class Weak {
        weak var object: AnyObject?
        let name: String
        init(_ object: AnyObject) {
            self.object = object
            name = String(describing: type(of: object))
        }
    }

    /// The switch reaches every host through a notification on the main queue.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(100))
    }
}
