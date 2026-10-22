import Foundation

/// A color from a theme file, in sRGB.
public struct ThemeColor: Sendable, Hashable {
    public var red, green, blue, alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        (self.red, self.green, self.blue, self.alpha) = (red, green, blue, alpha)
    }

    /// `#rgb`, `#rgba`, `#rrggbb` or `#rrggbbaa`.
    public init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        if digits.count == 3 || digits.count == 4 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
        let hasAlpha = digits.count == 8
        func channel(_ shift: Int) -> Double { Double((value >> UInt64(shift)) & 0xFF) / 255 }
        self.init(
            red: channel(hasAlpha ? 24 : 16), green: channel(hasAlpha ? 16 : 8),
            blue: channel(hasAlpha ? 8 : 0), alpha: hasAlpha ? channel(0) : 1
        )
    }

    public func opacity(_ factor: Double) -> ThemeColor {
        ThemeColor(red: red, green: green, blue: blue, alpha: alpha * factor)
    }

    /// This color painted over an opaque `base`: the opaque color it shows as.
    public func composited(over base: ThemeColor) -> ThemeColor {
        func mix(_ top: Double, _ bottom: Double) -> Double { top * alpha + bottom * (1 - alpha) }
        return ThemeColor(red: mix(red, base.red), green: mix(green, base.green), blue: mix(blue, base.blue))
    }
}

public struct SyntaxStyle: Sendable, Hashable {
    public var color: ThemeColor?
    /// CSS-style weight (400 regular, 700 bold); nil keeps the editor's.
    public var weight: Int?
    public var isItalic = false

    public init(color: ThemeColor? = nil, weight: Int? = nil, isItalic: Bool = false) {
        self.color = color
        self.weight = weight
        self.isItalic = isItalic
    }
}

/// A color theme in Zed's theme format (D38). Only what Orbit draws itself is
/// read: the editor, gutter, terminal, version-control colors and syntax; the
/// window chrome stays native. A missing color means "use the system's".
public struct ColorTheme: Sendable, Identifiable, Hashable {
    /// `<extension id>/<theme name>`.
    public let id: String
    public var name: String
    public var isDark: Bool
    public var extensionName: String

    public var editorBackground: ThemeColor?
    public var editorForeground: ThemeColor?
    public var activeLineBackground: ThemeColor?
    public var indentGuide: ThemeColor?
    public var lineNumber: ThemeColor?
    public var activeLineNumber: ThemeColor?
    public var cursor: ThemeColor?
    public var selection: ThemeColor?
    /// Zed's `text.accent`: the app's tint instead of the system blue (D97).
    public var accent: ThemeColor?
    /// Other uses of the symbol under the caret: reads, and writes (assignments).
    public var symbolHighlight: ThemeColor?
    public var symbolHighlightWrite: ThemeColor?
    /// Find in file's matches (the current one is drawn stronger).
    public var searchMatch: ThemeColor?

    public var added: ThemeColor?
    public var modified: ThemeColor?
    public var deleted: ThemeColor?
    public var renamed: ThemeColor?
    public var conflict: ThemeColor?

    /// Diagnostics: squiggles and problem counts.
    public var error: ThemeColor?
    public var warning: ThemeColor?
    public var info: ThemeColor?
    /// Inlay hints: their text and the capsule behind it.
    public var hint: ThemeColor?
    public var hintBackground: ThemeColor?

    public var terminalBackground: ThemeColor?
    public var terminalForeground: ThemeColor?
    /// The 16 ANSI colors: black…white, then the bright ones.
    public var terminalANSI: [ThemeColor?] = Array(repeating: nil, count: 16)

    public var syntax: [String: SyntaxStyle] = [:]

    public init(id: String, name: String, isDark: Bool, extensionName: String) {
        self.id = id
        self.name = name
        self.isDark = isDark
        self.extensionName = extensionName
    }

    /// The extension it comes from (the part of `id` before the first slash).
    public var extensionID: String { String(id.prefix { $0 != "/" }) }

    /// The system look, used when no theme file loads.
    public static func system(dark: Bool) -> ColorTheme {
        ColorTheme(id: dark ? "system/dark" : "system/light", name: dark ? "System Dark" : "System Light", isDark: dark, extensionName: "Orbit")
    }

    /// The style for a tree-sitter capture such as `keyword.return`: the exact
    /// name, then its Zed equivalent, then less specific names.
    public func style(forCapture capture: String) -> SyntaxStyle? {
        var name = Substring(capture)
        var aliasHops = 0
        while !name.isEmpty {
            if let style = syntax[String(name)] { return style }
            if aliasHops < 4, let alias = Self.captureAliases[String(name)] {
                name = Substring(alias)
                aliasHops += 1
                continue
            }
            guard let dot = name.lastIndex(of: ".") else { return nil }
            name = name[..<dot]
        }
        return nil
    }

    /// nvim-style captures some Zed extensions' queries still emit, mapped to the names Zed themes use.
    static let captureAliases: [String: String] = [
        "include": "keyword", "conditional": "keyword", "repeat": "keyword",
        "exception": "keyword", "storageclass": "keyword", "import": "keyword",
        "method": "function.method", "function.call": "function",
        "function.macro": "function", "function.builtin": "function",
        "parameter": "variable.parameter", "variable.builtin": "variable.special",
        "field": "property", "float": "number", "character": "string",
        "escape": "string.escape", "symbol": "constant", "namespace": "type",
        "module": "type", "text.title": "title", "text.literal": "string",
        "text.uri": "link_uri", "text.reference": "link_text",
        "text.emphasis": "emphasis", "text.strong": "emphasis.strong",
    ]
}

/// File and folder icons in Zed's icon-theme format; paths are resolved against the extension.
public struct IconTheme: Sendable, Identifiable, Hashable {
    public let id: String
    public var name: String
    public var extensionName: String
    /// What the icons are drawn for; only orders the pickers.
    public var isDark = true

    public var folder: URL?
    public var folderExpanded: URL?
    public var namedFolders: [String: (collapsed: URL?, expanded: URL?)] = [:]
    /// Whole file names (`Makefile`) or stems (`Dockerfile` for `Dockerfile.dev`) → icon key.
    public var fileStems: [String: String] = [:]
    /// `ts`, `d.ts`, `json` → icon key.
    public var fileSuffixes: [String: String] = [:]
    public var fileIcons: [String: URL] = [:]

    public init(id: String, name: String, extensionName: String) {
        self.id = id
        self.name = name
        self.extensionName = extensionName
    }

    public func icon(forFileNamed fileName: String) -> URL? {
        let lower = fileName.lowercased()
        if let key = fileStems[fileName] ?? fileStems[lower], let url = fileIcons[key] { return url }
        // Longest suffix first: `index.d.ts` tries `d.ts`, then `ts`.
        var rest = Substring(lower)
        while let dot = rest.firstIndex(of: ".") {
            rest = rest[rest.index(after: dot)...]
            if let key = fileSuffixes[String(rest)], let url = fileIcons[key] { return url }
        }
        if let dot = fileName.firstIndex(of: "."), dot != fileName.startIndex,
           let key = fileStems[String(fileName[..<dot])], let url = fileIcons[key] { return url }
        return fileIcons["default"]
    }

    public func icon(forFolderNamed name: String, expanded: Bool) -> URL? {
        if let named = namedFolders[name] ?? namedFolders[name.lowercased()],
           let url = expanded ? (named.expanded ?? named.collapsed) : named.collapsed {
            return url
        }
        return expanded ? (folderExpanded ?? folder) : folder
    }

    public static func == (lhs: IconTheme, rhs: IconTheme) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Parsing

enum ThemeFile {
    /// Every theme in a Zed theme-family file.
    static func colorThemes(from data: Data, extensionID: String, extensionName: String) throws -> [ColorTheme] {
        guard let family = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let themes = family["themes"] as? [[String: Any]]
        else { throw ExtensionError.invalid("expected an object with a \"themes\" array") }
        return themes.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            var theme = ColorTheme(
                id: "\(extensionID)/\(name)", name: name,
                isDark: (entry["appearance"] as? String)?.lowercased() != "light",
                extensionName: extensionName
            )
            let style = entry["style"] as? [String: Any] ?? [:]
            func color(_ keys: String...) -> ThemeColor? {
                for key in keys {
                    if let hex = style[key] as? String, let color = ThemeColor(hex: hex) { return color }
                }
                return nil
            }
            // "Blurred" Zed themes leave backgrounds translucent for Zed to blur the
            // desktop through; Orbit lays this color under the whole window (D41),
            // where translucency showed the desktop unblurred. Flatten it onto the
            // theme's own background, as it would look over a dark or light desktop.
            let backdrop = theme.isDark ? ThemeColor(red: 0, green: 0, blue: 0) : ThemeColor(red: 1, green: 1, blue: 1)
            let surface = color("background")?.composited(over: backdrop) ?? backdrop
            theme.editorBackground = color("editor.background")?.composited(over: surface)
            theme.editorForeground = color("editor.foreground", "text")
            theme.activeLineBackground = color("editor.active_line.background")
            theme.indentGuide = color("editor.indent_guide")
            theme.lineNumber = color("editor.line_number")
            theme.activeLineNumber = color("editor.active_line_number")
            let player = (style["players"] as? [[String: Any]])?.first
            theme.cursor = (player?["cursor"] as? String).flatMap(ThemeColor.init(hex:))
            theme.selection = (player?["selection"] as? String).flatMap(ThemeColor.init(hex:))
            theme.accent = color("text.accent", "icon.accent", "border.focused")
            theme.symbolHighlight = color("editor.document_highlight.read_background")
            theme.symbolHighlightWrite = color("editor.document_highlight.write_background")
            theme.searchMatch = color("search.match_background")

            theme.added = color("version_control.added", "created")
            theme.modified = color("version_control.modified", "modified")
            theme.deleted = color("version_control.deleted", "deleted")
            theme.renamed = color("version_control.renamed", "renamed")
            theme.conflict = color("version_control.conflict", "conflict")
            theme.error = color("error")
            theme.warning = color("warning")
            theme.info = color("info", "hint")
            theme.hintBackground = color("hint.background")

            theme.terminalBackground = color("terminal.background")?.composited(over: theme.editorBackground ?? surface)
            theme.terminalForeground = color("terminal.foreground")
            let ansi = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
            theme.terminalANSI = ansi.map { color("terminal.ansi.\($0)") } + ansi.map { color("terminal.ansi.bright_\($0)") }

            for (capture, value) in style["syntax"] as? [String: [String: Any]] ?? [:] {
                var syntax = SyntaxStyle()
                syntax.color = (value["color"] as? String).flatMap(ThemeColor.init(hex:))
                syntax.weight = (value["font_weight"] as? NSNumber)?.intValue
                syntax.isItalic = ["italic", "oblique"].contains((value["font_style"] as? String)?.lowercased())
                theme.syntax[capture] = syntax
            }
            // Zed draws inlay hints in the syntax "hint" style, else the status color.
            theme.hint = theme.syntax["hint"]?.color ?? color("hint")
            return theme
        }
    }

    static func iconThemes(from data: Data, root: URL, extensionID: String, extensionName: String) throws -> [IconTheme] {
        guard let family = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let themes = family["themes"] as? [[String: Any]]
        else { throw ExtensionError.invalid("expected an object with a \"themes\" array") }
        func file(_ path: Any?) -> URL? {
            guard let path = path as? String, !path.isEmpty else { return nil }
            return root.appending(path: path).standardizedFileURL
        }
        return themes.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            var theme = IconTheme(id: "\(extensionID)/\(name)", name: name, extensionName: extensionName)
            theme.isDark = (entry["appearance"] as? String)?.lowercased() != "light"
            let folders = entry["directory_icons"] as? [String: Any]
            theme.folder = file(folders?["collapsed"])
            theme.folderExpanded = file(folders?["expanded"])
            for (folder, icons) in entry["named_directory_icons"] as? [String: [String: Any]] ?? [:] {
                theme.namedFolders[folder] = (file(icons["collapsed"]), file(icons["expanded"]))
            }
            theme.fileStems = entry["file_stems"] as? [String: String] ?? [:]
            theme.fileSuffixes = Dictionary(
                (entry["file_suffixes"] as? [String: String] ?? [:]).map { ($0.key.lowercased(), $0.value) },
                uniquingKeysWith: { first, _ in first }
            )
            for (key, icon) in entry["file_icons"] as? [String: [String: Any]] ?? [:] {
                if let url = file(icon["path"]) { theme.fileIcons[key] = url }
            }
            return theme
        }
    }
}
