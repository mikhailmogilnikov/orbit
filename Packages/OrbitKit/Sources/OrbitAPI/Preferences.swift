import AppKit
import Observation

/// App-wide preferences more than one plugin reads (the code font is shared by
/// the editor, terminal and diffs). A plugin's own options live in `PluginSettings`.
@MainActor
@Observable
public final class Preferences {
    public static let shared = Preferences()

    public enum Appearance: String, CaseIterable, Sendable {
        case system, light, dark
    }

    public static let defaultCodeFontSize = 12.5
    public static let codeFontSizes: ClosedRange<Double> = 9...24

    public var appearance: Appearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    /// Whether windows are drawn dark right now ("System" follows macOS).
    public var isDark: Bool {
        switch appearance {
        case .light: false
        case .dark: true
        case .system: UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        }
    }

    public var codeFontSize: Double {
        didSet { UserDefaults.standard.set(codeFontSize, forKey: Keys.codeFontSize) }
    }

    /// The code font's family (D180); nil: SF Mono. Used by the editor, diffs and the terminal.
    public var codeFontFamily: String? {
        didSet { UserDefaults.standard.set(codeFontFamily, forKey: Keys.codeFontFamily) }
    }

    /// Fira Code's `=>`, JetBrains Mono's `!=` (D188); SF Mono has none.
    public var codeLigatures: Bool {
        didSet { UserDefaults.standard.set(codeLigatures, forKey: Keys.codeLigatures) }
    }

    /// The editor's line height as a multiple of the font's (D188).
    public static let lineHeights: [Double] = [1, 1.1, 1.2, 1.3, 1.4, 1.5]
    public var codeLineHeight: Double {
        didSet { UserDefaults.standard.set(codeLineHeight, forKey: Keys.codeLineHeight) }
    }

    /// The code font at a size and weight, in the picked family when it has that weight.
    public nonisolated static func codeFont(family: String?, size: Double, weight: NSFont.Weight = .regular, ligatures: Bool = true) -> NSFont {
        let system = NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        guard let family, let base = NSFont(name: family, size: size) ?? NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) else {
            return system
        }
        var descriptor = base.fontDescriptor
        if weight != .regular { descriptor = descriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight]]) }
        if !ligatures { descriptor = descriptor.addingAttributes([.featureSettings: noLigatures]) }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// Programming fonts draw their ligatures as contextual alternates.
    nonisolated static let noLigatures: [[NSFontDescriptor.FeatureKey: Int]] = [
        [.typeIdentifier: kLigaturesType, .selectorIdentifier: kCommonLigaturesOffSelector],
        [.typeIdentifier: kContextualAlternatesType, .selectorIdentifier: kContextualAlternatesOffSelector],
    ]

    public func codeFont(size: Double? = nil, weight: NSFont.Weight = .regular) -> NSFont {
        Self.codeFont(family: codeFontFamily, size: size ?? codeFontSize, weight: weight, ligatures: codeLigatures)
    }

    /// Installed fixed-pitch families, for the font picker.
    public static var monospacedFamilies: [String] {
        NSFontManager.shared.availableFontFamilies.filter { family in
            guard !family.hasPrefix("."), let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 12) else { return false }
            return font.isFixedPitch || NSFontManager.shared.traits(of: font).contains(.fixedPitchFontMask)
        }
    }

    /// Indentation for a file nothing decides: no `.editorconfig`, no indented lines yet (D180).
    public var defaultIndentation: Indentation {
        didSet {
            UserDefaults.standard.set(defaultIndentation.size, forKey: Keys.indentSize)
            UserDefaults.standard.set(defaultIndentation.spaces, forKey: Keys.indentSpaces)
        }
    }

    /// The size of interface text, as the size of a list row (D181); the type
    /// scale grows or shrinks around it.
    public static let defaultInterfaceTextSize = 12.0
    public static let interfaceTextSizes: ClosedRange<Double> = 10...15

    public var interfaceTextSize: Double {
        didSet { UserDefaults.standard.set(interfaceTextSize, forKey: Keys.interfaceTextSize) }
    }

    /// The agent chat's own size; nil follows the interface.
    public var chatTextSize: Double? {
        didSet { UserDefaults.standard.set(chatTextSize ?? 0, forKey: Keys.chatTextSize) }
    }

    public var effectiveChatTextSize: Double { chatTextSize ?? interfaceTextSize }

    /// The terminal's own size; nil follows the code font.
    public var terminalFontSize: Double? {
        didSet { UserDefaults.standard.set(terminalFontSize ?? 0, forKey: Keys.terminalFontSize) }
    }

    public var effectiveTerminalFontSize: Double { terminalFontSize ?? codeFontSize }

    /// Dot files in the file tree (D178).
    public var showsHiddenFiles: Bool {
        didSet { UserDefaults.standard.set(showsHiddenFiles, forKey: Keys.showsHiddenFiles) }
    }

    /// Git-ignored files in the file tree, dimmed; search skips them either way.
    public var showsIgnoredFiles: Bool {
        didSet { UserDefaults.standard.set(showsIgnoredFiles, forKey: Keys.showsIgnoredFiles) }
    }

    /// Moving or renaming a file in Orbit fixes the imports of it (D255).
    public var updatesImportsOnMove: Bool {
        didSet { UserDefaults.standard.set(updatesImportsOnMove, forKey: Keys.updatesImportsOnMove) }
    }

    /// Globs hidden from the file tree, Open Quickly and Find in Project (D178).
    public var excludedFiles: [String] {
        didSet {
            UserDefaults.standard.set(excludedFiles, forKey: Keys.excludedFiles)
            fileExclusions = PathFilter(exclude: excludedFiles.joined(separator: ","))
        }
    }

    /// `excludedFiles` compiled; `allows` takes a project-relative path.
    public private(set) var fileExclusions = PathFilter()

    /// What Orbit keeps up to date by itself, in the background (D186).
    public var autoUpdatesAgents: Bool {
        didSet { UserDefaults.standard.set(autoUpdatesAgents, forKey: Keys.autoUpdatesAgents) }
    }

    public var autoUpdatesLanguageServers: Bool {
        didSet { UserDefaults.standard.set(autoUpdatesLanguageServers, forKey: Keys.autoUpdatesLanguageServers) }
    }

    public var autoUpdatesExtensions: Bool {
        didSet { UserDefaults.standard.set(autoUpdatesExtensions, forKey: Keys.autoUpdatesExtensions) }
    }

    /// True at most once a day per `name`, across windows and launches:
    /// the first window to ask does the day's check.
    public func claimDailyCheck(_ name: String) -> Bool {
        let key = "orbit.lastAutoUpdate.\(name)"
        let last = UserDefaults.standard.double(forKey: key)
        let now = Date().timeIntervalSince1970
        guard now - last > 20 * 3600 else { return false }
        UserDefaults.standard.set(now, forKey: key)
        return true
    }

    /// Picked color themes by `ColorTheme.id`; nil uses Orbit's default.
    public var lightThemeID: String? {
        didSet { store(lightThemeID, Keys.lightTheme) }
    }

    public var darkThemeID: String? {
        didSet { store(darkThemeID, Keys.darkTheme) }
    }

    /// Picked `IconTheme.id`s, per mode like color themes; nil uses the built-in SF Symbols.
    public var lightIconThemeID: String? {
        didSet { store(lightIconThemeID, Keys.lightIconTheme) }
    }

    public var darkIconThemeID: String? {
        didSet { store(darkIconThemeID, Keys.darkIconTheme) }
    }

    private func store(_ value: String?, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
        NotificationCenter.default.post(name: Extensions.themeDidChange, object: nil)
    }

    private enum Keys {
        static let appearance = "orbit.appearance"
        static let codeFontSize = "orbit.codeFontSize"
        static let terminalFontSize = "orbit.terminalFontSize"
        static let codeFontFamily = "orbit.codeFontFamily"
        static let codeLigatures = "orbit.codeLigatures"
        static let codeLineHeight = "orbit.codeLineHeight"
        static let autoUpdatesAgents = "orbit.autoUpdatesAgents"
        static let autoUpdatesLanguageServers = "orbit.autoUpdatesLanguageServers"
        static let autoUpdatesExtensions = "orbit.autoUpdatesExtensions"
        static let interfaceTextSize = "orbit.interfaceTextSize"
        static let chatTextSize = "orbit.chatTextSize"
        static let indentSize = "orbit.indentSize"
        static let indentSpaces = "orbit.indentSpaces"
        static let showsHiddenFiles = "orbit.showsHiddenFiles"
        static let showsIgnoredFiles = "orbit.showsIgnoredFiles"
        static let updatesImportsOnMove = "orbit.updatesImportsOnMove"
        static let excludedFiles = "orbit.excludedFiles"
        static let lightTheme = "orbit.lightTheme"
        static let darkTheme = "orbit.darkTheme"
        static let lightIconTheme = "orbit.lightIconTheme"
        static let darkIconTheme = "orbit.darkIconTheme"
        /// Before icons were picked per mode.
        static let legacyIconTheme = "orbit.iconTheme"
    }

    private init() {
        let defaults = UserDefaults.standard
        appearance = defaults.string(forKey: Keys.appearance).flatMap(Appearance.init) ?? .system
        let size = defaults.double(forKey: Keys.codeFontSize)
        codeFontSize = Self.codeFontSizes.contains(size) ? size : Self.defaultCodeFontSize
        codeFontFamily = defaults.string(forKey: Keys.codeFontFamily)
        codeLigatures = defaults.object(forKey: Keys.codeLigatures) as? Bool ?? true
        let lineHeight = defaults.double(forKey: Keys.codeLineHeight)
        codeLineHeight = Self.lineHeights.contains(lineHeight) ? lineHeight : 1
        autoUpdatesAgents = defaults.object(forKey: Keys.autoUpdatesAgents) as? Bool ?? true
        autoUpdatesLanguageServers = defaults.object(forKey: Keys.autoUpdatesLanguageServers) as? Bool ?? true
        autoUpdatesExtensions = defaults.object(forKey: Keys.autoUpdatesExtensions) as? Bool ?? true
        let interface = defaults.double(forKey: Keys.interfaceTextSize)
        interfaceTextSize = Self.interfaceTextSizes.contains(interface) ? interface : Self.defaultInterfaceTextSize
        let chat = defaults.double(forKey: Keys.chatTextSize)
        chatTextSize = Self.interfaceTextSizes.contains(chat) ? chat : nil
        let indentSize = defaults.integer(forKey: Keys.indentSize)
        defaultIndentation = Indentation(
            size: (1...8).contains(indentSize) ? indentSize : 4,
            spaces: defaults.object(forKey: Keys.indentSpaces) as? Bool ?? true
        )
        let terminal = defaults.double(forKey: Keys.terminalFontSize)
        terminalFontSize = Self.codeFontSizes.contains(terminal) ? terminal : nil
        lightThemeID = defaults.string(forKey: Keys.lightTheme)
        darkThemeID = defaults.string(forKey: Keys.darkTheme)
        let legacyIcons = defaults.string(forKey: Keys.legacyIconTheme)
        lightIconThemeID = defaults.string(forKey: Keys.lightIconTheme) ?? legacyIcons
        darkIconThemeID = defaults.string(forKey: Keys.darkIconTheme) ?? legacyIcons
        showsHiddenFiles = defaults.object(forKey: Keys.showsHiddenFiles) as? Bool ?? true
        showsIgnoredFiles = defaults.object(forKey: Keys.showsIgnoredFiles) as? Bool ?? true
        updatesImportsOnMove = defaults.object(forKey: Keys.updatesImportsOnMove) as? Bool ?? true
        excludedFiles = defaults.stringArray(forKey: Keys.excludedFiles) ?? []
        fileExclusions = PathFilter(exclude: excludedFiles.joined(separator: ","))
    }
}
