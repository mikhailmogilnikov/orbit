import Foundation
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

    public var codeFontSize: Double {
        didSet { UserDefaults.standard.set(codeFontSize, forKey: Keys.codeFontSize) }
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
        lightThemeID = defaults.string(forKey: Keys.lightTheme)
        darkThemeID = defaults.string(forKey: Keys.darkTheme)
        let legacyIcons = defaults.string(forKey: Keys.legacyIconTheme)
        lightIconThemeID = defaults.string(forKey: Keys.lightIconTheme) ?? legacyIcons
        darkIconThemeID = defaults.string(forKey: Keys.darkIconTheme) ?? legacyIcons
    }
}
