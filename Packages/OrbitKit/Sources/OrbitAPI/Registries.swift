import Observation
import SwiftUI

// MARK: - UI contributions

public struct PanelContribution: Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let order: Int
    public let makeView: @MainActor () -> AnyView

    public init<V: View>(id: String, title: String, systemImage: String, order: Int = 100, @ViewBuilder view: @escaping @MainActor () -> V) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.order = order
        makeView = { AnyView(view()) }
    }
}

/// A section of the Settings screen. Plugins add their own; the shell adds
/// General, Keyboard Shortcuts and Plugins.
public struct SettingsPane: Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let order: Int
    /// Extra words the settings search matches (option names).
    public let keywords: [String]
    public let makeView: @MainActor () -> AnyView

    public init<V: View>(
        id: String,
        title: String,
        systemImage: String,
        order: Int = 100,
        keywords: [String] = [],
        @ViewBuilder view: @escaping @MainActor () -> V
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.order = order
        self.keywords = keywords
        makeView = { AnyView(view()) }
    }
}

/// Opens tabs. The provider with the highest priority that accepts a tab wins,
/// so a plugin can override how e.g. Markdown files are shown.
public struct EditorProvider: Identifiable {
    public let id: String
    public let priority: Int
    public let accepts: @MainActor (EditorTab) -> Bool
    public let makeView: @MainActor (EditorTab) -> AnyView

    public init<V: View>(
        id: String,
        priority: Int = 0,
        accepts: @escaping @MainActor (EditorTab) -> Bool,
        @ViewBuilder view: @escaping @MainActor (EditorTab) -> V
    ) {
        self.id = id
        self.priority = priority
        self.accepts = accepts
        makeView = { AnyView(view($0)) }
    }
}

public struct StatusItem: Identifiable {
    public enum Placement: Sendable { case leading, trailing }
    public let id: String
    public let placement: Placement
    public let order: Int
    /// The status bar is shown only while at least one item has something to say.
    public let isVisible: @MainActor () -> Bool
    public let makeView: @MainActor () -> AnyView

    public init<V: View>(
        id: String,
        placement: Placement = .trailing,
        order: Int = 100,
        isVisible: @escaping @MainActor () -> Bool = { true },
        @ViewBuilder view: @escaping @MainActor () -> V
    ) {
        self.id = id
        self.placement = placement
        self.order = order
        self.isVisible = isVisible
        makeView = { AnyView(view()) }
    }
}

@MainActor
@Observable
public final class UIRegistry {
    public private(set) var sidebarPanels: [PanelContribution] = []
    public private(set) var inspectorPanels: [PanelContribution] = []
    /// Panels under the editor (terminal, …); one is shown at a time.
    public private(set) var bottomPanels: [PanelContribution] = []
    public var isBottomPanelVisible = false
    public var selectedBottomPanel: String?
    public private(set) var editorProviders: [EditorProvider] = []
    public private(set) var statusItems: [StatusItem] = []
    public private(set) var settingsPanes: [SettingsPane] = []
    /// The Settings screen covers the window while shown.
    public var isSettingsVisible = false
    public var selectedSettingsPane: String?

    /// UI requests from plugins to the shell (e.g. "reveal the Agents panel").
    public var requestedSidebarPanel: String?
    public var requestedInspectorPanel: String?
    /// The quick pick overlay on screen, if any.
    public private(set) var quickPick: QuickPick?

    init() {}

    public func addSidebarPanel(_ panel: PanelContribution) {
        sidebarPanels.append(panel)
        sidebarPanels.sort { $0.order < $1.order }
    }

    public func addInspectorPanel(_ panel: PanelContribution) {
        inspectorPanels.append(panel)
        inspectorPanels.sort { $0.order < $1.order }
    }

    public func addBottomPanel(_ panel: PanelContribution) {
        bottomPanels.append(panel)
        bottomPanels.sort { $0.order < $1.order }
    }

    public func addEditorProvider(_ provider: EditorProvider) {
        editorProviders.append(provider)
        editorProviders.sort { $0.priority > $1.priority }
    }

    public func addSettingsPane(_ pane: SettingsPane) {
        settingsPanes.append(pane)
        settingsPanes.sort { $0.order < $1.order }
    }

    public func showSettings(_ paneID: String? = nil) {
        if let paneID { selectedSettingsPane = paneID }
        isSettingsVisible = true
    }

    public func addStatusItem(_ item: StatusItem) {
        statusItems.append(item)
        statusItems.sort { $0.order < $1.order }
    }

    public func provider(for tab: EditorTab) -> EditorProvider? {
        editorProviders.first { $0.accepts(tab) }
    }

    public func revealSidebarPanel(_ id: String) { requestedSidebarPanel = id }
    public func revealInspectorPanel(_ id: String) { requestedInspectorPanel = id }

    public func revealBottomPanel(_ id: String) {
        selectedBottomPanel = id
        isBottomPanelVisible = true
    }

    /// Hides the bottom area when `id` is what it shows, otherwise reveals `id`.
    public func toggleBottomPanel(_ id: String) {
        if isBottomPanelVisible, (selectedBottomPanel ?? bottomPanels.first?.id) == id {
            isBottomPanelVisible = false
        } else {
            revealBottomPanel(id)
        }
    }

    /// Shows `pick`, or hides it when the same pick is already on screen (shortcut toggles).
    public func toggleQuickPick(_ pick: QuickPick) {
        quickPick = quickPick?.id == pick.id ? nil : pick
    }

    public func presentQuickPick(_ pick: QuickPick) { quickPick = pick }
    public func dismissQuickPick() { quickPick = nil }
}

// MARK: - Commands

public struct OrbitCommand: Identifiable {
    public let id: String
    public let title: String
    public let category: String
    public let systemImage: String?
    public let shortcut: KeyboardShortcut?
    public let isEnabled: @MainActor () -> Bool
    public let run: @MainActor () -> Void

    public init(
        id: String,
        title: String,
        category: String,
        systemImage: String? = nil,
        shortcut: KeyboardShortcut? = nil,
        isEnabled: @escaping @MainActor () -> Bool = { true },
        run: @escaping @MainActor () -> Void
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.systemImage = systemImage
        self.shortcut = shortcut
        self.isEnabled = isEnabled
        self.run = run
    }
}

@MainActor
@Observable
public final class CommandRegistry {
    public private(set) var all: [OrbitCommand] = []

    init() {}

    public func register(_ command: OrbitCommand) {
        all.removeAll { $0.id == command.id }
        all.append(command)
    }

    public func run(_ id: String) {
        guard let command = all.first(where: { $0.id == id }), command.isEnabled() else { return }
        command.run()
    }

    public var categories: [String] {
        var seen = Set<String>()
        return all.map(\.category).filter { seen.insert($0).inserted }
    }
}

// MARK: - Services

/// Typed service locator: plugins expose APIs to each other through protocols
/// declared in OrbitAPI, never through concrete types.
@MainActor
public final class ServiceRegistry {
    private var services: [ObjectIdentifier: Any] = [:]

    init() {}

    public func register<Service>(_ type: Service.Type, _ service: Service) {
        services[ObjectIdentifier(type)] = service
    }

    public func resolve<Service>(_ type: Service.Type) -> Service? {
        services[ObjectIdentifier(type)] as? Service
    }
}
