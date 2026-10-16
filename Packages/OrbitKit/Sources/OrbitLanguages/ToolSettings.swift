import Foundation
import OrbitACP

/// `"companions"` and `"codeActionsOnSave"` in `.orbit/settings.json` (the
/// project's, then `~/.orbit/settings.json`; the first that says something
/// about an entry wins), D81:
///
///     "companions": {
///       "eslint": "off",                                  not started ("on": even without eslint in package.json)
///       "tailwindcss": { "settings": { "tailwindCSS": { "lint": { "cssConflict": "ignore" } } } }
///     },
///     "codeActionsOnSave": {
///       "ts, tsx": ["source.organizeImports", "source.fixAll.eslint"],
///       "js": []                                          nothing on save
///     }
struct ToolSettings: Sendable {
    enum Companion: Sendable, Equatable {
        case off
        /// Started even when no package.json names the tool.
        case on(LanguageServerSettings.Overrides)
        /// Started as usual (when the project uses it), with these settings merged over its own.
        case configured(LanguageServerSettings.Overrides)
    }

    var companions: [String: Companion]
    /// Code action kinds run on save, by file type.
    var actionsOnSave: [String: [String]]
    var displayPath: String

    /// Without a rule: the project's ESLint fixes, which do nothing where ESLint doesn't run.
    /// Import order is the linter's call (its rules), so organizing imports is opt-in.
    static let defaultActionsOnSave = ["source.fixAll.eslint"]

    /// Other spellings of a companion's id.
    private static let aliases = ["tailwind": "tailwindcss", "vue": "vue-language-server"]

    static func layers(root: URL?, home: URL = FormatterSettings.home) throws -> [ToolSettings] {
        var files: [(URL, String)] = []
        if let root { files.append((FormatterSettings.projectFile(root: root), ".orbit/settings.json")) }
        files.append((FormatterSettings.userFile(home: home), "~/.orbit/settings.json"))
        return try files.compactMap { url, display in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try parse(data, displayPath: display)
        }
    }

    static func parse(_ data: Data, displayPath: String) throws -> ToolSettings {
        guard let object = try? JSONDecoder().decode(JSONValue.self, from: data), case .object(let root) = object else {
            throw FormatterSettings.Failure.invalid("\(displayPath) isn't valid JSON.")
        }
        var companions: [String: Companion] = [:]
        if let section = root["companions"] {
            guard case .object(let table) = section else {
                throw FormatterSettings.Failure.invalid("\(displayPath): “companions” should be an object keyed by tool (eslint, tailwindcss).")
            }
            for (name, value) in table {
                let id = aliases[name.lowercased()] ?? name.lowercased()
                let state = value.string?.lowercased() ?? value.bool.map { $0 ? "on" : "off" }
                switch value {
                case _ where state == "off" || state == "none":
                    companions[id] = .off
                case _ where state == "on":
                    companions[id] = .on(.init())
                case .object(let fields):
                    let overrides = LanguageServerSettings.Overrides(settings: fields["settings"], initializationOptions: fields["initializationOptions"])
                    switch fields["enabled"] {
                    case .bool(false)?: companions[id] = .off
                    case .bool(true)?: companions[id] = .on(overrides)
                    default: companions[id] = .configured(overrides)
                    }
                default:
                    throw FormatterSettings.Failure.invalid("\(displayPath): “\(name)” should be \"off\", \"on\" or { \"settings\": … }.")
                }
            }
        }
        var actions: [String: [String]] = [:]
        if let section = root["codeActionsOnSave"] {
            guard case .object(let table) = section else {
                throw FormatterSettings.Failure.invalid("\(displayPath): “codeActionsOnSave” should be an object keyed by file type.")
            }
            for (types, value) in table {
                let kinds: [String]
                switch value {
                case .array(let items): kinds = items.compactMap(\.string)
                case .string(let state) where ["off", "none"].contains(state.lowercased()): kinds = []
                case .string(let kind): kinds = [kind]
                default:
                    throw FormatterSettings.Failure.invalid("\(displayPath): “\(types)” should be a list of code action kinds, e.g. [\"source.fixAll.eslint\"].")
                }
                for type in types.split(separator: ",") {
                    let type = type.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
                    if !type.isEmpty { actions[type] = kinds }
                }
            }
        }
        return ToolSettings(companions: companions, actionsOnSave: actions, displayPath: displayPath)
    }

    static func companion(_ id: String, in layers: [ToolSettings]) -> Companion? {
        layers.lazy.compactMap { $0.companions[id] }.first
    }

    static func actionsOnSave(for file: URL, in layers: [ToolSettings]) -> [String] {
        let type = file.pathExtension.lowercased()
        return layers.lazy.compactMap { $0.actionsOnSave[type] }.first ?? defaultActionsOnSave
    }
}
