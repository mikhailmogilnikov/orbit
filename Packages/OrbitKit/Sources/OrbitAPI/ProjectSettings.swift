import Foundation
import Observation

/// Options from `.orbit/settings.json` (the project's, then `~/.orbit/settings.json`)
/// that win over Settings: `"editor": { "wordWrap": true }` or `"editor.wordWrap": true`.
/// Sections plugins parse themselves (formatters, mcpServers…) live in the same
/// files; this reads the simple values, one level deep.
@MainActor
@Observable
public final class ProjectSettings {
    public enum Value: Equatable, Sendable {
        case bool(Bool), number(Double), string(String)
    }

    public static let projectPath = ".orbit/settings.json"
    public static let userPath = "~/.orbit/settings.json"

    private var project: [String: Value] = [:]
    private var user: [String: Value] = [:]
    /// Files that couldn't be read, for Settings to show.
    public private(set) var problems: [String] = []
    @ObservationIgnored private var root: URL?

    init() {}

    public static func projectFile(root: URL) -> URL { root.appendingPathComponent(projectPath) }

    /// A new project file: empty sections, so nothing is decided until written in.
    public static let template = """
    {
      "editor": {},
      "agents": {}
    }

    """
    public static var userFile: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".orbit/settings.json") }

    public func value(_ key: String) -> Value? { project[key] ?? user[key] }

    public func bool(_ key: String) -> Bool? {
        if case .bool(let value) = value(key) { value } else { nil }
    }

    public func string(_ key: String) -> String? {
        if case .string(let value) = value(key) { value } else { nil }
    }

    /// Which file sets `key` (".orbit/settings.json"), for "Set by …" notes.
    public func origin(of key: String) -> String? {
        project[key] != nil ? Self.projectPath : user[key] != nil ? Self.userPath : nil
    }

    func isSettingsFile(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path == Self.userFile.standardizedFileURL.path || root.map { Self.projectFile(root: $0).standardizedFileURL.path == path } == true
    }

    /// Cheap (two small files); views only hear about it when a value changed.
    func reload(root: URL?) {
        self.root = root
        var problems: [String] = []
        let user = Self.read(Self.userFile, display: Self.userPath, problems: &problems)
        let project = root.map { Self.read(Self.projectFile(root: $0), display: Self.projectPath, problems: &problems) } ?? [:]
        if user != self.user { self.user = user }
        if project != self.project { self.project = project }
        if problems != self.problems { self.problems = problems }
    }

    private static func read(_ url: URL, display: String, problems: inout [String]) -> [String: Value] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        guard let object = parse(data) else {
            problems.append("\(display) isn't valid JSON.")
            return [:]
        }
        return object
    }

    /// Top-level values and those one object down, as "section.key".
    nonisolated static func parse(_ data: Data) -> [String: Value]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var values: [String: Value] = [:]
        for (key, entry) in root {
            if let section = entry as? [String: Any] {
                for (name, inner) in section { values["\(key).\(name)"] = value(inner) }
            } else {
                values[key] = value(entry)
            }
        }
        return values
    }

    private nonisolated static func value(_ any: Any) -> Value? {
        switch any {
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): .bool(number.boolValue)
        case let number as NSNumber: .number(number.doubleValue)
        case let string as String: .string(string)
        default: nil
        }
    }
}
