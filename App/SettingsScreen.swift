import OrbitKit
import SwiftUI

/// Settings take over the window (D36), laid out like System Settings (D158):
/// the project on top of the sidebar, panes in groups with colored tiles,
/// search, back and forward over the pane's page, which opens with a header
/// card. "Back to Project" (bottom of the sidebar), or Esc, returns.
struct SettingsScreen: View {
    let host: PluginHost
    @State private var query = ""
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var navigator = SettingsNavigator()
    /// The search result picked in the sidebar ("pane/item"), while it's the pane showing.
    @State private var pickedResult: String?
    /// Panes whose found options are all listed, not just the first few.
    @State private var expanded: Set<String> = []
    /// Built when a search starts, dropped when it's cleared.
    @State private var index: SettingsSearch.Index?

    private var ui: UIRegistry { host.ui }

    private var panes: [SettingsPane] {
        let host = host
        var shell = [
            SettingsPane(
                id: "general", title: "General", systemImage: "gearshape.fill", tint: .gray, group: .app, order: 0,
                summary: "Updates, the orbit command and the settings file every project shares.",
                keywords: ["version", "about", "update", "command line", "terminal", "settings.json", "global"],
                items: { [
                    SettingsItem("updates", "Check for Updates", keywords: ["version", "software update", "about"]),
                    SettingsItem("checkAutomatically", "Check for Orbit updates automatically", keywords: ["auto update", "sparkle"]),
                    SettingsItem("installAutomatically", "Install updates automatically", keywords: ["auto update", "download"]),
                    SettingsItem("autoAgents", "Update agents automatically", keywords: ["auto update", "registry"]),
                    SettingsItem("autoLanguageServers", "Update language servers automatically", keywords: ["auto update", "lsp", "mason"]),
                    SettingsItem("autoExtensions", "Update themes and icons automatically", keywords: ["auto update", "extensions"]),
                    SettingsItem("command", "orbit command", keywords: ["command line", "terminal", "cli", "shell"]),
                    SettingsItem("globalSettings", "Global settings", keywords: ["settings.json", "~/.orbit"]),
                    SettingsItem("folder", "Orbit folder", keywords: ["downloads", "~/.orbit", "finder"]),
                ] }

            ) {
                GeneralSettings()
            },
            SettingsPane(
                id: "appearance", title: "Appearance", systemImage: "circle.lefthalf.filled", tint: Color(white: 0.16), group: .app, order: 1,
                summary: "Light or dark, the color theme for each, text sizes and file icons.",
                keywords: ["theme", "dark", "light", "colors", "icons", "file icons", "mode"],
                items: { [
                    SettingsItem("mode", "Light, dark or auto", keywords: ["appearance", "mode", "system"]),
                    SettingsItem("theme", "Color theme", keywords: ["light theme", "dark theme", "colors"]),
                    SettingsItem("moreThemes", "Browse Themes", keywords: ["catalog", "zed", "install", "more themes"]),
                    SettingsItem("icons", "File icons", keywords: ["icon theme", "light icons", "dark icons"]),
                    SettingsItem("interfaceSize", "Interface text size", keywords: ["font size", "ui", "zoom", "bigger", "smaller"]),
                    SettingsItem("chatSize", "Chat text size", keywords: ["font size", "agent", "messages"]),
                    SettingsItem("codeSize", "Code font size", keywords: ["font size", "editor"]),
                    SettingsItem("terminalSize", "Terminal font size", keywords: ["font size"]),
                ] }
            ) {
                AppearanceSettings(host: host)
            },
            SettingsPane(
                id: "shortcuts", title: "Keyboard Shortcuts", systemImage: "keyboard.fill", tint: .gray, group: .customization, order: 0,
                summary: "Every command's keys; click one to change it.",
                keywords: ["keys", "hotkeys", "commands", "bindings"],
                // Each command, so "comment" finds Toggle Comment's keys.
                items: { host.commands.all.map { SettingsItem($0.id, $0.title) } }
            ) {
                ShortcutsSettings(host: host)
            },
            SettingsPane(
                id: "extensions", title: "Extensions", systemImage: "puzzlepiece.extension.fill", tint: .pink, group: .customization, order: 10,
                summary: "Everything you can add to Orbit: agents, language servers, packages of themes, icons and snippets, and Orbit's own features.",
                keywords: ["install", "catalog", "registry", "plugins", "features", "enable", "disable", "update", "agents", "language servers", "themes", "icons", "snippets", "packages", "zed", "mason", "acp"],
                // What's installed, by name: "codex" finds it here too.
                items: {
                    [
                        SettingsItem("catalog", "Browse Themes, Icons & Snippets", keywords: ["install", "themes", "icons", "snippets", "zed"]),
                        SettingsItem("snippets", "Your Snippets", keywords: ["~/.orbit/snippets", "templates", "prefix"]),
                        SettingsItem("newExtension", "New Extension…", keywords: ["create", "package", "~/.orbit/extensions"]),
                        SettingsItem("getMore.packages", "Get More Packages", keywords: ["install", "registry", "orbit-extensions", "tasks"]),
                    ]
                    + host.ui.extensionSources.map { SettingsItem("getMore." + $0.kind.rawValue, "Get More \($0.kind.title)", keywords: ["install", "catalog"]) }
                    + (host.ui.extensionSources + [PackageExtensionSource(host: host), FeatureExtensionSource(host: host)])
                        .flatMap(\.installed)
                        .map { SettingsItem($0.id, $0.name, keywords: $0.keywords) }
                }
            ) {
                ExtensionsSettings(host: host)
            },
        ]
        if let root = host.workspace.root {
            shell.append(SettingsPane(
                id: Self.projectPane, title: root.lastPathComponent, systemImage: "folder.fill", tint: .blue, group: .app, order: -1,
                summary: "Settings this project overrides, in .orbit/settings.json.",
                keywords: ["project", "folder", "settings.json", "per project", "override"],
                items: { [SettingsItem("file", "Project settings", keywords: [".orbit/settings.json", "overrides"])] }
            ) {
                ProjectSettingsPane(host: host, root: root)
            })
        }
        return (shell + ui.settingsPanes).sorted { ($0.group, $0.order) < ($1.group, $1.order) }
    }

    static let projectPane = "project"

    /// Panes the query finds, each with the options it finds in them (D177).
    private var results: [SettingsSearch.Result] {
        guard isSearching else { return panes.map { SettingsSearch.Result(pane: $0, items: []) } }
        return SettingsSearch.results(for: query, in: index ?? SettingsSearch.Index(panes))
    }

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        let results = results
        // Typing doesn't switch the page, as in System Settings: a result does.
        let all = panes
        let current = all.first { $0.id == navigator.pane } ?? all.first
        let page = current?.id == navigator.pane ? navigator.page : nil
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar(results, current: current?.id)
        } detail: {
            GeometryReader { proxy in
                // System Settings keeps its forms narrow; a wide window centers them.
                let margin = max(0, (proxy.size.width - 720) / 2)
                Group {
                    if let current {
                        if let page {
                            navigator.pageView.id(page.id)
                        } else {
                            current.makeView()
                                .environment(\.settingsPaneInfo, SettingsPaneInfo(
                                    title: current.title, systemImage: current.systemImage,
                                    tint: current.tint, summary: current.summary
                                ))
                                .id(current.id)
                        }
                    }
                }
                .contentMargins(.horizontal, margin, for: .scrollContent)
            }
            // The page scrolls under the bar and fades out there, as under System Settings' toolbar.
            .safeAreaBar(edge: .top, spacing: 0) {
                SettingsTopBar(
                    navigator: navigator, title: page?.title ?? current?.title ?? "Settings",
                    sidebarHidden: columnVisibility == .detailOnly
                )
            }
            .environment(navigator)
            .ignoresSafeArea(.container, edges: .top)
            .background(.background)
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search")
        // Return opens the best match, as in System Settings.
        .onSubmit(of: .search) {
            guard let first = results.first else { return }
            if let item = first.items.first {
                select(SettingsSearch.tag(item, in: first.pane))
            } else {
                select(first.pane.id)
            }
        }
        .onChange(of: query) {
            expanded = []
            if !isSearching { index = nil } else if index == nil { index = SettingsSearch.Index(panes) }
        }
        .navigationTitle(current?.title ?? "Settings")
        .navigationSubtitle("Settings")
        .onChange(of: ui.selectedSettingsPane, initial: true) { _, id in
            navigator.show(id ?? "general")
        }
        .onChange(of: navigator.pane) { _, id in
            if let id, ui.selectedSettingsPane != id { ui.selectedSettingsPane = id }
        }
    }

    private func sidebar(_ results: [SettingsSearch.Result], current: String?) -> some View {
        let visible = results.map(\.pane)
        let groups = Dictionary(grouping: visible.filter { $0.id != Self.projectPane }, by: \.group)
        let picked = isSearching && pickedResult.map { SettingsSearch.pane(ofTag: $0) == current } == true ? pickedResult : nil
        return List(selection: Binding(get: { picked ?? current }, set: { if let tag = $0 { select(tag) } })) {
            if isSearching {
                // Each pane with what it found under it, best first.
                ForEach(results, id: \.pane.id) { result in
                    Section {
                        SettingsSidebarRow(pane: result.pane)
                            .tag(result.pane.id)
                        let showsAll = expanded.contains(result.pane.id) || result.items.count <= SettingsSearch.shownItems + 1
                        ForEach(showsAll ? result.items : Array(result.items.prefix(SettingsSearch.shownItems))) { item in
                            SettingsResultRow(item: item, pane: result.pane, words: SettingsSearch.words(query))
                                .tag(SettingsSearch.tag(item, in: result.pane))
                        }
                        if !showsAll {
                            SettingsMoreRow(count: result.items.count - SettingsSearch.shownItems) {
                                expanded.insert(result.pane.id)
                            }
                        }
                    }
                }
            } else {
                if let project = visible.first(where: { $0.id == Self.projectPane }), let root = host.workspace.root {
                    Section {
                        ProjectSidebarRow(pane: project, root: root)
                            .tag(project.id)
                    }
                }
                ForEach(groups.keys.sorted(), id: \.self) { group in
                    Section {
                        ForEach(groups[group] ?? []) { pane in
                            SettingsSidebarRow(pane: pane)
                                .tag(pane.id)
                        }
                    }
                }
            }
        }
        // Room above the first row: flush with the search field, its selection lost its top corners.
        .contentMargins(.top, 6, for: .scrollContent)
        .overlay {
            if isSearching && results.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
        // At the bottom of the sidebar, not in the top row: the hidden
        // title bar's area over the detail column hid the Done button there.
        .safeAreaInset(edge: .bottom) {
            Button {
                ui.isSettingsVisible = false
            } label: {
                Label("Back to Project", systemImage: "chevron.left")
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.cancelAction)
            .buttonStyle(.glass)
            // Plain glass: the window's tint (the theme's text color in Orbit's
            // own themes) made it a heavy black or white bar.
            .tint(nil)
            .controlSize(.large)
            .help("Back to the project (Esc)")
            .padding(12)
        }
    }

    /// A pane ("general") or a found option in it ("editor/wordWrap").
    private func select(_ tag: String) {
        if let item = SettingsSearch.item(ofTag: tag) {
            pickedResult = tag
            navigator.reveal(item, in: SettingsSearch.pane(ofTag: tag))
        } else {
            pickedResult = nil
            navigator.show(tag)
        }
    }
}

/// Matching the sidebar's query against panes and the options in them (D177).
@MainActor
enum SettingsSearch {
    struct Result {
        let pane: SettingsPane
        let items: [SettingsItem]
    }

    /// Options listed under a pane before "N More".
    static let shownItems = 4
    private static let separator: Character = "/"

    static func words(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Every pane's and option's text, lowercased once when a search starts:
    /// typing then only compares strings (`pane.items()` can be slow).
    struct Index {
        struct Entry {
            let item: SettingsItem
            let title: String
            let text: String
        }

        struct Pane {
            let pane: SettingsPane
            let title: String
            let text: String
            let items: [Entry]
        }

        let panes: [Pane]

        @MainActor init(_ panes: [SettingsPane]) {
            self.panes = panes.map { pane in
                Pane(
                    pane: pane,
                    title: pane.title.lowercased(),
                    text: ([pane.title, pane.summary ?? ""] + pane.keywords).joined(separator: " ").lowercased(),
                    items: pane.items().map { item in
                        Entry(item: item, title: item.title.lowercased(), text: ([item.title] + item.keywords).joined(separator: " ").lowercased())
                    }
                )
            }
        }
    }

    static func results(for query: String, in index: Index) -> [Result] {
        let words = words(query)
        guard !words.isEmpty else { return index.panes.map { Result(pane: $0.pane, items: []) } }
        // Every word somewhere: "wrap line" finds "Wrap long lines".
        func matches(_ text: String) -> Bool { words.allSatisfy(text.contains) }
        let found: [(result: Result, rank: Int)] = index.panes.compactMap { entry in
            let items = entry.items
                .filter { matches($0.text) }
                .map { (item: $0.item, rank: rank($0.title, words)) }
                .sorted { ($0.rank, $0.item.title.count) < ($1.rank, $1.item.title.count) }
            let paneRank = matches(entry.title) ? rank(entry.title, words) - 1 : matches(entry.text) ? 4 : nil
            guard paneRank != nil || !items.isEmpty else { return nil }
            return (Result(pane: entry.pane, items: items.map(\.item)), min(paneRank ?? .max, items.first?.rank ?? .max))
        }
        // Stable: equally good panes keep the sidebar's order.
        return found.enumerated().sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }.map(\.element.result)
    }

    /// 0: the title starts with the query; 1: its words start with the query's; 2: in the title; 3: only in keywords.
    /// `title` is lowercased already.
    private static func rank(_ title: String, _ words: [String]) -> Int {
        if title.hasPrefix(words.joined(separator: " ")) { return 0 }
        let titleWords = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.allSatisfy({ word in titleWords.contains { $0.hasPrefix(word) } }) { return 1 }
        return words.allSatisfy(title.contains) ? 2 : 3
    }

    static func tag(_ item: SettingsItem, in pane: SettingsPane) -> String { "\(pane.id)\(separator)\(item.id)" }
    static func pane(ofTag tag: String) -> String { String(tag.prefix { $0 != separator }) }
    static func item(ofTag tag: String) -> String? {
        tag.firstIndex(of: separator).map { String(tag[tag.index(after: $0)...]) }
    }

    /// The title with the query's words in bold and full color.
    static func highlighted(_ title: String, _ words: [String]) -> AttributedString {
        var text = AttributedString(title)
        for word in words {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let range = text[searchStart...].range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) {
                text[range].font = .orbit(.body, weight: .semibold)
                text[range].foregroundColor = .primary
                searchStart = range.upperBound
            }
        }
        return text
    }
}

/// A found option, indented under its pane like a row inside it.
private struct SettingsResultRow: View {
    let item: SettingsItem
    let pane: SettingsPane
    let words: [String]

    var body: some View {
        Text(SettingsSearch.highlighted(item.title, words))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.leading, 28)
            .padding(.vertical, 1)
            .help("\(pane.title) › \(item.title)")
    }
}

/// "3 More" under a pane's first few found options; lists the rest.
private struct SettingsMoreRow: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text("\(count) More")
                Image(systemName: "chevron.down")
                    .orbitFont(.micro, weight: .semibold)
            }
            .foregroundStyle(.tertiary)
            .padding(.leading, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Show all \(count) more")
    }
}

private struct SettingsSidebarRow: View {
    let pane: SettingsPane

    var body: some View {
        HStack(spacing: 8) {
            SettingsTile(pane.systemImage, tint: pane.tint, size: 20)
            Text(pane.title)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

/// The project at the top of the sidebar, like the Apple Account in System Settings.
private struct ProjectSidebarRow: View {
    let pane: SettingsPane
    let root: URL

    var body: some View {
        HStack(spacing: 10) {
            SettingsTile(pane.systemImage, tint: pane.tint, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(pane.title)
                    .orbitFont(.control, weight: .semibold)
                    .lineLimit(1)
                Text("Project")
                    .orbitFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
        .help(root.path)
    }
}

/// Back and forward in a glass capsule, then the page's title, as in System Settings.
private struct SettingsTopBar: View {
    let navigator: SettingsNavigator
    let title: String
    let sidebarHidden: Bool

    /// With the sidebar hidden the bar runs under the traffic lights and the
    /// window's sidebar button, which end about 125 pt in.
    private static let windowButtonsInset: CGFloat = 136

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 0) {
                Button(action: navigator.back) {
                    Image(systemName: "chevron.left")
                        .frame(width: 34, height: 32)
                        .contentShape(.rect)
                }
                .disabled(!navigator.canGoBack)
                .keyboardShortcut("[", modifiers: .command)
                .help("Back (⌘[)")
                Divider()
                    .frame(height: 16)
                Button(action: navigator.forward) {
                    Image(systemName: "chevron.right")
                        .frame(width: 34, height: 32)
                        .contentShape(.rect)
                }
                .disabled(!navigator.canGoForward)
                .keyboardShortcut("]", modifiers: .command)
                .help("Forward (⌘])")
            }
            .buttonStyle(.plain)
            .orbitFont(.control, weight: .medium)
            .padding(.horizontal, 2)
            .glassEffect(.regular.interactive(), in: .capsule)
            Text(title)
                .orbitFont(.title, weight: .semibold)
                .lineLimit(1)
            Spacer()
        }
        .padding(.leading, sidebarHidden ? Self.windowButtonsInset : 16)
        .padding(.trailing, 16)
        .animation(.default, value: sidebarHidden)
        .frame(height: 52)
        .background {
            Color.clear
                .contentShape(.rect)
                .gesture(WindowDragGesture())
        }
    }
}

// MARK: - General

struct GeneralSettings: View {
    @State private var commandInstalled = CommandLineTool.isInstalled
    @Bindable private var preferences = Preferences.shared
    /// Mirrors of Sparkle's settings: it isn't observable.
    @State private var checksAutomatically = Updater.shared.checksAutomatically
    @State private var installsAutomatically = Updater.shared.installsAutomatically

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty || build == short ? short : "\(short) (\(build))"
    }

    var body: some View {
        SettingsForm {
            Section {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Orbit")
                            .orbitFont(.control, weight: .semibold)
                        Text("Version \(version)")
                            .orbitFont(.body)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button("Check for Updates…") { Updater.shared.checkForUpdates() }
                        .disabled(!Updater.isEnabled)
                }
                .padding(.vertical, 2)
                .settingsItem("updates")
                Toggle("Check for Orbit updates automatically", isOn: $checksAutomatically)
                    .onChange(of: checksAutomatically) { _, on in Updater.shared.checksAutomatically = on }
                    .disabled(!Updater.isEnabled)
                    .settingsItem("checkAutomatically")
                Toggle(isOn: $installsAutomatically) {
                    Text("Download and install them")
                    Text("Ready the next time Orbit starts.")
                }
                .onChange(of: installsAutomatically) { _, on in Updater.shared.installsAutomatically = on }
                .disabled(!Updater.isEnabled || !checksAutomatically)
                .settingsItem("installAutomatically")
            } header: {
                Text("Software Update")
            } footer: {
                if !Updater.isEnabled {
                    Text("Updates are off in development builds.")
                }
            }

            Section {
                Toggle(isOn: $preferences.autoUpdatesAgents) {
                    Text("Agents")
                    Text("From the ACP registry. Open chats keep their version until they restart.")
                }
                .settingsItem("autoAgents")
                Toggle(isOn: $preferences.autoUpdatesLanguageServers) {
                    Text("Language servers")
                    Text("The ones Orbit installed; servers already on your Mac are left alone.")
                }
                .settingsItem("autoLanguageServers")
                Toggle(isOn: $preferences.autoUpdatesExtensions) {
                    Text("Themes and icons")
                    Text("Extensions installed from the catalog.")
                }
                .settingsItem("autoExtensions")
            } header: {
                Text("Keep Up to Date")
            } footer: {
                Text("Checked in the background once a day, a little after Orbit starts.")
            }

            Section {
                LabeledContent {
                    if commandInstalled {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                    } else {
                        Button("Install…") {
                            CommandLineTool.install()
                            commandInstalled = CommandLineTool.isInstalled
                        }
                    }
                } label: {
                    Text("orbit command")
                    Text("Open folders and files from a terminal: orbit . or orbit src/main.swift")
                }
                .settingsItem("command")
            } header: {
                Text("Command Line")
            }

            Section {
                LabeledContent {
                    Button("Open") { NSWorkspace.shared.open(Self.prepared(ProjectSettings.userFile)) }
                } label: {
                    Text("Global settings")
                    Text(ProjectSettings.userPath)
                        .orbitFont(.caption, design: .monospaced)
                }
                .settingsItem("globalSettings")
                LabeledContent {
                    Button("Show in Finder") {
                        let folder = ProjectSettings.userFile.deletingLastPathComponent()
                        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                } label: {
                    Text("Orbit folder")
                    Text("Agents, language servers, grammars and extensions Orbit downloads.")
                }
                .settingsItem("folder")
            } header: {
                Text("Files")
            } footer: {
                Text("~/.orbit/settings.json applies to every project; a project's .orbit/settings.json wins over it.")
            }
        }
        .onAppear { commandInstalled = CommandLineTool.isInstalled }
    }

    /// Makes the file (with empty sections) so there's something to open.
    static func prepared(_ url: URL) -> URL {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? ProjectSettings.template.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }
}

// MARK: - Appearance

struct AppearanceSettings: View {
    let host: PluginHost
    @Bindable private var preferences = Preferences.shared
    @Environment(SettingsNavigator.self) private var navigator: SettingsNavigator?

    var body: some View {
        SettingsForm {
            Section {
                HStack(spacing: 18) {
                    ForEach([Preferences.Appearance.system, .light, .dark], id: \.self) { mode in
                        AppearanceChoice(mode: mode, isSelected: preferences.appearance == mode) {
                            preferences.appearance = mode
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .settingsItem("mode")
            } header: {
                Text("Mode")
            }

            Section {
                if preferences.appearance != .dark {
                    ThemePicker(title: preferences.appearance == .light ? "Theme" : "Light theme", dark: false)
                        .settingsItem("theme")
                }
                if preferences.appearance != .light {
                    ThemePicker(title: preferences.appearance == .dark ? "Theme" : "Dark theme", dark: true)
                        .settingsItem("theme")
                }
                LabeledContent {
                    Button("Browse Themes…") {
                        navigator?.push("Theme Catalog") { ExtensionCatalogPage() }
                    }
                } label: {
                    Text("More themes")
                    Text("Try on any of Zed's themes before installing it. ⌃⌘T switches themes from anywhere.")
                }
                .settingsItem("moreThemes")
            } header: {
                Text("Color Theme")
            } footer: {
                Text("A theme colors the editor, the terminal and the window behind the sidebars, and sets the accent color.")
            }

            Section {
                LabeledContent {
                    FontSizeControl(size: $preferences.interfaceTextSize, reset: Preferences.defaultInterfaceTextSize, range: Preferences.interfaceTextSizes)
                } label: {
                    Text("Interface")
                    Text("The file tree, tabs, panels and Settings.")
                }
                .settingsItem("interfaceSize")
                Toggle(isOn: Binding(
                    get: { preferences.chatTextSize == nil },
                    set: { preferences.chatTextSize = $0 ? nil : preferences.interfaceTextSize }
                )) {
                    Text("Chat matches the interface")
                    Text("Agents' replies, your messages and the composer.")
                }
                .settingsItem("chatSize")
                if let size = preferences.chatTextSize {
                    LabeledContent("Chat") {
                        FontSizeControl(
                            size: Binding(get: { size }, set: { preferences.chatTextSize = $0 }),
                            reset: preferences.interfaceTextSize, range: Preferences.interfaceTextSizes
                        )
                    }
                }
                LabeledContent {
                    FontSizeControl(size: $preferences.codeFontSize, reset: Preferences.defaultCodeFontSize)
                } label: {
                    Text("Code")
                    Text("The editor and diffs; its font is in Editor.")
                }
                .settingsItem("codeSize")
                Toggle(isOn: Binding(
                    get: { preferences.terminalFontSize == nil },
                    set: { preferences.terminalFontSize = $0 ? nil : preferences.codeFontSize }
                )) {
                    Text("Terminal matches the code")
                }
                .settingsItem("terminalSize")
                if let size = preferences.terminalFontSize {
                    LabeledContent("Terminal") {
                        FontSizeControl(size: Binding(get: { size }, set: { preferences.terminalFontSize = $0 }), reset: preferences.codeFontSize)
                    }
                }
            } header: {
                Text("Text Size")
            } footer: {
                Text("⌘= ⌘- ⌘0 change the code size from anywhere.")
            }

            Section("File Icons") {
                if preferences.appearance != .dark {
                    IconThemePicker(title: preferences.appearance == .light ? "Icons" : "Light icons", dark: false)
                        .settingsItem("icons")
                }
                if preferences.appearance != .light {
                    IconThemePicker(title: preferences.appearance == .dark ? "Icons" : "Dark icons", dark: true)
                        .settingsItem("icons")
                }
            }
        }
    }
}

/// A small window in the mode's theme colors, like System Settings' Appearance.
private struct AppearanceChoice: View {
    let mode: Preferences.Appearance
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                thumbnail
                    .frame(width: 96, height: 62)
                    .clipShape(.rect(cornerRadius: Theme.smallCorner, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.smallCorner, style: .continuous)
                            .strokeBorder(Theme.hairline)
                    }
                    .padding(3)
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.smallCorner + 3, style: .continuous)
                            .strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 2.5)
                    }
                Text(title)
                    .orbitFont(.body, weight: isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var title: String {
        switch mode {
        case .system: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    @ViewBuilder private var thumbnail: some View {
        switch mode {
        case .light: ModeThumbnail(dark: false)
        case .dark: ModeThumbnail(dark: true)
        case .system:
            // Light and dark halves split on the diagonal, like macOS's Auto.
            ModeThumbnail(dark: false)
                .overlay {
                    ModeThumbnail(dark: true).mask(DiagonalHalf())
                }
        }
    }
}

/// The lower right half of a rectangle, corner to corner.
private struct DiagonalHalf: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

/// The picked theme as a tiny window: sidebar, a tab, a few lines of code.
private struct ModeThumbnail: View {
    let dark: Bool

    var body: some View {
        let theme = Extensions.shared.pickedColorTheme(dark: dark)
        let background = theme.editorBackground?.color ?? (dark ? Color(white: 0.12) : .white)
        let text = theme.editorForeground?.color ?? (dark ? .white : .black)
        let accent = theme.accent?.color ?? text
        GeometryReader { proxy in
            let width = proxy.size.width
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(0..<4, id: \.self) { row in
                        Capsule().fill(text.opacity(row == 1 ? 0.5 : 0.2)).frame(width: width * 0.16, height: 2.5)
                    }
                    Spacer()
                }
                .padding(.top, 10)
                .padding(.leading, 6)
                .frame(width: width * 0.28, alignment: .leading)
                .frame(maxHeight: .infinity)
                .background(text.opacity(dark ? 0.06 : 0.05))
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array([0.55, 0.38, 0.62, 0.3, 0.48].enumerated()), id: \.offset) { index, length in
                        Capsule()
                            .fill(index == 2 ? accent.opacity(0.85) : text.opacity(0.32))
                            .frame(width: width * 0.72 * length, height: 2.5)
                            .padding(.leading, index == 1 || index == 2 ? 6 : 0)
                    }
                    Spacer()
                }
                .padding(.top, 10)
                .padding(.leading, 7)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .background(background)
    }
}

// MARK: - Project

struct ProjectSettingsPane: View {
    let host: PluginHost
    let root: URL

    private var settings: ProjectSettings { host.workspace.settings }
    private var file: URL { ProjectSettings.projectFile(root: root) }

    var body: some View {
        let values = settings.projectValues
        let exists = FileManager.default.fileExists(atPath: file.path)
        SettingsForm {
            Section {
                LabeledContent {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([root]) }
                } label: {
                    Text("Location")
                    Text((root.path as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(root.path)
                }
            }

            Section {
                ForEach(settings.problems, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if values.isEmpty {
                    Text(exists ? "The file sets nothing Settings shows yet." : "This project uses your settings as they are.")
                        .foregroundStyle(.secondary)
                }
                ForEach(values, id: \.key) { entry in
                    LabeledContent {
                        HStack(spacing: 8) {
                            Text(Self.display(entry.value))
                                .orbitFont(.body, design: .monospaced)
                            Button {
                                withAnimation(.smooth) { ProjectSettingWriter.write(entry.key, nil, in: host.workspace) }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .help("Remove from \(ProjectSettings.projectPath); Settings decides again")
                        }
                    } label: {
                        Text(entry.key)
                            .orbitFont(.body, design: .monospaced)
                    }
                }
                LabeledContent {
                    Button(exists ? "Open" : "Create") {
                        host.commands.run("editor.openProjectSettings")
                        host.ui.isSettingsVisible = false
                    }
                } label: {
                    Text("Project settings")
                    Text(ProjectSettings.projectPath)
                        .orbitFont(.caption, design: .monospaced)
                }
                .settingsItem("file")
            } header: {
                Text("Overrides")
            } footer: {
                Text("""
                What a project sets wins over Settings, for everyone who opens it: "editor": { "wordWrap": true }, \
                "agents": { "default": "codex" }, formatters, language servers and MCP servers. \
                Options it decides carry a Project badge in their pane; right-click an option there to set it for this project or take it out again.
                """)
            }
        }
    }

    private static func display(_ value: ProjectSettings.Value) -> String {
        switch value {
        case .bool(let value): value ? "true" : "false"
        case .number(let value): value.formatted()
        case .string(let value): "\"\(value)\""
        }
    }
}
