import OrbitKit
import SwiftUI

/// Settings → Extensions: what's installed, and Zed's catalog of themes and
/// icon themes to try on and install (D48).
struct ExtensionsSettings: View {
    enum Tab: String { case installed, catalog }

    static let tabKey = "orbit.extensionsTab"
    @AppStorage(ExtensionsSettings.tabKey) private var tab = Tab.installed

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Installed").tag(Tab.installed)
                Text("Catalog").tag(Tab.catalog)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.bottom, 4)
            switch tab {
            case .installed: InstalledExtensionsView()
            case .catalog: ExtensionCatalogView()
            }
        }
    }
}

// MARK: - Installed

struct InstalledExtensionsView: View {
    private var extensions: Extensions { .shared }
    private var catalog: ExtensionCatalog { .shared }

    var body: some View {
        Form {
            Section {
                ForEach(extensions.installed) { item in
                    LabeledContent {
                        HStack(spacing: 8) {
                            Text(item.isBuiltin ? "Built-in" : item.manifest.version)
                                .foregroundStyle(.secondary)
                            if !item.isBuiltin {
                                Menu {
                                    menuItems(for: item)
                                } label: {
                                    Image(systemName: "ellipsis")
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .fixedSize()
                            }
                        }
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.manifest.name)
                                Text(Self.summary(of: item))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let failure = catalog.failures[item.id] {
                                    Text(failure)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                            }
                        } icon: {
                            Image(systemName: item.iconThemeCount > 0 && item.themeCount == 0 ? "doc.richtext" : "paintpalette")
                        }
                    }
                    .contextMenu {
                        if !item.isBuiltin { menuItems(for: item) }
                    }
                }
            } footer: {
                HStack {
                    Text("Find more in the Catalog, or drop an extension folder into ~/.orbit/extensions — it loads right away.")
                    Spacer()
                    Button("Open Folder") { NSWorkspace.shared.open(Extensions.userDirectory) }
                }
            }
            if !extensions.problems.isEmpty {
                Section("Problems") {
                    ForEach(extensions.problems) { problem in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(problem.location.lastPathComponent)
                                Text(problem.message)
                                    .font(.caption)
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
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func menuItems(for item: InstalledExtension) -> some View {
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.directory]) }
        Divider()
        Button("Uninstall", role: .destructive) { catalog.uninstall(item) }
    }

    private static func summary(of item: InstalledExtension) -> String {
        var parts: [String] = []
        if let description = item.manifest.description, !description.isEmpty { parts.append(description) }
        if item.themeCount > 0 { parts.append(item.themeCount == 1 ? "1 theme" : "\(item.themeCount) themes") }
        if item.iconThemeCount > 0 { parts.append(item.iconThemeCount == 1 ? "1 icon theme" : "\(item.iconThemeCount) icon themes") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Catalog

struct ExtensionCatalogView: View {
    @AppStorage("orbit.catalogKind") private var kind = ExtensionCatalog.Kind.themes
    @State private var query = ""
    /// A grouped Form isn't lazy and Zed lists hundreds of themes: draw the
    /// most downloaded first, the rest on request (search reaches them all).
    @State private var limit = Self.pageSize
    private static let pageSize = 40
    private var catalog: ExtensionCatalog { .shared }

    var body: some View {
        Form {
            if Extensions.shared.preview != nil {
                TryOnSection()
            }
            Section {
                HStack(spacing: 10) {
                    TextField("Search", text: $query, prompt: Text("Search Zed extensions"))
                        .labelsHidden()
                    Picker("", selection: $kind) {
                        Text("Themes").tag(ExtensionCatalog.Kind.themes)
                        Text("Icons").tag(ExtensionCatalog.Kind.iconThemes)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            Section {
                if catalog.entries.isEmpty {
                    HStack {
                        Spacer()
                        if catalog.isLoading {
                            ProgressView().controlSize(.small)
                        } else if let error = catalog.loadError {
                            VStack(spacing: 6) {
                                Text("Couldn't load the catalog").font(.headline)
                                Text(error).font(.caption).foregroundStyle(.secondary)
                                Button("Try Again") { catalog.search(query, kind: kind) }
                            }
                        } else {
                            Text("Nothing found").foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 12)
                } else {
                    ForEach(catalog.entries.prefix(limit)) { entry in
                        CatalogRow(entry: entry)
                    }
                    if catalog.entries.count > limit {
                        HStack {
                            Spacer()
                            Button("Show More (\(catalog.entries.count - limit))") { limit += Self.pageSize }
                                .buttonStyle(.glass)
                            Spacer()
                        }
                    }
                }
            } footer: {
                Text("From Zed's extension catalog. Orbit installs only the themes and icons from an extension.")
            }
        }
        .formStyle(.grouped)
        // Debounced: typing restarts the task.
        .task(id: "\(kind.rawValue)|\(query)") {
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            limit = Self.pageSize
            catalog.search(query, kind: kind)
        }
    }
}

struct CatalogRow: View {
    let entry: CatalogEntry
    private var catalog: ExtensionCatalog { .shared }

    var body: some View {
        let installed = catalog.installed(entry)
        let isTrying = Extensions.shared.preview?.manifest.id == entry.id
        HStack(alignment: .center, spacing: 12) {
            if entry.provides.contains("themes") {
                ThemeThumbnail(themes: catalog.samples[entry.id])
                    .task { catalog.requestSample(entry) }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(entry.name).fontWeight(.medium)
                    Text(entry.version).font(.caption).foregroundStyle(.tertiary)
                }
                if let description = entry.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(byline)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if let failure = catalog.failures[entry.id] {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer(minLength: 8)
            if catalog.busy.contains(entry.id) {
                ProgressView().controlSize(.small)
            } else {
                HStack(spacing: 6) {
                    if isTrying {
                        Button("Stop") { catalog.endPreview() }
                            .buttonStyle(.glass)
                    } else if installed == nil || catalog.hasUpdate(entry) {
                        Button("Try On") { Task { await catalog.tryOn(entry) } }
                            .buttonStyle(.glass)
                    }
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
        .padding(.vertical, 2)
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

/// The extension being tried on: which of its themes, a sample, Install / Stop.
struct TryOnSection: View {
    private var extensions: Extensions { .shared }
    private var catalog: ExtensionCatalog { .shared }

    var body: some View {
        if let preview = extensions.preview {
            Section {
                ThemeSampleView(theme: preview.colorTheme ?? extensions.pickedColorTheme(dark: Preferences.shared.isDark))
                PreviewThemePickers(preview: preview)
                HStack {
                    Spacer()
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
            } header: {
                Text("Trying On \(preview.manifest.name)")
            } footer: {
                Text("The whole window uses it until you install it or stop. Go back to the project to see it on your own code.")
            }
        }
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
                            .font(.system(size: 11))
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
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(isActive ? color(theme.activeLineNumber ?? theme.editorForeground, .textColor) : color(theme.lineNumber, .tertiaryLabelColor))
                .frame(width: 26, alignment: .trailing)
                .padding(.trailing, 12)
            Text(attributed(tokens))
                .font(.system(size: 11.5, design: .monospaced))
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
            var font = Font.system(size: 11.5, design: .monospaced)
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
