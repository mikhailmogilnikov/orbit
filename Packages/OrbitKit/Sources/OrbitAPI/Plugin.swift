import Foundation
import Observation
import SwiftUI

public struct PluginManifest: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var version: String
    public var summary: String
    public var systemImage: String
    /// Its tile in Settings → Extensions (Built-in Features), like its settings pane's (D184).
    public var tint: Color
    /// Plugins it can't work without (D194): it's off while any of them is,
    /// and comes back with them.
    public var requires: [String]
    /// Part of Orbit itself: no switch (the editor, the file tree).
    public var isRequired: Bool
    /// Programs it runs, named in its row when they aren't on the Mac ("git").
    public var tools: [String]

    public init(
        id: String, name: String, version: String = "0.1.0", summary: String, systemImage: String = "puzzlepiece.extension",
        tint: Color = .gray, requires: [String] = [], isRequired: Bool = false, tools: [String] = []
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.summary = summary
        self.systemImage = systemImage
        self.tint = tint
        self.requires = requires
        self.isRequired = isRequired
        self.tools = tools
    }
}

/// Everything in Orbit beyond the bare window is a plugin, including the
/// built-in explorer, editor and agents. Built-ins get no private API.
@MainActor
public protocol OrbitPlugin: AnyObject {
    static var manifest: PluginManifest { get }
    init()
    func activate(_ context: PluginContext)
    /// Turned off (D194) or its window closed: stop processes, timers and
    /// observers. What it added to the registries the host removes.
    func deactivate()
    /// Work turning it off would stop ("2 agents are working"), asked first.
    func deactivationWarning() -> String?
}

extension OrbitPlugin {
    public func deactivate() {}
    public func deactivationWarning() -> String? { nil }
}

/// Whether a plugin is still on (D194). Observers that re-arm themselves
/// stop once it isn't, as they do once the window closes.
@MainActor
public final class PluginLifetime {
    public private(set) var isActive = true
    init() {}
    func end() { isActive = false }
}

/// What a plugin receives on activation.
@MainActor
public final class PluginContext {
    public let manifest: PluginManifest
    public let workspace: Workspace
    public let ui: UIRegistry
    public let commands: CommandRegistry
    public let services: ServiceRegistry
    /// What `make stress` does with the plugin's features (D244).
    public let stress: StressRegistry
    public let settings: PluginSettings
    public let lifetime: PluginLifetime

    /// False once the plugin is off or its window closed.
    public var isActive: Bool { lifetime.isActive && !workspace.isClosed }

    init(manifest: PluginManifest, host: PluginHost, lifetime: PluginLifetime) {
        self.manifest = manifest
        self.lifetime = lifetime
        workspace = host.workspace
        // Its own registries over the window's: what it adds carries its id.
        ui = UIRegistry(sharing: host.ui, owner: manifest.id, lifetime: lifetime)
        commands = CommandRegistry(sharing: host.commands, owner: manifest.id, lifetime: lifetime)
        services = ServiceRegistry(sharing: host.services, owner: manifest.id, lifetime: lifetime)
        stress = StressRegistry(sharing: host.stress, owner: manifest.id, lifetime: lifetime)
        settings = PluginSettings(pluginID: manifest.id)
    }
}

/// Per-plugin namespaced persistent settings.
public struct PluginSettings: Sendable {
    let pluginID: String

    private func key(_ name: String) -> String { "plugin.\(pluginID).\(name)" }

    public func string(_ name: String) -> String? { UserDefaults.standard.string(forKey: key(name)) }
    public func data(_ name: String) -> Data? { UserDefaults.standard.data(forKey: key(name)) }
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
        /// The user's switch; running also needs what it requires on.
        public var isEnabled: Bool
        public var id: String { manifest.id }
    }

    public let workspace: Workspace
    public let ui = UIRegistry()
    public let commands = CommandRegistry()
    public let services = ServiceRegistry()
    public let stress = StressRegistry()
    public private(set) var entries: [Entry] = []

    @ObservationIgnored private var types: [String: any OrbitPlugin.Type] = [:]
    private(set) var active: [String: any OrbitPlugin] = [:]
    @ObservationIgnored private var lifetimes: [String: PluginLifetime] = [:]
    @ObservationIgnored private var observer: NSObjectProtocol?
    private static let disabledKey = "orbit.disabledPlugins"
    /// Posted when a switch changes, so every window follows (D101, D194).
    static let enabledDidChange = Notification.Name("orbit.pluginsEnabledDidChange")

    /// One per window (D101), activating its own copy of every plugin.
    /// `plugins` come in activation order: each after what it requires.
    public init(plugins: [any OrbitPlugin.Type], root: URL? = nil) {
        workspace = Workspace(root: root)
        let disabled = Self.disabled
        for type in plugins {
            let manifest = type.manifest
            types[manifest.id] = type
            entries.append(Entry(manifest: manifest, isEnabled: manifest.isRequired || !disabled.contains(manifest.id)))
        }
        apply()
        observer = NotificationCenter.default.addObserver(forName: Self.enabledDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadSwitches() }
        }
    }

    private static var disabled: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: disabledKey) ?? [])
    }

    /// Takes effect right away, in every window (D194); turning a plugin off
    /// turns off what requires it too.
    public func setEnabled(_ enabled: Bool, pluginID: String) {
        guard let entry = entries.first(where: { $0.id == pluginID }), !entry.manifest.isRequired else { return }
        var disabled = Self.disabled
        if enabled { disabled.remove(pluginID) } else { disabled.insert(pluginID) }
        UserDefaults.standard.set(Array(disabled).sorted(), forKey: Self.disabledKey)
        NotificationCenter.default.post(name: Self.enabledDidChange, object: nil)
    }

    private func reloadSwitches() {
        let disabled = Self.disabled
        for index in entries.indices {
            entries[index].isEnabled = entries[index].manifest.isRequired || !disabled.contains(entries[index].id)
        }
        apply()
    }

    /// Running now: switched on, and so is everything it requires.
    public func isActive(_ pluginID: String) -> Bool { active[pluginID] != nil }

    /// What it requires that is off, by name ("Source Control").
    public func missingRequirements(of pluginID: String) -> [String] {
        guard let entry = entries.first(where: { $0.id == pluginID }) else { return [] }
        let wanted = wanted
        return entry.manifest.requires.compactMap { id in
            wanted.contains(id) ? nil : entries.first { $0.id == id }?.manifest.name ?? id
        }
    }

    /// What turning `pluginID` off would stop in this window: its work and that of what requires it.
    public func deactivationWarnings(for pluginID: String) -> [String] {
        var off: Set<String> = [pluginID]
        for entry in entries where entry.manifest.requires.contains(where: off.contains) { off.insert(entry.id) }
        return entries.filter { off.contains($0.id) }.compactMap { active[$0.id]?.deactivationWarning() }
    }

    /// What turning `pluginID` off has to free (D246): it and what requires
    /// it, and the models they registered as services (not one a plugin that
    /// stays on registered too: Git Lens hands on Source Control's model).
    public func objectsFreed(whenOff pluginID: String) -> [(name: String, object: AnyObject)] {
        var off: Set<String> = [pluginID]
        for entry in entries where entry.manifest.requires.contains(where: off.contains) { off.insert(entry.id) }
        let services = self.services.state.services.values.filter { type(of: $0.service) is AnyClass }
        let staying = Set(services.filter { !off.contains($0.owner ?? "") }.map { ObjectIdentifier($0.service as AnyObject) })
        var result: [(String, AnyObject)] = off.compactMap { id in active[id].map { ("plugin \(id)", $0 as AnyObject) } }
        for service in services where off.contains(service.owner ?? "") {
            let object = service.service as AnyObject
            if !staying.contains(ObjectIdentifier(object)) { result.append(("\(type(of: object)) of \(service.owner ?? "")", object)) }
        }
        return result
    }

    /// Switched on, with all it requires; entries come after what they require.
    private var wanted: Set<String> {
        var result = Set<String>()
        for entry in entries where entry.isEnabled && entry.manifest.requires.allSatisfy(result.contains) {
            result.insert(entry.id)
        }
        return result
    }

    /// Turns plugins on and off to match the switches: off in reverse order,
    /// so a plugin goes before what it requires; on in order.
    private func apply() {
        guard !workspace.isClosed else { return }
        let wanted = wanted
        for entry in entries.reversed() where active[entry.id] != nil && !wanted.contains(entry.id) {
            deactivate(entry.id)
        }
        for entry in entries where active[entry.id] == nil && wanted.contains(entry.id) {
            guard let type = types[entry.id] else { continue }
            let lifetime = PluginLifetime()
            let plugin = type.init()
            plugin.activate(PluginContext(manifest: entry.manifest, host: self, lifetime: lifetime))
            lifetimes[entry.id] = lifetime
            active[entry.id] = plugin
        }
    }

    private func deactivate(_ id: String) {
        guard let plugin = active.removeValue(forKey: id) else { return }
        lifetimes.removeValue(forKey: id)?.end()
        plugin.deactivate()
        ui.state.remove(owner: id)
        commands.remove(owner: id)
        services.remove(owner: id)
        stress.remove(owner: id)
        // Its tabs (a diff, a preview, a page) have nothing to show them now.
        for tab in workspace.allTabs where tab.kind != EditorTab.fileKind && ui.provider(for: tab) == nil {
            workspace.close(tab.id)
        }
    }

    /// The window closed (D101). Registries hold closures that hold the
    /// plugins, which hold the registries: emptied, the window's whole graph
    /// (buffers, indexes, models) can go.
    public func shutdown() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        for lifetime in lifetimes.values { lifetime.end() }
        lifetimes.removeAll()
        for plugin in active.values { plugin.deactivate() }
        active.removeAll()
        ui.removeAll()
        commands.removeAll()
        services.removeAll()
        stress.removeAll()
        workspace.close()
    }
}
