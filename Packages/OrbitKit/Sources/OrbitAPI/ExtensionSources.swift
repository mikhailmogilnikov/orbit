import SwiftUI

/// What can be added to Orbit, as Settings → Extensions groups it (D192).
/// Packages are extension folders: themes, icons, snippets, and agents,
/// servers or tasks for the other kinds (D195).
public enum ExtensionKind: String, CaseIterable, Sendable, Comparable {
    case agents, languageServers, packages, features

    public var title: String {
        switch self {
        case .agents: "Agents"
        case .languageServers: "Language Servers"
        case .packages: "Extension Packages"
        case .features: "Built-in Features"
        }
    }

    /// The filter's short name.
    public var shortTitle: String {
        switch self {
        case .agents: "Agents"
        case .languageServers: "Languages"
        case .packages: "Packages"
        case .features: "Features"
        }
    }

    public static func < (a: Self, b: Self) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// One thing a source lists: installed, or in its catalog to install.
/// The row is drawn by the shell; the source fills in what it can do.
public struct ExtensionItem: Identifiable {
    public let id: String
    public var name: String
    /// One line under the name: a description, "On your Mac", the defaults picked…
    public var summary: String
    /// Small and gray after the name: a version, file types.
    public var detail: String?
    public var keywords: [String]
    public var icon: @MainActor () -> AnyView
    public var isInstalled: Bool
    /// Ships with Orbit: nothing to uninstall.
    public var isBuiltin: Bool
    public var isBusy: Bool
    /// The last install or update that failed, said plainly.
    public var failure: String?
    /// A warning instead of the summary ("Not found on this Mac").
    public var warning: String?
    public var latestVersion: String?
    /// A switch at the end of the row when it can be turned off without uninstalling.
    public var isEnabled: Bool?
    public var setEnabled: (@MainActor (Bool) -> Void)?
    /// The switch is shown but can't be used (what it requires is off).
    public var isSwitchLocked = false
    /// Drawn indented under the row before it: it requires that one (D194).
    public var isNested = false
    public var install: (@MainActor () async -> Void)?
    public var update: (@MainActor () async -> Void)?
    public var uninstall: (@MainActor () -> Void)?
    public var folder: URL?
    /// Its own page, pushed when the row is clicked (an agent's defaults).
    public var page: (@MainActor () -> AnyView)?
    /// The Settings pane its options are in (a gear on the row).
    public var settingsPane: String?

    public init(
        id: String, name: String, summary: String, detail: String? = nil, keywords: [String] = [],
        isInstalled: Bool, isBuiltin: Bool = false,
        @ViewBuilder icon: @escaping @MainActor () -> some View
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.detail = detail
        self.keywords = keywords
        self.isInstalled = isInstalled
        self.isBuiltin = isBuiltin
        self.isBusy = false
        self.icon = { AnyView(icon()) }
    }

    public var hasUpdate: Bool { latestVersion != nil && update != nil }

    /// Name, summary, detail and keywords hold every word of the query.
    public func matches(_ query: String) -> Bool {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return true }
        let haystack = ([name, summary, detail ?? ""] + keywords).joined(separator: " ").lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }
}

/// A kind of installable thing and where it comes from (the ACP registry,
/// Mason, Zed's catalog…). Plugins register theirs so one Settings page lists
/// and installs everything (D192); reads of observable state in `installed`
/// and `available` keep that page current.
@MainActor
public protocol ExtensionSource: AnyObject {
    var kind: ExtensionKind { get }
    /// Where the catalog comes from, under the Available list.
    var catalogName: String { get }
    var installed: [ExtensionItem] { get }
    /// The catalog's items not installed yet, matching the query (all of them when it's empty).
    func available(matching query: String) -> [ExtensionItem]
    var isLoading: Bool { get }
    var loadError: String? { get }
    /// Fetches the catalog; called when the page appears.
    func refresh() async
}

extension ExtensionSource {
    public var isLoading: Bool { false }
    public var loadError: String? { nil }
    public func refresh() async {}
}
