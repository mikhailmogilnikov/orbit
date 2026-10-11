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

    private enum Keys {
        static let appearance = "orbit.appearance"
        static let codeFontSize = "orbit.codeFontSize"
    }

    private init() {
        let defaults = UserDefaults.standard
        appearance = defaults.string(forKey: Keys.appearance).flatMap(Appearance.init) ?? .system
        let size = defaults.double(forKey: Keys.codeFontSize)
        codeFontSize = Self.codeFontSizes.contains(size) ? size : Self.defaultCodeFontSize
    }
}
