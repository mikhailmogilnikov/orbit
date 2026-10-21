import OrbitKit
import SwiftUI

/// Settings → Extensions (D192, D195): everything that can be added to Orbit
/// in one list — agents, language servers, extension packages (themes,
/// icons, snippets…) and Orbit's own features — with one search and a filter
/// by kind. Each group ends with a way to get more, as System Settings'
/// lists end with "Add…". Each kind is an `ExtensionSource`; plugins register
/// theirs, the shell adds packages and features.
struct ExtensionsSettings: View {
    enum Tab: String { case installed, catalog }

    /// Set to "catalog" to open the catalog page when the pane appears (the try-on bar's Catalog).
    static let tabKey = "orbit.extensionsTab"
    @AppStorage(ExtensionsSettings.tabKey) private var tab = Tab.installed
    @Environment(SettingsNavigator.self) private var navigator: SettingsNavigator?
    let host: PluginHost
    @State private var query = ""
    /// nil: every kind.
    @State private var kind: ExtensionKind?

    private var sources: [any ExtensionSource] {
        (host.ui.extensionSources + [PackageExtensionSource(host: host), FeatureExtensionSource(host: host)])
            .sorted { $0.kind < $1.kind }
    }

    var body: some View {
        let query = query.trimmingCharacters(in: .whitespaces)
        let sources = sources.filter { kind == nil || $0.kind == kind }
        let found = sources.map { (source: $0, installed: $0.installed.filter { $0.matches(query) }) }
        let available = query.isEmpty ? [] : sources.map { (source: $0, items: $0.available(matching: query)) }
        let nothingFound = !query.isEmpty && found.allSatisfy(\.installed.isEmpty) && available.allSatisfy(\.items.isEmpty)
            && !(kind == nil || kind == .packages)
        SettingsForm {
            Section {
                SettingsSearchField("Search agents, languages, packages and features", text: $query)
                Picker("Show", selection: $kind) {
                    Text("All").tag(ExtensionKind?.none)
                    ForEach(ExtensionKind.allCases, id: \.self) { kind in
                        Text(kind.shortTitle).tag(ExtensionKind?.some(kind))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if nothingFound {
                Section {
                    ContentUnavailableView.search(text: query)
                }
            }
            ForEach(found, id: \.source.kind) { source, installed in
                // A group shows when it has something to say: rows, or (one kind, or
                // nothing typed) the way to get more.
                if !installed.isEmpty || query.isEmpty {
                    Section {
                        if installed.isEmpty {
                            Text("None installed yet.").foregroundStyle(.secondary)
                        }
                        // One that requires the row before it is a sub-row of that
                        // row, as System Settings nests dependent options (D194).
                        ForEach(Self.grouped(installed), id: \.first!.id) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(group) { item in
                                    ExtensionRow(item: item)
                                        .padding(.leading, item.isNested && item.id != group.first?.id ? 38 : 0)
                                        .settingsItem(item.id)
                                }
                            }
                        }
                        if query.isEmpty { getMore(source) }
                    } header: {
                        SectionHeader(title: kind == nil ? source.kind.title : "Installed", count: source.kind == .features ? nil : installed.count)
                    } footer: {
                        footer(source.kind)
                    }
                }
            }
            if let kind, let source = sources.first, query.isEmpty, kind != .features {
                // One kind, nothing typed: its whole catalog under what's installed.
                AvailableSection(source: source, query: "", limit: nil)
            }
            ForEach(available, id: \.source.kind) { source, items in
                if !items.isEmpty {
                    AvailableSection(source: source, query: query, limit: kind == nil ? 5 : nil,
                                     title: kind == nil ? "Available \(source.kind.title)" : "Available") {
                        self.kind = source.kind
                    }
                }
            }
            if !query.isEmpty, kind == nil || kind == .packages {
                Section {
                    catalogLink(query: query)
                } header: {
                    SectionHeader(title: "In Zed's Catalog")
                }
            }
            if kind == nil || kind == .packages {
                ExtensionProblemsSection()
            }
        }
        .onAppear {
            if let requested = host.ui.requestedExtensionKind {
                kind = requested
                host.ui.requestedExtensionKind = nil
            }
            // Side by side: the registry download needn't wait for Mason's.
            for source in self.sources { Task { await source.refresh() } }
            guard tab == .catalog else { return }
            tab = .installed
            navigator?.push("Catalog") { ExtensionCatalogPage() }
        }
        .onChange(of: host.ui.requestedExtensionKind) { _, requested in
            guard let requested else { return }
            kind = requested
            host.ui.requestedExtensionKind = nil
        }
    }

    /// The group's last rows: where more of its kind come from.
    @ViewBuilder
    private func getMore(_ source: any ExtensionSource) -> some View {
        switch source.kind {
        case .agents, .languageServers:
            if kind == nil {
                Button {
                    withAnimation(.snappy) { kind = source.kind }
                } label: {
                    AddRow(title: "Get More \(source.kind.title)…", trailing: source.isLoading ? nil : "\(source.available(matching: "").count)")
                }
                .buttonStyle(.plain)
                .settingsItem("getMore." + source.kind.rawValue)
            }
        case .packages:
            if kind == nil {
                Button {
                    withAnimation(.snappy) { kind = .packages }
                } label: {
                    AddRow(title: "Get More Packages…", trailing: source.isLoading ? nil : "\(source.available(matching: "").count)")
                }
                .buttonStyle(.plain)
                .settingsItem("getMore.packages")
            }
            catalogLink(query: "")
            SettingsLink("Your Snippets") {
                SnippetsPage(root: host.workspace.root)
            } label: {
                SettingsLabel("Your Snippets", subtitle: "~/.orbit/snippets, and .orbit/snippets in the project",
                              systemImage: "text.badge.plus", tint: .teal)
            }
            .settingsItem("snippets")
            Button {
                NewExtension.create(navigator: navigator)
            } label: {
                AddRow(title: "New Extension…")
            }
            .buttonStyle(.plain)
            .settingsItem("newExtension")
        case .features:
            EmptyView()
        }
    }

    private func catalogLink(query: String) -> some View {
        SettingsLink("Catalog") {
            ExtensionCatalogPage(query: query)
        } label: {
            SettingsLabel(query.isEmpty ? "Browse Themes, Icons & Snippets" : "Search Zed's Catalog for “\(query)”",
                          subtitle: "Zed's extension catalog; try a theme on before installing it",
                          systemImage: "square.grid.2x2.fill", tint: .pink)
        }
        .settingsItem("catalog")
    }

    @ViewBuilder
    private func footer(_ kind: ExtensionKind) -> some View {
        switch kind {
        case .features:
            Text("A feature that's off isn't loaded at all. Switches take effect right away, in every window.")
        case .packages:
            Text("Packages live in ~/.orbit/extensions and reload as their files change. Zed's theme, icon and snippet extensions work as they are.")
        default:
            EmptyView()
        }
    }

    /// Each row with the nested rows right after it.
    static func grouped(_ items: [ExtensionItem]) -> [[ExtensionItem]] {
        var groups: [[ExtensionItem]] = []
        for item in items {
            if item.isNested, !groups.isEmpty { groups[groups.count - 1].append(item) } else { groups.append([item]) }
        }
        return groups
    }
}

/// A group's title with its count at the trailing edge, as System Settings' lists.
private struct SectionHeader: View {
    let title: String
    var count: Int?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let count, count > 0 {
                Text("\(count)")
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// "Add…" at the end of a group: a plus in the accent of a link, the rest quiet.
private struct AddRow: View {
    let title: String
    var trailing: String?
    var systemImage = "plus"

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .orbitFont(.body, weight: .semibold)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.smallCorner, style: .continuous))
            Text(title)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing).foregroundStyle(.secondary).monospacedDigit()
            }
            Image(systemName: "chevron.right")
                .orbitFont(.caption, weight: .semibold)
                .foregroundStyle(.tertiary)
        }
        .contentShape(.rect)
    }
}

/// A source's catalog: what's not installed yet, with Install on each.
private struct AvailableSection: View {
    let source: any ExtensionSource
    let query: String
    /// Rows shown before "Show All" (searching every kind); nil shows all.
    let limit: Int?
    var title = "Available"
    var showAll: () -> Void = {}

    var body: some View {
        let available = source.available(matching: query)
        Section {
            if available.isEmpty {
                HStack(spacing: 8) {
                    if source.isLoading {
                        ProgressView().controlSize(.small)
                        Text("Loading…").foregroundStyle(.secondary)
                    } else if let error = source.loadError {
                        Text("Couldn't load the catalog: \(error)").foregroundStyle(.secondary)
                        Spacer()
                        Button("Try Again") { Task { await source.refresh() } }
                    } else {
                        Text(query.isEmpty ? "Everything here is installed." : "Nothing matches “\(query)”.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(limit.map { Array(available.prefix($0)) } ?? available) { item in
                ExtensionRow(item: item)
            }
            if let limit, available.count > limit {
                Button {
                    withAnimation(.snappy) { showAll() }
                } label: {
                    AddRow(title: "Show All", trailing: "\(available.count)", systemImage: "ellipsis")
                }
                .buttonStyle(.plain)
            }
        } header: {
            SectionHeader(title: title, count: limit == nil ? available.count : nil)
        } footer: {
            if limit == nil { Text(source.catalogName) }
        }
    }
}

/// One installed or available thing; what it can do comes from its source.
private struct ExtensionRow: View {
    let item: ExtensionItem
    @Environment(SettingsNavigator.self) private var navigator: SettingsNavigator?

    var body: some View {
        if let page = item.page {
            SettingsLink(item.name) {
                page()
            } label: {
                content
            }
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 10) {
            item.icon()
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.name)
                    if let detail = item.detail {
                        Text(detail)
                            .orbitFont(.micro)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                if let warning = item.warning {
                    Text(warning)
                        .orbitFont(.caption)
                        .foregroundStyle(.orange)
                } else if !item.summary.isEmpty {
                    Text(item.summary)
                        .orbitFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let failure = item.failure {
                    Text(failure)
                        .orbitFont(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 2)
        .contextMenu { menuItems }
    }

    @ViewBuilder private var trailing: some View {
        HStack(spacing: 10) {
            if item.isBusy {
                ProgressView().controlSize(.small)
            } else if let install = item.install, !item.isInstalled {
                Button("Install") { Task { await install() } }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
            } else if let update = item.update, let latest = item.latestVersion {
                Button("Update") { Task { await update() } }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                    .help("Update to \(latest)")
            }
            if let pane = item.settingsPane, item.isEnabled != false {
                Button {
                    navigator?.show(pane)
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Settings")
            }
            if hasMenu {
                Menu {
                    menuItems
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Show in Finder, Uninstall")
            }
            if let isEnabled = item.isEnabled, let setEnabled = item.setEnabled {
                Toggle("", isOn: Binding(get: { isEnabled }, set: { setEnabled($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help(isEnabled ? "Turn \(item.name) off" : "Turn \(item.name) on")
                    .disabled(item.isSwitchLocked)
            }
        }
    }

    private var hasMenu: Bool { item.page == nil && (item.folder != nil || item.uninstall != nil) }

    @ViewBuilder private var menuItems: some View {
        if let folder = item.folder {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
        }
        if let uninstall = item.uninstall {
            Divider()
            Button("Uninstall", role: .destructive) { uninstall() }
        }
    }
}

private struct ExtensionProblemsSection: View {
    var body: some View {
        let problems = Extensions.shared.problems
        if !problems.isEmpty {
            Section("Problems") {
                ForEach(problems) { problem in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(problem.location.lastPathComponent)
                            Text(problem.message)
                                .orbitFont(.micro)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }
}

/// Extension folders (D195): what each brings, its own page, uninstalling;
/// Orbit's registry is their catalog (D224). Zed's catalog has a page of its
/// own, where themes are tried on.
final class PackageExtensionSource: ExtensionSource {
    let host: PluginHost
    init(host: PluginHost) { self.host = host }

    var kind: ExtensionKind { .packages }
    var catalogName: String { "From Orbit's extension registry, github.com/mikhailmogilnikov/orbit-extensions. A package that runs programs asks before it's installed." }
    var isLoading: Bool { ExtensionRegistry.shared.isLoading }
    var loadError: String? { ExtensionRegistry.shared.loadError }
    func refresh() async { await ExtensionRegistry.shared.refresh() }

    var installed: [ExtensionItem] {
        let catalog = ExtensionCatalog.shared
        let registry = ExtensionRegistry.shared
        let host = host
        return Extensions.shared.installed.map { installed in
            var item = ExtensionItem(
                id: "package:" + installed.id, name: installed.manifest.name,
                summary: installed.manifest.description.flatMap { $0.isEmpty ? nil : $0 } ?? PackageContents.summary(of: installed),
                detail: installed.isBuiltin ? "Built-in" : installed.manifest.version,
                keywords: ["extension", "package", "theme", "icons", "snippets"] + PackageContents.kinds(of: installed),
                isInstalled: true, isBuiltin: installed.isBuiltin
            ) {
                PackageTile(installed: installed, size: 28)
            }
            if installed.manifest.description?.isEmpty == false {
                item.summary += " — " + PackageContents.summary(of: installed)
            }
            item.failure = catalog.failures[installed.id] ?? registry.failures[installed.id]
            item.isBusy = catalog.busy.contains(installed.id) || registry.busy.contains(installed.id)
            if let entry = registry.entries.first(where: { $0.id == installed.id }), registry.hasUpdate(entry) {
                item.latestVersion = entry.version
                item.update = { await registry.install(entry, confirm: ProgramConsent.ask) }
            }
            item.page = { AnyView(PackagePage(id: installed.id, host: host)) }
            return item
        }
    }

    func available(matching query: String) -> [ExtensionItem] {
        let registry = ExtensionRegistry.shared
        return registry.entries
            .filter { registry.installed($0) == nil && !registry.isTaken($0) }
            .map { entry in
                let kinds = Self.kinds(entry.provides)
                var item = ExtensionItem(
                    id: "registry:" + entry.id, name: entry.name,
                    summary: [entry.description, kinds.isEmpty ? nil : kinds.joined(separator: " · ")]
                        .compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " — "),
                    detail: entry.version,
                    keywords: ["extension", "package"] + kinds + entry.authors,
                    isInstalled: false
                ) {
                    RegistryTile(entry: entry, size: 28)
                }
                item.isBusy = registry.busy.contains(entry.id)
                item.failure = registry.failures[entry.id]
                item.install = { await registry.install(entry, confirm: ProgramConsent.ask) }
                return item
            }
            .filter { $0.matches(query) }
    }

    /// The registry's `provides`, said plainly.
    static func kinds(_ provides: [String]) -> [String] {
        let names = ["agents": "Agents", "language-servers": "Language servers", "tasks": "Tasks",
                     "themes": "Themes", "icon-themes": "Icons", "snippets": "Snippets"]
        return provides.compactMap { names[$0] }
    }
}

/// Asks before a download that starts programs is installed (D224), naming each one.
@MainActor
enum ProgramConsent {
    static func ask(_ entry: RegistryEntry, _ programs: [ExtensionProgram]) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "“\(entry.name)” runs programs on your Mac"
        let authors = entry.authors.map { $0.split(separator: "<").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? $0 }
        let lines = programs.map { program in
            let kind = switch program.kind {
            case .agent: "Agent"
            case .languageServer: "Language server"
            case .task: "Task"
            }
            return "\(kind) “\(program.name)”: \(program.command)"
        }
        alert.informativeText = """
            Install it only if you trust \(authors.isEmpty ? "its author" : authors.formatted()). It can start:

            \(lines.joined(separator: "\n"))

            Agents and language servers start when you use them, tasks when you run them.
            """
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        return alert.runSheetModal() == .alertFirstButtonReturn
    }
}

/// A registry entry's tile, picked as `PackageTile` picks an installed one's.
struct RegistryTile: View {
    let entry: RegistryEntry
    let size: CGFloat

    var body: some View {
        let provides = Set(entry.provides)
        let (symbol, tint): (String, Color) = if entry.runsPrograms {
            ("shippingbox.fill", .pink)
        } else if provides.contains("themes") {
            ("paintpalette.fill", .purple)
        } else if provides.contains("icon-themes") {
            ("doc.richtext.fill", .orange)
        } else if provides.contains("snippets") {
            ("text.badge.plus", .teal)
        } else {
            ("shippingbox.fill", .gray)
        }
        SettingsTile(symbol, tint: tint, size: size)
    }
}

/// What a package brings, said plainly: "2 themes · 14 snippets · 1 agent".
enum PackageContents {
    static func parts(of item: InstalledExtension) -> [(count: Int, one: String, many: String, symbol: String)] {
        [
            (item.themeCount, "theme", "themes", "paintpalette"),
            (item.iconThemeCount, "icon theme", "icon themes", "doc.richtext"),
            (item.snippetCount, "snippet", "snippets", "text.badge.plus"),
            (item.agentCount, "agent", "agents", "sparkles"),
            (item.languageServerCount, "language server", "language servers", "curlybraces"),
            (item.taskCount, "task", "tasks", "play"),
        ].filter { $0.count > 0 }
    }

    static func summary(of item: InstalledExtension) -> String {
        let parts = parts(of: item).map { "\($0.count) \($0.count == 1 ? $0.one : $0.many)" }
        return parts.isEmpty ? "Nothing Orbit reads yet" : parts.joined(separator: " · ")
    }

    static func kinds(of item: InstalledExtension) -> [String] {
        parts(of: item).map(\.many)
    }
}

/// A package's tile: what it mostly is, in System Settings' colors.
struct PackageTile: View {
    let installed: InstalledExtension
    let size: CGFloat

    var body: some View {
        let (symbol, tint): (String, Color) = if installed.runsPrograms {
            ("shippingbox.fill", .pink)
        } else if installed.themeCount > 0 {
            ("paintpalette.fill", .purple)
        } else if installed.iconThemeCount > 0 {
            ("doc.richtext.fill", .orange)
        } else if installed.snippetCount > 0 {
            ("text.badge.plus", .teal)
        } else {
            ("shippingbox.fill", .gray)
        }
        SettingsTile(symbol, tint: tint, size: size)
    }
}

/// One package (D195): what's in it, what it runs, where it lives.
struct PackagePage: View {
    let id: String
    let host: PluginHost
    @Environment(SettingsNavigator.self) private var navigator: SettingsNavigator?
    @Bindable private var preferences = Preferences.shared

    var body: some View {
        let extensions = Extensions.shared
        if let installed = extensions.installed.first(where: { $0.id == id }) {
            let manifest = installed.manifest
            SettingsForm {
                Section {
                    HStack(spacing: 12) {
                        PackageTile(installed: installed, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(manifest.name).orbitFont(.title, weight: .semibold)
                                Text(installed.isBuiltin ? "Built-in" : manifest.version)
                                    .orbitFont(.caption).foregroundStyle(.tertiary)
                            }
                            if let description = manifest.description, !description.isEmpty {
                                Text(description).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let authors = manifest.authors, !authors.isEmpty {
                                Text(authors.map { $0.split(separator: "<").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? $0 }.joined(separator: ", "))
                                    .orbitFont(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                }

                let themes = extensions.colorThemes.filter { $0.extensionID == id }
                if !themes.isEmpty {
                    Section {
                        ForEach(themes) { theme in
                            let isPicked = theme.id == (theme.isDark ? preferences.darkThemeID : preferences.lightThemeID)
                            LabeledContent {
                                if isPicked {
                                    Label("In Use", systemImage: "checkmark").labelStyle(.titleAndIcon).foregroundStyle(.secondary)
                                } else {
                                    Button("Use") { extensions.choose(theme, from: themes) }
                                }
                            } label: {
                                Label(theme.name, systemImage: theme.isDark ? "moon.fill" : "sun.max.fill")
                            }
                        }
                    } header: {
                        Text("Color Themes")
                    }
                }

                let icons = extensions.iconThemes.filter { $0.id.hasPrefix(id + "/") }
                if !icons.isEmpty {
                    Section {
                        ForEach(icons) { icons in
                            LabeledContent {
                                if preferences.lightIconThemeID == icons.id, preferences.darkIconThemeID == icons.id {
                                    Label("In Use", systemImage: "checkmark").foregroundStyle(.secondary)
                                } else {
                                    Button("Use") {
                                        preferences.lightIconThemeID = icons.id
                                        preferences.darkIconThemeID = icons.id
                                    }
                                }
                            } label: {
                                Text(icons.name)
                            }
                        }
                    } header: {
                        Text("File Icons")
                    }
                }

                let snippets = extensions.snippets.filter { $0.source == manifest.name }
                if !snippets.isEmpty {
                    SnippetList(snippets: snippets, title: "Snippets")
                }

                let runs = PackagePrograms.list(of: installed)
                if !runs.isEmpty {
                    Section {
                        ForEach(runs, id: \.name) { program in
                            LabeledContent {
                                Text(program.command)
                                    .orbitFont(.caption, design: .monospaced)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            } label: {
                                Label(program.name, systemImage: program.symbol)
                            }
                        }
                    } header: {
                        Text("Runs on Your Mac")
                    } footer: {
                        Text("Agents and language servers start when you use them; tasks when you run them from Run Task… (⌃⌘R).")
                    }
                }

                let problems = extensions.problems.filter { $0.location.path.hasPrefix(installed.directory.path) }
                if !problems.isEmpty {
                    Section("Problems") {
                        ForEach(problems) { problem in
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(problem.location.lastPathComponent)
                                    Text(problem.message).orbitFont(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            }
                        }
                    }
                }

                if !installed.isBuiltin {
                    Section {
                        LabeledContent {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([installed.directory]) }
                        } label: {
                            Text("Folder")
                            Text((installed.directory.path as NSString).abbreviatingWithTildeInPath)
                                .orbitFont(.caption, design: .monospaced)
                        }
                        if let repository = manifest.repository, let url = URL(string: repository) {
                            LabeledContent {
                                Button("Open") { NSWorkspace.shared.open(url) }
                            } label: {
                                Text("Repository")
                                Text(repository).orbitFont(.caption)
                            }
                        }
                        LabeledContent {
                            Button("Uninstall…", role: .destructive) { uninstall(installed) }
                        } label: {
                            Text("Uninstall \(manifest.name)")
                            Text("Moves its folder to the Trash.")
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView("Uninstalled", systemImage: "shippingbox", description: Text("This package isn't installed anymore."))
        }
    }

    private func uninstall(_ installed: InstalledExtension) {
        let alert = NSAlert()
        alert.messageText = "Uninstall \(installed.manifest.name)?"
        alert.informativeText = "Its folder goes to the Trash. Themes from it in use fall back to Orbit's."
        alert.addButton(withTitle: "Uninstall").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runSheetModal() == .alertFirstButtonReturn else { return }
        ExtensionCatalog.shared.uninstall(installed)
        navigator?.back()
    }
}

/// What a package runs (D195), read from its files for its page.
@MainActor
enum PackagePrograms {
    struct Program {
        var name: String
        var command: String
        var symbol: String
    }

    static func list(of installed: InstalledExtension) -> [Program] {
        // Read with the files' revision, so the page follows edits.
        _ = Extensions.shared.revision
        return Extensions.programs(in: installed.directory).map { program in
            let symbol = switch program.kind {
            case .agent: "sparkles"
            case .languageServer: "curlybraces"
            case .task: "play"
            }
            return Program(name: program.name, command: program.command, symbol: symbol)
        }
    }
}

/// Snippets as a list: the prefix you type, its name, its languages.
struct SnippetList: View {
    let snippets: [CodeSnippet]
    let title: String
    @State private var showsAll = false

    var body: some View {
        let shown = showsAll ? snippets : Array(snippets.prefix(8))
        Section {
            ForEach(shown) { snippet in
                LabeledContent {
                    Text(snippet.languages.isEmpty ? "Any language" : snippet.languages.joined(separator: ", "))
                        .orbitFont(.caption)
                        .foregroundStyle(.tertiary)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(snippet.prefixes.first ?? "")
                            .orbitFont(.caption, weight: .medium, design: .monospaced)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.tinyCorner))
                        Text(snippet.name)
                    }
                    if let description = snippet.description {
                        Text(description)
                    }
                }
                .help(Snippet(snippet.body).text)
            }
            if snippets.count > shown.count {
                Button("Show All \(snippets.count)") { withAnimation(.snappy) { showsAll = true } }
                    .buttonStyle(.link)
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
                Text("\(snippets.count)").monospacedDigit().foregroundStyle(.tertiary)
            }
        } footer: {
            Text("Type a prefix and pick it from the suggestions, or use Editor → Insert Snippet…; Tab goes to the next placeholder.")
        }
    }
}

/// Your own snippets and the project's (D195).
struct SnippetsPage: View {
    let root: URL?
    @Environment(SettingsNavigator.self) private var navigator: SettingsNavigator?

    var body: some View {
        let library = SnippetLibrary.shared
        SettingsForm {
            if library.userSnippets.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("No Snippets Yet", systemImage: "text.badge.plus")
                    } description: {
                        Text("A snippet is code you type by a short prefix, with places to fill in. Make a file for a language, or install a package of them.")
                    } actions: {
                        Button("New Snippet File…") { NewSnippetFile.create() }
                            .buttonStyle(.glassProminent)
                    }
                }
            } else {
                SnippetList(snippets: library.userSnippets, title: "Your Snippets")
            }
            Section {
                LabeledContent {
                    HStack {
                        Button("New File…") { NewSnippetFile.create() }
                        Button("Open Folder") { NSWorkspace.shared.open(SnippetLibrary.userDirectory) }
                    }
                } label: {
                    Text("Your snippets")
                    Text("~/.orbit/snippets: rust.json for Rust, snippets.json for every language")
                }
                if let root {
                    LabeledContent {
                        Button("Open Folder") {
                            let folder = SnippetLibrary.projectDirectory(root: root)
                            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(folder)
                        }
                    } label: {
                        Text("This project's")
                        Text(".orbit/snippets, shared with everyone working on it")
                    }
                }
            } footer: {
                Text("The format is VS Code's and Zed's, so their snippet files work as they are. They reload when saved.")
            }
        }
    }
}

/// A language's snippet file in ~/.orbit/snippets, with one example to copy.
@MainActor
enum NewSnippetFile {
    static func create() {
        let alert = NSAlert()
        alert.messageText = "New Snippet File"
        alert.informativeText = "The language its snippets are for, as a file type or name (swift, typescript, python). Leave it empty for every language."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "swift"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        guard alert.runSheetModal() == .alertFirstButtonReturn else { return }
        let language = field.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let name = language.isEmpty ? "snippets" : language
        let url = SnippetLibrary.userDirectory.appending(path: "\(name).json")
        let manager = FileManager.default
        try? manager.createDirectory(at: SnippetLibrary.userDirectory, withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path) {
            let example = """
            {
              // "prefix" is what you type; $1, $2 are the places Tab goes to, $0 where it ends.
              "Example": {
                "prefix": "example",
                "body": ["// ${1:what this does}", "$0"],
                "description": "An example: change or remove it"
              }
            }

            """
            try? example.write(to: url, atomically: true, encoding: .utf8)
        }
        ProjectWindows.shared.activeHost?.ui.isSettingsVisible = false
        ProjectWindows.shared.activeHost?.workspace.openFile(url)
    }
}

/// New Extension… (D195): a package folder with every part it can have,
/// documented in its README, ready to fill in.
@MainActor
enum NewExtension {
    static func create(navigator: SettingsNavigator?) {
        let alert = NSAlert()
        alert.messageText = "New Extension"
        alert.informativeText = "A folder in ~/.orbit/extensions with snippets to start from and a README on the rest: themes, agents, language servers, tasks."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "My Extension"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        guard alert.runSheetModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ? "My Extension" : field.stringValue.trimmingCharacters(in: .whitespaces)
        let id = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        let folder = Extensions.userDirectory.appending(path: id.isEmpty ? "my-extension" : id, directoryHint: .isDirectory)
        let manager = FileManager.default
        guard !manager.fileExists(atPath: folder.path) else {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
            return
        }
        do {
            try manager.createDirectory(at: folder.appending(path: "snippets"), withIntermediateDirectories: true)
            let manifest = """
            {
              "id": "\(id)",
              "name": "\(name)",
              "version": "0.1.0",
              "description": ""
            }

            """
            try manifest.write(to: folder.appending(path: "extension.json"), atomically: true, encoding: .utf8)
            let snippets = """
            {
              "Example": {
                "prefix": "example",
                "body": ["// ${1:what this does}", "$0"],
                "description": "An example snippet for every language"
              }
            }

            """
            try snippets.write(to: folder.appending(path: "snippets/snippets.json"), atomically: true, encoding: .utf8)
            try readme(name).write(to: folder.appending(path: "README.md"), atomically: true, encoding: .utf8)
        } catch {
            let failure = NSAlert(error: error)
            failure.runSheetModal()
            return
        }
        Extensions.shared.reload()
        NSWorkspace.shared.activateFileViewerSelecting([folder.appending(path: "README.md")])
    }

    private static func readme(_ name: String) -> String {
        """
        # \(name)

        An Orbit extension. Orbit reloads it whenever a file here changes.

        - `snippets/` — `<language>.json` (`rust.json`, `typescript.json`) or `snippets.json`
          for every language, in VS Code's format.
        - `themes/`, `icon_themes/` — Zed's theme formats.
        - `agents/<id>.json` — an ACP agent:
          `{ "id": "my-agent", "name": "My Agent", "command": { "executable": "my-agent", "arguments": ["--acp"] } }`
        - `language_servers.json` —
          `{ "servers": [ { "id": "…", "name": "…", "fileTypes": { "kt": "kotlin" }, "command": "kotlin-lsp",
          "install": { "mason": "kotlin-lsp" } } ] }`
        - `tasks.json` — `{ "tasks": [ { "name": "deploy", "command": "fly deploy", "when": "fly.toml" } ] }`

        See Orbit's docs/extensions.md for every key.

        """
    }
}

/// Orbit's own plugins (D194): switched on and off right away, never
/// installed. Orbit's core has no switch; one that requires another sits
/// under it and is greyed while that one is off.
final class FeatureExtensionSource: ExtensionSource {
    let host: PluginHost
    init(host: PluginHost) { self.host = host }

    var kind: ExtensionKind { .features }
    var catalogName: String { "Ship with Orbit." }

    var installed: [ExtensionItem] {
        let host = host
        // Required ones first: they read as the base the others add to.
        let entries = host.entries.filter(\.manifest.isRequired) + host.entries.filter { !$0.manifest.isRequired }
        return entries.map { entry in
            let manifest = entry.manifest
            var item = ExtensionItem(
                id: "feature:" + entry.id, name: manifest.name, summary: manifest.summary,
                detail: manifest.isRequired ? "Required" : nil,
                keywords: ["plugin", "feature"],
                isInstalled: true, isBuiltin: true
            ) {
                // A sub-row's tile is smaller, as in System Settings.
                SettingsTile(Self.filled(manifest.systemImage), tint: manifest.tint, size: manifest.requires.isEmpty ? 28 : 20)
            }
            if !manifest.isRequired {
                let missing = host.missingRequirements(of: entry.id)
                item.isEnabled = entry.isEnabled && missing.isEmpty
                item.isSwitchLocked = !missing.isEmpty
                item.isNested = !manifest.requires.isEmpty
                item.setEnabled = { on in Self.set(on, entry: entry, host: host) }
                if !missing.isEmpty {
                    item.warning = "Needs \(missing.joined(separator: " and ")) on"
                } else if let tool = manifest.tools.first(where: { !Self.isInstalled($0) }) {
                    item.warning = "Needs \(tool), which isn't on this Mac"
                }
            }
            if host.isActive(entry.id) {
                item.settingsPane = host.ui.settingsPanes.first { $0.pluginID == entry.id }?.id
            }
            return item
        }
    }

    func available(matching query: String) -> [ExtensionItem] { [] }

    /// Turning off stops work in every window: say what, and ask first.
    private static func set(_ on: Bool, entry: PluginHost.Entry, host: PluginHost) {
        if !on {
            let warnings = ProjectWindows.shared.allHosts.flatMap { $0.deactivationWarnings(for: entry.id) }
            if !warnings.isEmpty {
                let alert = NSAlert()
                alert.messageText = "Turn off \(entry.manifest.name)?"
                alert.informativeText = warnings.joined(separator: "\n")
                alert.addButton(withTitle: "Turn Off").hasDestructiveAction = true
                alert.addButton(withTitle: "Cancel")
                guard alert.runSheetModal() == .alertFirstButtonReturn else { return }
            }
        }
        host.setEnabled(on, pluginID: entry.id)
    }

    /// On the PATH a login shell gets, or where macOS and Homebrew put programs.
    private static func isInstalled(_ tool: String) -> Bool {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let folders = path.split(separator: ":").map(String.init) + ["/usr/bin", "/usr/local/bin", "/opt/homebrew/bin"]
        return folders.contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(tool)") }
    }

    /// Tiles carry filled symbols, as System Settings' do.
    private static func filled(_ name: String) -> String {
        NSImage(systemSymbolName: name + ".fill", accessibilityDescription: nil) != nil ? name + ".fill" : name
    }
}

/// The catalog as a Settings page: it lays itself out (a pinned try-on panel over a long list).
struct ExtensionCatalogPage: View {
    var query = ""

    var body: some View {
        ExtensionCatalogView(query: query)
            .contentMargins(.horizontal, 0, for: .scrollContent)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
    }
}

// MARK: - Catalog

struct ExtensionCatalogView: View {
    @AppStorage("orbit.catalogKind") private var kind = ExtensionCatalog.Kind.themes
    @State private var query: String

    init(query: String = "") {
        _query = State(initialValue: query)
    }
    /// The selected row is tried on, so arrowing through the list previews
    /// each extension like the theme selector does.
    @State private var selection: String?
    private var catalog: ExtensionCatalog { .shared }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("Search", text: $query, prompt: Text("Search Zed extensions"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                Picker("", selection: $kind) {
                    Text("Themes").tag(ExtensionCatalog.Kind.themes)
                    Text("Icons").tag(ExtensionCatalog.Kind.iconThemes)
                    Text("Snippets").tag(ExtensionCatalog.Kind.snippets)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            // Pinned above the list: what's tried on stays in view while scrolling.
            if kind.canTryOn || Extensions.shared.preview != nil {
                Group {
                    if Extensions.shared.preview != nil {
                        TryOnPanel()
                    } else {
                        TryOnHint()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            Divider()
            // A List is backed by a table view and only draws the visible rows;
            // Zed has hundreds of themes.
            List(selection: $selection) {
                ForEach(catalog.entries) { entry in
                    CatalogRow(entry: entry, canTryOn: kind.canTryOn)
                        .tag(entry.id)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .overlay {
                if catalog.entries.isEmpty {
                    if catalog.isLoading {
                        ProgressView().controlSize(.small)
                    } else if let error = catalog.loadError {
                        VStack(spacing: 6) {
                            Text("Couldn't load the catalog").orbitFont(.control, weight: .bold)
                            Text(error).orbitFont(.micro).foregroundStyle(.secondary)
                            Button("Try Again") { catalog.search(query, kind: kind) }
                                .buttonStyle(.glass)
                        }
                    } else {
                        Text("Nothing found").foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            Text("From Zed's extension catalog. Orbit installs the themes, icons and snippets; Zed's language support is its own code.")
                .orbitFont(.micro)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
        }
        .onAppear { selection = catalog.previewEntry?.id }
        // Debounced: typing restarts the task.
        .task(id: "\(kind.rawValue)|\(query)") {
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            catalog.search(query, kind: kind)
        }
        // Debounced too, so arrowing past rows doesn't download each one.
        .task(id: selection) {
            guard kind.canTryOn, let selection, selection != catalog.previewEntry?.id,
                  let entry = catalog.entries.first(where: { $0.id == selection }) else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await catalog.tryOn(entry)
        }
        .onChange(of: catalog.previewEntry?.id) { _, id in
            // Stopped or installed from the panel or the bar: the selection follows.
            if id == nil { selection = nil }
        }
    }
}

struct CatalogRow: View {
    let entry: CatalogEntry
    var canTryOn = true
    private var catalog: ExtensionCatalog { .shared }

    var body: some View {
        let installed = catalog.installed(entry)
        HStack(alignment: .center, spacing: 12) {
            if entry.provides.contains("themes") {
                ThemeThumbnail(themes: catalog.samples[entry.id])
                    .task { catalog.requestSample(entry) }
            } else if entry.provides.contains("snippets") {
                SettingsTile("text.badge.plus", tint: .teal, size: 40)
                    .frame(width: 58)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(entry.name).fontWeight(.medium)
                    Text(entry.version).orbitFont(.micro).foregroundStyle(.tertiary)
                }
                if let description = entry.description, !description.isEmpty {
                    Text(description)
                        .orbitFont(.micro)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(byline)
                    .orbitFont(.micro)
                    .foregroundStyle(.tertiary)
                if let failure = catalog.failures[entry.id] {
                    Text(failure)
                        .orbitFont(.micro)
                        .foregroundStyle(.red)
                }
            }
            Spacer(minLength: 8)
            if catalog.busy.contains(entry.id) {
                ProgressView().controlSize(.small)
            } else {
                HStack(spacing: 6) {
                    if let installed, !catalog.hasUpdate(entry) {
                        Menu("Installed") {
                            Button("Uninstall", role: .destructive) { catalog.uninstall(installed) }
                        }
                        .fixedSize()
                    } else {
                        Button(installed == nil ? "Install" : "Update") { Task { await catalog.install(entry) } }
                            .buttonStyle(.glassProminent)
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .help(canTryOn ? "Click to try it on" : "")
    }

    private var byline: String {
        // Zed authors are "Name <email>"; the name is enough here.
        let names = entry.authors.map { author in
            author.split(separator: "<").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? author
        }
        var parts: [String] = []
        if !names.isEmpty { parts.append(names.joined(separator: ", ")) }
        if let count = catalog.samples[entry.id]?.count, count > 1 { parts.append("\(count) themes") }
        parts.append("\(entry.downloadCount.formatted(.number.notation(.compactName))) downloads")
        return parts.joined(separator: " · ")
    }
}

/// A theme drawn as a tiny editor: its background with a few lines of code
/// in its syntax colors, the current mode's variant. A blank tile while loading.
struct ThemeThumbnail: View {
    let themes: [ColorTheme]?

    var body: some View {
        let theme = themes.flatMap { themes in
            themes.first { $0.isDark == Preferences.shared.isDark } ?? themes.first
        }
        ZStack(alignment: .topLeading) {
            if let theme {
                Rectangle().fill(color(theme.editorBackground, .textBackgroundColor))
                VStack(alignment: .leading, spacing: 4) {
                    bars(theme, [("keyword", 9), ("function", 17), (nil, 6)])
                    bars(theme, [(nil, 4), ("type", 12), ("string", 18)])
                    bars(theme, [(nil, 4), ("property", 10), ("number", 6)])
                    bars(theme, [("comment", 26)])
                }
                .padding(7)
            } else {
                Rectangle().fill(Theme.subtleFill)
            }
        }
        .frame(width: 58, height: 40)
        .clipShape(.rect(cornerRadius: Theme.smallCorner))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.smallCorner)
                .strokeBorder(Theme.hairline)
        }
    }

    private func bars(_ theme: ColorTheme, _ tokens: [(capture: String?, width: CGFloat)]) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                Capsule()
                    .fill(token.capture.map { color(theme.style(forCapture: $0)?.color ?? theme.editorForeground, .textColor) } ?? .clear)
                    .frame(width: token.width, height: 3)
            }
        }
    }

    private func color(_ value: ThemeColor?, _ fallback: NSColor) -> Color {
        Color(nsColor: value?.nsColor ?? fallback)
    }
}

/// The extension being tried on, pinned over the catalog: a sample in its
/// theme, which of its themes, Install / Stop.
struct TryOnPanel: View {
    private var extensions: Extensions { .shared }
    private var catalog: ExtensionCatalog { .shared }

    var body: some View {
        if let preview = extensions.preview {
            HStack(alignment: .top, spacing: 16) {
                ThemeSampleView(theme: preview.colorTheme ?? extensions.pickedColorTheme(dark: Preferences.shared.isDark))
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Trying On").orbitFont(.micro).foregroundStyle(.secondary)
                        Text(preview.manifest.name).orbitFont(.control, weight: .bold).lineLimit(2)
                    }
                    PreviewThemePickers(preview: preview)
                        .labelsHidden()
                    Spacer(minLength: 0)
                    HStack {
                        Button("Stop") { catalog.endPreview() }
                            .buttonStyle(.glass)
                        if let entry = catalog.previewEntry {
                            Button(catalog.installed(entry) == nil ? "Install" : "Update") {
                                Task { await catalog.install(entry) }
                            }
                            .buttonStyle(.glassProminent)
                            .disabled(catalog.busy.contains(entry.id))
                        }
                    }
                }
                .frame(width: 180, alignment: .leading)
                .padding(.vertical, 4)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Where the try-on panel appears, until something is tried on: says that a
/// click previews, which a plain list doesn't suggest.
struct TryOnHint: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "eye")
                .orbitFont(.title)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Click an extension to try it on")
                    .orbitFont(.body, weight: .medium)
                Text("The whole window previews it, nothing is installed. Use ↑ ↓ to go through the list.")
                    .orbitFont(.micro)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.corner))
    }
}

/// Which theme and icon set of the extension being tried on is drawn.
struct PreviewThemePickers: View {
    let preview: ExtensionPreview

    var body: some View {
        if preview.colorThemes.count > 1 {
            Picker("Theme", selection: Binding(
                get: { preview.colorThemeID },
                set: { Extensions.shared.preview?.colorThemeID = $0 }
            )) {
                ForEach(preview.colorThemes) { theme in
                    Text(theme.name).tag(Optional(theme.id))
                }
            }
        }
        if preview.iconThemes.count > 1 {
            Picker("File Icons", selection: Binding(
                get: { preview.iconThemeID },
                set: { Extensions.shared.preview?.iconThemeID = $0 }
            )) {
                ForEach(preview.iconThemes) { theme in
                    Text(theme.name).tag(Optional(theme.id))
                }
            }
        }
    }
}

/// A few lines of code, a file list and the terminal colors in `theme`:
/// Settings cover the editor, so this is where a theme is first seen.
struct ThemeSampleView: View {
    let theme: ColorTheme

    private static let files = ["Sources", "Package.swift", "README.md", "main.rs", "index.ts", "app.py", "package.json", "Makefile"]

    var body: some View {
        let foreground = color(theme.editorForeground, .textColor)
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Self.files, id: \.self) { name in
                    HStack(spacing: 6) {
                        FileIconView(url: URL(fileURLWithPath: "/sample/\(name)"), isFolder: name == "Sources", size: 14)
                            .foregroundStyle(foreground.opacity(0.7))
                            .frame(width: 14)
                        Text(name)
                            .orbitFont(.caption)
                            .foregroundStyle(foreground.opacity(0.85))
                            .lineLimit(1)
                    }
                }
            }
            .padding(10)
            .frame(width: 140, alignment: .leading)
            Rectangle()
                .fill(foreground.opacity(0.08))
                .frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(SampleCode.lines.enumerated()), id: \.offset) { index, tokens in
                    codeLine(index: index, tokens: tokens)
                }
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    ForEach(0..<8, id: \.self) { index in
                        Circle()
                            .fill(color(theme.terminalANSI[index], Self.ansiFallback[index]))
                            .frame(width: 9, height: 9)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .padding(.top, 8)
        }
        .background(color(theme.editorBackground, .textBackgroundColor))
        .clipShape(.rect(cornerRadius: Theme.smallCorner))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.smallCorner)
                .strokeBorder(Theme.hairline)
        }
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .padding(.vertical, 4)
    }

    private func codeLine(index: Int, tokens: [SampleCode.Token]) -> some View {
        let isActive = index == SampleCode.activeLine
        let marker: Color? = switch index {
        case SampleCode.addedLine: color(theme.added, .systemGreen)
        case SampleCode.modifiedLine: color(theme.modified, .systemOrange)
        default: nil
        }
        return HStack(spacing: 0) {
            Rectangle()
                .fill(marker ?? .clear)
                .frame(width: 2)
            Text("\(index + 1)")
                .orbitFont(.caption, design: .monospaced)
                .foregroundStyle(isActive ? color(theme.activeLineNumber ?? theme.editorForeground, .textColor) : color(theme.lineNumber, .tertiaryLabelColor))
                .frame(width: 26, alignment: .trailing)
                .padding(.trailing, 12)
            Text(attributed(tokens))
                .orbitFont(.code)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1.5)
        .background(isActive ? color(theme.activeLineBackground, .clear) : .clear)
    }

    private func attributed(_ tokens: [SampleCode.Token]) -> AttributedString {
        var line = AttributedString()
        for token in tokens {
            var piece = AttributedString(token.text)
            let style = token.capture.flatMap(theme.style(forCapture:))
            piece.foregroundColor = color(style?.color ?? theme.editorForeground, .textColor)
            var font = Font.orbit(.code)
            if let weight = style?.weight { font = font.weight(Self.weight(weight)) }
            if style?.isItalic == true { font = font.italic() }
            piece.font = font
            line += piece
        }
        return line
    }

    private func color(_ value: ThemeColor?, _ fallback: NSColor) -> Color {
        Color(nsColor: value?.nsColor ?? fallback)
    }

    private static func weight(_ css: Int) -> Font.Weight {
        switch css {
        case ..<250: .thin
        case ..<350: .light
        case ..<450: .regular
        case ..<550: .medium
        case ..<650: .semibold
        case ..<750: .bold
        default: .heavy
        }
    }

    private static var ansiFallback: [NSColor] {
        [.black, .systemRed, .systemGreen, .systemYellow, .systemBlue, .systemPurple, .systemTeal, .white]
    }
}

/// Hand-tokenized Swift with Zed capture names, so the sample needs no parser.
private enum SampleCode {
    struct Token {
        var text: String
        var capture: String?
    }

    static let activeLine = 5
    static let addedLine = 6
    static let modifiedLine = 3

    private static func t(_ text: String, _ capture: String? = nil) -> Token { Token(text: text, capture: capture) }

    static let lines: [[Token]] = [
        [t("// Everyone in orbit says hello", "comment")],
        [t("struct", "keyword"), t(" "), t("Planet", "type"), t(": "), t("Identifiable", "type"), t(" {", "punctuation.bracket")],
        [t("    "), t("let", "keyword"), t(" "), t("name", "property"), t(": "), t("String", "type")],
        [t("    "), t("var", "keyword"), t(" "), t("moons", "property"), t(" "), t("=", "operator"), t(" "), t("0", "number")],
        [],
        [t("    "), t("func", "keyword"), t(" "), t("greet", "function"), t("("), t("_", "variable.special"), t(" "), t("visitor", "variable.parameter"), t(": "), t("String", "type"), t(") "), t("->", "operator"), t(" "), t("String", "type"), t(" {", "punctuation.bracket")],
        [t("        "), t("return", "keyword"), t(" "), t("\"Hello, \\(", "string"), t("visitor", "variable"), t(")! I have \\(", "string"), t("moons", "variable"), t(") moons.\"", "string")],
        [t("    }", "punctuation.bracket")],
        [t("}", "punctuation.bracket")],
    ]
}

/// Over the editor while an extension is tried on: back to Settings, install, or stop.
struct TryOnBar: View {
    let host: PluginHost
    private var catalog: ExtensionCatalog { .shared }

    var body: some View {
        // The theme selector shows themes the same way while it's open.
        if let preview = Extensions.shared.preview, host.ui.quickPick?.id != ThemeSelector.pickID {
            HStack(spacing: 10) {
                Image(systemName: "paintpalette")
                    .foregroundStyle(.secondary)
                Text("Trying On \(preview.colorTheme?.name ?? preview.iconTheme?.name ?? preview.manifest.name)")
                    .lineLimit(1)
                if preview.colorThemes.count > 1 || preview.iconThemes.count > 1 {
                    Menu {
                        PreviewThemePickers(preview: preview)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .help("Other themes in this extension")
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                Button("Catalog") {
                    UserDefaults.standard.set(ExtensionsSettings.Tab.catalog.rawValue, forKey: ExtensionsSettings.tabKey)
                    host.ui.showSettings("extensions")
                }
                .buttonStyle(.glass)
                if let entry = catalog.previewEntry {
                    Button(catalog.installed(entry) == nil ? "Install" : "Update") {
                        Task { await catalog.install(entry) }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(catalog.busy.contains(entry.id))
                }
                Button {
                    catalog.endPreview()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.glass)
                .help("Stop trying it on")
            }
            .controlSize(.small)
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
            .padding(.bottom, 14)
        }
    }
}
