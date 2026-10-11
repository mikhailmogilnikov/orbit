import Foundation
import Observation

public struct PluginManifest: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var version: String
    public var summary: String
    public var systemImage: String

    public init(id: String, name: String, version: String = "0.1.0", summary: String, systemImage: String = "puzzlepiece.extension") {
        self.id = id
        self.name = name
        self.version = version
        self.summary = summary
        self.systemImage = systemImage
    }
}

/// Everything in Orbit beyond the bare window is a plugin, including the
/// built-in explorer, editor and agents. Built-ins get no private API.
@MainActor
public protocol OrbitPlugin: AnyObject {
    static var manifest: PluginManifest { get }
    init()
    func activate(_ context: PluginContext)
    func deactivate()
}

extension OrbitPlugin {
    public func deactivate() {}
}

/// What a plugin receives on activation.
@MainActor
public final class PluginContext {
    public let manifest: PluginManifest
    public let workspace: Workspace
    public let ui: UIRegistry
    public let commands: CommandRegistry
    public let services: ServiceRegistry
    public let settings: PluginSettings

    init(manifest: PluginManifest, host: PluginHost) {
        self.manifest = manifest
        workspace = host.workspace
        ui = host.ui
        commands = host.commands
        services = host.services
        settings = PluginSettings(pluginID: manifest.id)
    }
}

/// Per-plugin namespaced persistent settings.
public struct PluginSettings: Sendable {
    let pluginID: String

    private func key(_ name: String) -> String { "plugin.\(pluginID).\(name)" }

    public func string(_ name: String) -> String? { UserDefaults.standard.string(forKey: key(name)) }
    public func bool(_ name: String, default value: Bool = false) -> Bool {
        UserDefaults.standard.object(forKey: key(name)) as? Bool ?? value
    }
    public func set(_ value: Any?, for name: String) { UserDefaults.standard.set(value, forKey: key(name)) }
}

@MainActor
@Observable
public final class PluginHost {
    public struct Entry: Identifiable {
        public let manifest: PluginManifest
        public var isEnabled: Bool
        public var id: String { manifest.id }
    }

    public let workspace = Workspace()
    public let ui = UIRegistry()
    public let commands = CommandRegistry()
    public let services = ServiceRegistry()
    public private(set) var entries: [Entry] = []

    private var active: [String: any OrbitPlugin] = [:]
    private static let disabledKey = "orbit.disabledPlugins"

    public init(plugins: [any OrbitPlugin.Type]) {
        let disabled = Set(UserDefaults.standard.stringArray(forKey: Self.disabledKey) ?? [])
        for type in plugins {
            let manifest = type.manifest
            let enabled = !disabled.contains(manifest.id)
            entries.append(Entry(manifest: manifest, isEnabled: enabled))
            guard enabled else { continue }
            let plugin = type.init()
            plugin.activate(PluginContext(manifest: manifest, host: self))
            active[manifest.id] = plugin
        }
    }

    /// Takes effect on next launch; hot (de)activation comes with external plugins.
    public func setEnabled(_ enabled: Bool, pluginID: String) {
        guard let index = entries.firstIndex(where: { $0.id == pluginID }) else { return }
        entries[index].isEnabled = enabled
        var disabled = Set(UserDefaults.standard.stringArray(forKey: Self.disabledKey) ?? [])
        if enabled { disabled.remove(pluginID) } else { disabled.insert(pluginID) }
        UserDefaults.standard.set(Array(disabled).sorted(), forKey: Self.disabledKey)
    }

    public var needsRestart: Bool {
        entries.contains { ($0.isEnabled) != (active[$0.id] != nil) }
    }

    public func shutdown() {
        for plugin in active.values { plugin.deactivate() }
        active.removeAll()
    }
}
