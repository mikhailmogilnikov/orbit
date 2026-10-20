import Foundation
import Observation

/// A snippet of code typed by its prefix (D195), in VS Code's and Zed's format:
///
///     "For Loop": { "prefix": "for", "body": ["for ${1:item} in ${2:items} {", "\t$0", "}"],
///                   "description": "A for-in loop", "scope": "swift" }
///
/// A file named after a language (`rust.json`) holds that language's;
/// `snippets.json` or a `.code-snippets` file every language's, unless `scope` says.
public struct CodeSnippet: Sendable, Hashable, Identifiable {
    public var id: String { "\(source)|\(name)" }
    public var name: String
    public var prefixes: [String]
    /// LSP snippet syntax: `$1`, `${1:name}`, `${1|a,b|}`, `$0`.
    public var body: String
    public var description: String?
    /// Language names or ids (`rust`, `typescriptreact`); empty for every language.
    public var languages: [String]
    /// Where it comes from, said in lists: an extension's name, "Your snippets", "This project".
    public var source: String

    public init(name: String, prefixes: [String], body: String, description: String? = nil, languages: [String] = [], source: String) {
        self.name = name
        self.prefixes = prefixes
        self.body = body
        self.description = description
        self.languages = languages
        self.source = source
    }

    /// For a file of `language` (its grammar's id) with extension `fileExtension`.
    public func applies(toLanguage language: String?, fileExtension: String) -> Bool {
        guard !languages.isEmpty else { return true }
        return languages.contains { name in
            let key = name.lowercased()
            if key == fileExtension.lowercased() { return true }
            guard let language else { return false }
            let resolved = Self.vsCodeIDs[key] ?? key
            return GrammarCatalog.shared.language(named: resolved)?.id == language
        }
    }

    /// VS Code's language ids that aren't a grammar's name or suffix.
    private static let vsCodeIDs = [
        "javascriptreact": "tsx", "typescriptreact": "tsx", "shellscript": "bash", "csharp": "c#",
        "objective-c": "objc", "objective-cpp": "objcpp", "dockercompose": "yaml", "jsonc": "json",
    ]

    /// The snippets in one file; `language` is the file's (from its name), nil for a global one.
    public static func parse(_ data: Data, language: String?, source: String) throws -> [CodeSnippet] {
        // VS Code's files allow comments and trailing commas.
        let object = try JSONSerialization.jsonObject(with: data, options: [.json5Allowed])
        guard let entries = object as? [String: Any] else { throw ExtensionError.invalid("a snippet file holds an object of snippets") }
        return entries.sorted { $0.key < $1.key }.compactMap { name, value in
            guard let entry = value as? [String: Any] else { return nil }
            let prefixes = (entry["prefix"] as? [String]) ?? (entry["prefix"] as? String).map { [$0] } ?? []
            let body = (entry["body"] as? [String])?.joined(separator: "\n") ?? entry["body"] as? String
            guard !prefixes.isEmpty, let body else { return nil }
            let scope = (entry["scope"] as? String)?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return CodeSnippet(
                name: name, prefixes: prefixes, body: body, description: entry["description"] as? String,
                languages: scope ?? language.map { [$0] } ?? [], source: source
            )
        }
    }

    /// Every snippet file in a folder: `<language>.json`, `snippets.json`, `*.code-snippets`.
    static func load(folder: URL, source: String) -> (snippets: [CodeSnippet], problems: [ExtensionProblem]) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return load(files: files.sorted { $0.lastPathComponent < $1.lastPathComponent }, source: source)
    }

    static func load(files: [URL], source: String) -> (snippets: [CodeSnippet], problems: [ExtensionProblem]) {
        var snippets: [CodeSnippet] = [], problems: [ExtensionProblem] = []
        for file in files where ["json", "code-snippets"].contains(file.pathExtension) {
            let stem = file.deletingPathExtension().lastPathComponent
            let language = file.pathExtension == "code-snippets" || ["snippets", "global"].contains(stem) ? nil : stem
            do {
                snippets += try parse(Data(contentsOf: file), language: language, source: source)
            } catch {
                problems.append(ExtensionProblem(location: file, message: error.localizedDescription))
            }
        }
        return (snippets, problems)
    }
}

/// All snippets a file can use (D195): its project's (`.orbit/snippets`), the
/// user's (`~/.orbit/snippets`) and the installed extensions'. The user's
/// folder is watched; a project's is read again when its files change.
@MainActor
@Observable
public final class SnippetLibrary {
    public static let shared = SnippetLibrary()

    public static var userDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".orbit/snippets", directoryHint: .isDirectory)
    }

    public static func projectDirectory(root: URL) -> URL {
        root.appending(path: ".orbit/snippets", directoryHint: .isDirectory)
    }

    public private(set) var userSnippets: [CodeSnippet] = []
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var projects: [URL: (stamp: [Date], snippets: [CodeSnippet])] = [:]

    private init() {
        try? FileManager.default.createDirectory(at: Self.userDirectory, withIntermediateDirectories: true)
        reloadUser()
        watcher = DirectoryWatcher(url: Self.userDirectory) { [weak self] in self?.reloadUser() }
    }

    private func reloadUser() {
        let loaded = CodeSnippet.load(folder: Self.userDirectory, source: "Your snippets").snippets
        if loaded != userSnippets { userSnippets = loaded }
    }

    /// The project's own, then the user's, then extensions'; for `url`'s language.
    public func snippets(for url: URL, root: URL?) -> [CodeSnippet] {
        let language = GrammarCatalog.shared.language(for: url)?.id
        let fileExtension = url.pathExtension
        let all = (root.map(projectSnippets) ?? []) + userSnippets + Extensions.shared.snippets
        return all.filter { $0.applies(toLanguage: language, fileExtension: fileExtension) }
    }

    /// Read again only when a file in the folder changed (dates are cheap to list).
    private func projectSnippets(_ root: URL) -> [CodeSnippet] {
        let folder = Self.projectDirectory(root: root)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let stamp = files.map { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        if let cached = projects[root], cached.stamp == stamp { return cached.snippets }
        let snippets = files.isEmpty ? [] : CodeSnippet.load(folder: folder, source: "This project").snippets
        projects[root] = (stamp, snippets)
        return snippets
    }
}
