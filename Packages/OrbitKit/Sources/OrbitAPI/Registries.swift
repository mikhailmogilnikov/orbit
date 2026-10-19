import Observation
import SwiftUI

// MARK: - UI contributions

public struct PanelContribution: Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let order: Int
    public let makeView: @MainActor () -> AnyView
    /// A count next to the panel's name (bottom panels): problems, results…
    public let badge: (@MainActor () -> PanelBadge?)?
    /// Controls of the shown panel, in the bottom area's header (terminal tabs).
    public private(set) var makeAccessory: (@MainActor () -> AnyView)?
    /// The command that shows the panel: its shortcut goes in the panel button's tooltip.
    public private(set) var commandID: String?

    public init<V: View>(
        id: String, title: String, systemImage: String, order: Int = 100,
        badge: (@MainActor () -> PanelBadge?)? = nil,
        @ViewBuilder view: @escaping @MainActor () -> V
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.order = order
        self.badge = badge
        makeView = { AnyView(view()) }
    }

    public func command(_ id: String) -> PanelContribution {
        var copy = self
        copy.commandID = id
        return copy
    }

    public func accessory<A: View>(@ViewBuilder _ content: @escaping @MainActor () -> A) -> PanelContribution {
        var copy = self
        copy.makeAccessory = { AnyView(content()) }
        return copy
    }
}

public struct PanelBadge: Sendable, Hashable {
    public enum Style: Sendable, Hashable { case plain, error, warning }
    public var count: Int
    public var style: Style

    public init(_ count: Int, style: Style = .plain) {
        self.count = count
        self.style = style
    }
}

/// The sidebar's blocks in Settings, top to bottom, like System Settings'
/// groups; panes sort by `order` inside their group.
public enum SettingsGroup: Int, Comparable, Sendable {
    /// The app itself: General, Appearance, Notifications.
    case app
    /// Writing code: Editor, Languages, Formatting, Source Control.
    case code
    /// Agents and what they get: Agents, MCP Servers.
    case agents
    /// Making Orbit yours: Keyboard Shortcuts, Extensions, Plugins.
    case customization

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A section of the Settings screen. Plugins add their own; the shell adds
/// General, Appearance, Keyboard Shortcuts, Extensions and Plugins.
public struct SettingsPane: Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String
    /// The tile behind the icon (sidebar, the pane's header), as in System Settings.
    public let tint: Color
    public let group: SettingsGroup
    public let order: Int
    /// One line under the title in the pane's header.
    public let summary: String?
    /// Extra words the settings search matches (option names).
    public let keywords: [String]
    public let makeView: @MainActor () -> AnyView

    public init<V: View>(
        id: String,
        title: String,
        systemImage: String,
        tint: Color = .gray,
        group: SettingsGroup = .customization,
        order: Int = 100,
        summary: String? = nil,
        keywords: [String] = [],
        @ViewBuilder view: @escaping @MainActor () -> V
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.group = group
        self.order = order
        self.summary = summary
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

/// An icon button at the trailing end of the editor's path bar, for the files
/// it applies to (Markdown's preview). It runs a command, so it carries the
/// command's title and shortcut as its tooltip.
public struct EditorAction: Identifiable {
    public let id: String
    public let commandID: String
    public let systemImage: String
    public let order: Int
    public let isVisible: @MainActor (URL) -> Bool

    public init(commandID: String, systemImage: String, order: Int = 100, isVisible: @escaping @MainActor (URL) -> Bool) {
        id = commandID
        self.commandID = commandID
        self.systemImage = systemImage
        self.order = order
        self.isVisible = isVisible
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
    // Remembered across launches (D80).
    public var isBottomPanelVisible = UserDefaults.standard.bool(forKey: "orbit.bottomPanelVisible") {
        didSet { UserDefaults.standard.set(isBottomPanelVisible, forKey: "orbit.bottomPanelVisible") }
    }
    public var selectedBottomPanel: String? = UserDefaults.standard.string(forKey: "orbit.bottomPanel") {
        didSet { UserDefaults.standard.set(selectedBottomPanel, forKey: "orbit.bottomPanel") }
    }
    public private(set) var editorProviders: [EditorProvider] = []
    public private(set) var statusItems: [StatusItem] = []
    public private(set) var editorActions: [EditorAction] = []
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

    func removeAll() {
        sidebarPanels = []
        inspectorPanels = []
        bottomPanels = []
        editorProviders = []
        statusItems = []
        editorActions = []
        settingsPanes = []
        quickPick = nil
    }

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
        settingsPanes.sort { ($0.group, $0.order) < ($1.group, $1.order) }
    }

    public func showSettings(_ paneID: String? = nil) {
        if let paneID { selectedSettingsPane = paneID }
        isSettingsVisible = true
    }

    public func addEditorAction(_ action: EditorAction) {
        editorActions.append(action)
        editorActions.sort { $0.order < $1.order }
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
    /// The plugin's keys; the user's own (Settings → Keyboard Shortcuts) win.
    public let defaultShortcut: KeyboardShortcut?
    /// A key only the focused editor answers, not a menu shortcut: keys like
    /// ⌥↑ or ⌘D mean something else in text fields (the agent composer).
    public let defaultEditorShortcut: KeyboardShortcut?
    public let isEnabled: @MainActor () -> Bool
    /// In the editor's right-click menu too, when set.
    public let editorMenu: EditorMenuPlacement?
    public let run: @MainActor () -> Void

    public init(
        id: String,
        title: String,
        category: String,
        systemImage: String? = nil,
        shortcut: KeyboardShortcut? = nil,
        editorShortcut: KeyboardShortcut? = nil,
        isEnabled: @escaping @MainActor () -> Bool = { true },
        editorMenu: EditorMenuPlacement? = nil,
        run: @escaping @MainActor () -> Void
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.systemImage = systemImage
        self.defaultShortcut = shortcut
        self.defaultEditorShortcut = editorShortcut
        self.isEnabled = isEnabled
        self.editorMenu = editorMenu
        self.run = run
    }

    /// A user's key replaces the editor-only one when that's all the command
    /// had, else the menu one (so a key given to a command without one is global).
    private var bindsEditorKey: Bool { defaultShortcut == nil && defaultEditorShortcut != nil }

    @MainActor public var shortcut: KeyboardShortcut? {
        bindsEditorKey ? nil : KeyBindings.shared.binding(for: id) ?? defaultShortcut
    }

    @MainActor public var editorShortcut: KeyboardShortcut? {
        bindsEditorKey ? KeyBindings.shared.binding(for: id) ?? defaultEditorShortcut : defaultEditorShortcut
    }

    /// The key to show in lists, tooltips and hints.
    @MainActor public var displayShortcut: KeyboardShortcut? { shortcut ?? editorShortcut }

    @MainActor public var defaultDisplayShortcut: KeyboardShortcut? { defaultShortcut ?? defaultEditorShortcut }
}

/// Where a command sits in the editor's right-click menu (above Cut, Copy,
/// Paste). Groups go in this order, separated; `isVisible` is asked each time
/// the menu opens, so it may read anything (unlike `isEnabled`).
public struct EditorMenuPlacement {
    public enum Group: Int, Comparable, Sendable {
        case navigate, edit, agent, review
        public static func < (a: Group, b: Group) -> Bool { a.rawValue < b.rawValue }
    }

    public let group: Group
    /// Shown instead of the command's title ("Ask Agent" for "Focus Agent Chat").
    public let title: String?
    public let isVisible: @MainActor () -> Bool

    public init(_ group: Group, title: String? = nil, isVisible: @escaping @MainActor () -> Bool = { true }) {
        self.group = group
        self.title = title
        self.isVisible = isVisible
    }
}

/// A command just run by mouse (menu, palette, a button) that has a shortcut:
/// the shell shows the shortcut for a moment, so it gets learned.
public struct CommandHint: Equatable {
    public let id = UUID()
    public let title: String
    public let shortcut: KeyboardShortcut

    public static func == (a: CommandHint, b: CommandHint) -> Bool { a.id == b.id }
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

    func removeAll() {
        all = []
        hint = nil
    }

    public func unregister(_ id: String) {
        all.removeAll { $0.id == id }
    }

    /// The latest shortcut to show (see `CommandHint`).
    public private(set) var hint: CommandHint?

    /// `teaching`: run without its shortcut (a click), so the shortcut is shown.
    public func run(_ id: String, teaching: Bool = false) {
        guard let command = all.first(where: { $0.id == id }), command.isEnabled() else { return }
        if teaching { teach(command) }
        command.run()
    }

    /// A tooltip naming what a button does and its command's shortcut:
    /// "Find References (⇧⌘R)". `text` replaces the command's title.
    public func help(_ id: String, _ text: String? = nil) -> String {
        let command = all.first { $0.id == id }
        let title = text ?? command?.title ?? ""
        guard let shortcut = command?.displayShortcut else { return title }
        return "\(title) (\(shortcut.displayString))"
    }

    public func teach(_ command: OrbitCommand) {
        guard let shortcut = command.displayShortcut else { return }
        hint = CommandHint(title: command.title, shortcut: shortcut)
    }

    /// The editor's right-click menu: visible commands with a placement, by group.
    public func editorMenuCommands() -> [OrbitCommand] {
        all.enumerated()
            .filter { $0.element.editorMenu?.isVisible() == true }
            .sorted { ($0.element.editorMenu!.group, $0.offset) < ($1.element.editorMenu!.group, $1.offset) }
            .map(\.element)
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

    func removeAll() { services = [:] }

    public func resolve<Service>(_ type: Service.Type) -> Service? {
        services[ObjectIdentifier(type)] as? Service
    }
}

extension KeyboardShortcut {
    /// "⇧⌘P", as menus draw it.
    public var displayString: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        switch key {
        case .return: result += "↩"
        case .delete: result += "⌫"
        case .escape: result += "⎋"
        case .tab: result += "⇥"
        case .upArrow: result += "↑"
        case .downArrow: result += "↓"
        case .leftArrow: result += "←"
        case .rightArrow: result += "→"
        case .space: result += "Space"
        default: result += String(key.character).uppercased()
        }
        return result
    }
}
