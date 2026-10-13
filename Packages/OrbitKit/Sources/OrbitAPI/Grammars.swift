import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Syntax highlighting comes from Zed's languages (D71): its own and its
/// extension catalog's, converted by `make import-grammars` into
/// `Grammars.json`. A language is a grammar (a tree-sitter parser, pinned at a
/// commit) plus Zed's queries for it; several languages may share a grammar
/// (JavaScript is parsed with TSX's). Nothing is bundled: a language is built
/// on this Mac the first time a file of it, or embedding it, opens.
public struct SyntaxLanguage: Codable, Sendable, Hashable {
    public var name: String
    /// Folder name under `~/.orbit/grammars` (`C++` → `cpp`), unique in the catalog.
    public var id: String
    /// A key of `GrammarCatalog.grammars`.
    public var grammar: String
    /// Extensions or whole file names (`ts`, `Gemfile`, `tsconfig.json`).
    public var suffixes: [String]
    /// Zed's queries, pinned to a commit: what to color, and where other languages are embedded.
    public var highlights: String
    public var injections: String?
    /// A regex for the first line when no suffix matches (shebangs).
    public var firstLine: String?
    public var aliases: [String]?
    /// The Zed extension it comes from; nil for Zed's own languages.
    public var zedExtension: String?
    /// For ⌘/ (D73): `// `, `/// `; or a block comment's start and end.
    public var lineComments: [String]?
    public var blockComment: [String]?
    /// Pairs typing closes (`(` → `)`, `/*` → ` */`).
    public var brackets: [Bracket]?
    /// Characters a pair may be closed before, besides whitespace and the end.
    public var autocloseBefore: String?

    public struct Bracket: Codable, Sendable, Hashable {
        public var start: String
        public var end: String
    }

    enum CodingKeys: String, CodingKey {
        case name, id, grammar, suffixes, highlights, injections, firstLine, aliases, lineComments, blockComment, brackets, autocloseBefore
        case zedExtension = "extension"
    }
}

/// Where a grammar's source lives and what its library exports.
public struct GrammarRepository: Codable, Sendable, Hashable {
    public var repository: String
    /// A commit, or the crate's version when `archive` is set.
    public var commit: String
    /// A published crate (`.tar.gz`), for grammars whose repository lost the commit.
    public var archive: String?
    /// The grammar's folder in a repository holding several (`tsx`).
    public var path: String?
    /// `tree_sitter_<name>`.
    public var symbol: String
}

public struct GrammarCatalog: Sendable {
    /// Zed's own first, then extensions by popularity: ties go to the earlier one, as in Zed.
    public let languages: [SyntaxLanguage]
    public let grammars: [String: GrammarRepository]
    /// Suffix → positions in `languages`.
    private let suffixIndex: [String: [Int]]
    /// Lowercased name or suffix, alias, grammar → position (`language(named:)` runs per injection).
    private let nameIndex: [String: Int]

    public init(languages: [SyntaxLanguage], grammars: [String: GrammarRepository]) {
        self.languages = languages
        self.grammars = grammars
        var index: [String: [Int]] = [:]
        for (position, language) in languages.enumerated() {
            for suffix in Set(language.suffixes) { index[suffix, default: []].append(position) }
        }
        suffixIndex = index
        var names: [String: Int] = [:]
        // Later passes don't override earlier ones: name/suffix, then aliases, then grammar.
        for (position, language) in languages.enumerated() {
            for key in [language.name] + language.suffixes { names[key.lowercased()] = names[key.lowercased()] ?? position }
        }
        for (position, language) in languages.enumerated() {
            for alias in language.aliases ?? [] { names[alias.lowercased()] = names[alias.lowercased()] ?? position }
        }
        for (position, language) in languages.enumerated() {
            names[language.grammar.lowercased()] = names[language.grammar.lowercased()] ?? position
        }
        nameIndex = names
    }

    public static let shared = load()

    private struct Table: Decodable {
        var languages: [SyntaxLanguage]
        var grammars: [String: GrammarRepository]
    }

    static func load(_ url: URL? = Bundle.module.url(forResource: "Grammars", withExtension: "json")) -> GrammarCatalog {
        guard let url, let data = try? Data(contentsOf: url),
              let table = try? JSONDecoder().decode(Table.self, from: data) else {
            return GrammarCatalog(languages: [], grammars: [:])
        }
        return GrammarCatalog(languages: table.languages, grammars: table.grammars)
    }

    public func grammar(of language: SyntaxLanguage) -> GrammarRepository? {
        grammars[language.grammar]
    }

    /// Zed's rule: the longest matching suffix wins (`tsconfig.json` over `json`);
    /// with none, a first-line pattern.
    public func language(for url: URL, firstLine: @autoclosure () -> String? = nil) -> SyntaxLanguage? {
        let fileName = url.lastPathComponent
        // `.zshrc`'s extension is `zshrc` here, unlike `pathExtension`.
        let candidates = [fileName.split(separator: ".", omittingEmptySubsequences: false).last.map(String.init) ?? "", fileName, url.path]
        // A suffix matches a candidate equal to it or ending in `.<suffix>`, so only
        // the candidates and what follows each of their dots can be suffixes.
        var best: (index: Int, length: Int)?
        for candidate in candidates {
            var keys = [Substring(candidate)]
            var rest = Substring(candidate)
            while let dot = rest.firstIndex(of: ".") {
                rest = rest[rest.index(after: dot)...]
                keys.append(rest)
            }
            for key in keys {
                for index in suffixIndex[String(key)] ?? [] {
                    // Zed scores a language by the first candidate one of its suffixes matches.
                    let length = Self.matchLength(languages[index], candidates)
                    if length > (best?.length ?? 0) || (length == best?.length && index < best!.index) { best = (index, length) }
                }
            }
        }
        if let best { return languages[best.index] }
        guard let line = firstLine() else { return nil }
        return languages.first { language in
            language.firstLine.flatMap { try? NSRegularExpression(pattern: $0) }.map {
                $0.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
            } ?? false
        }
    }

    private static func matchLength(_ language: SyntaxLanguage, _ candidates: [String]) -> Int {
        language.suffixes.reduce(0) { length, suffix in
            let match = candidates.first { $0 == suffix || $0.hasSuffix("." + suffix) }
            return max(length, match?.count ?? 0)
        }
    }

    /// For a language another one embeds, as an injection query or a code fence
    /// names it: the language's name or one of its suffixes, any case (`TypeScript`,
    /// `ts`, `markdown-inline`); then its aliases or grammar's name, as Zed's modelines.
    public func language(named name: String) -> SyntaxLanguage? {
        nameIndex[name.lowercased()].map { languages[$0] }
    }
}

/// An installed language, as the editor loads it.
public struct InstalledGrammar: Codable, Sendable, Hashable {
    /// `SyntaxLanguage.name`.
    public var name: String
    /// The grammar's commit and symbol, and the queries' URLs, it was installed from.
    public var commit: String
    public var symbol: String
    public var queries: String
    /// Absolute paths; the library may be shared with other languages.
    public var library: String
    public var highlights: String
    /// What it embeds (CSS and JS in Vue); not every language has one.
    public var injections: String?
    public var layout: Int

    /// Bumped when installs change shape, so older ones are redone (3: Zed's catalog, D71).
    public static let layout = 3

    public func isCurrent(_ language: SyntaxLanguage, _ grammar: GrammarRepository) -> Bool {
        commit == grammar.commit && symbol == grammar.symbol && queries == Self.queries(of: language) && layout >= Self.layout
    }

    static func queries(of language: SyntaxLanguage) -> String {
        [language.highlights, language.injections].compactMap(\.self).joined(separator: " ")
    }
}

/// `~/.orbit/grammars/`: a folder per language (`<id>/`: queries and
/// `grammar.json`) and the compiled grammars they share (`lib/`).
public struct GrammarStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static let shared = GrammarStore(
        root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".orbit/grammars")
    )

    /// Posted when a grammar was installed or removed.
    public static let didChange = Notification.Name("OrbitGrammarsDidChange")

    private var libraries: URL { root.appendingPathComponent("lib") }

    public func installed(_ id: String) -> InstalledGrammar? {
        let manifest = root.appendingPathComponent(id).appendingPathComponent("grammar.json")
        guard let data = try? Data(contentsOf: manifest) else { return nil }
        return try? JSONDecoder().decode(InstalledGrammar.self, from: data)
    }

    public func all() -> [InstalledGrammar] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { !$0.hasPrefix(".") && $0 != "lib" }.compactMap(installed)
    }

    /// Removes installs of an older shape and libraries no language uses any more.
    public func pruneOutdated() {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names where !name.hasPrefix(".") && name != "lib" && installed(name).map({ $0.layout < InstalledGrammar.layout }) ?? true {
            try? manager.removeItem(at: root.appendingPathComponent(name))
        }
        let used = Set(all().map { URL(fileURLWithPath: $0.library).lastPathComponent })
        for name in (try? manager.contentsOfDirectory(atPath: libraries.path)) ?? [] where !used.contains(name) {
            let library = libraries.appendingPathComponent(name)
            // One built just now may be waiting for its language's install to finish.
            let built = (try? manager.attributesOfItem(atPath: library.path)[.modificationDate] as? Date) ?? .distantPast
            if built < Date(timeIntervalSinceNow: -3600) { try? manager.removeItem(at: library) }
        }
    }

    public func uninstall(_ id: String) throws {
        let directory = root.appendingPathComponent(id)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    public enum Failure: LocalizedError {
        case needs(String)
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .needs(let tool): "Needs \(tool)."
            case .failed(let message): message
            }
        }
    }

    /// Builds the language's grammar (unless another language already did) and
    /// fetches its queries; blocking.
    @discardableResult
    public func install(
        _ language: SyntaxLanguage, grammar: GrammarRepository, environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> InstalledGrammar {
        let manager = FileManager.default
        try manager.createDirectory(at: libraries, withIntermediateDirectories: true)
        let library = try buildLibrary(grammar, environment: environment)

        let work = root.appendingPathComponent(".install-\(language.id)-\(UUID().uuidString)")
        try manager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: work) }
        let highlights = work.appendingPathComponent("highlights.scm")
        try Self.run("/usr/bin/curl", ["-fsSL", "--retry", "2", "-o", highlights.path, language.highlights], environment: environment)
        if let injections = language.injections {
            let file = work.appendingPathComponent("injections.scm")
            try Self.run("/usr/bin/curl", ["-fsSL", "--retry", "2", "-o", file.path, injections], environment: environment)
        }

        let destination = root.appendingPathComponent(language.id)
        let installed = InstalledGrammar(
            name: language.name, commit: grammar.commit, symbol: grammar.symbol, queries: InstalledGrammar.queries(of: language),
            library: library.path,
            highlights: destination.appendingPathComponent("highlights.scm").path,
            injections: language.injections == nil ? nil : destination.appendingPathComponent("injections.scm").path,
            layout: InstalledGrammar.layout
        )
        try JSONEncoder().encode(installed).write(to: work.appendingPathComponent("grammar.json"))
        let old = root.appendingPathComponent(".old-\(language.id)-\(UUID().uuidString)")
        if manager.fileExists(atPath: destination.path) { try manager.moveItem(at: destination, to: old) }
        try manager.moveItem(at: work, to: destination)
        try? manager.removeItem(at: old)
        return installed
    }

    /// `lib/<symbol>-<commit>.dylib`, compiled from the grammar's source at its commit.
    private func buildLibrary(_ grammar: GrammarRepository, environment: [String: String]) throws -> URL {
        let manager = FileManager.default
        #if os(macOS)
        let suffix = "dylib"
        let (compiler, prefix) = ("/usr/bin/xcrun", ["clang", "-dynamiclib"])
        #else
        let suffix = "so"
        let (compiler, prefix) = (try Self.tool("clang", in: environment, needs: "clang"), ["-shared", "-fPIC"])
        #endif
        let library = libraries.appendingPathComponent("\(grammar.symbol)-\(grammar.commit.prefix(12)).\(suffix)")
        if manager.fileExists(atPath: library.path) { return library }

        let work = root.appendingPathComponent(".build-\(grammar.symbol)-\(UUID().uuidString)")
        let checkout = work.appendingPathComponent("source")
        try manager.createDirectory(at: checkout, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: work) }
        if let archive = grammar.archive {
            let file = work.appendingPathComponent("source.tar.gz")
            try Self.run("/usr/bin/curl", ["-fsSL", "--retry", "2", "-o", file.path, archive], environment: environment)
            try Self.run("/usr/bin/tar", ["-xzf", file.path, "-C", checkout.path, "--strip-components", "1"], environment: environment)
        } else {
            let git = try Self.tool("git", in: environment, needs: "git (Xcode Command Line Tools)")
            try Self.run(git, ["-C", checkout.path, "init", "-q"], environment: environment)
            try Self.run(git, ["-C", checkout.path, "fetch", "-q", "--depth", "1", grammar.repository, grammar.commit], environment: environment)
            // Some repositories keep test fixtures in Git LFS; the parser's source never is.
            try Self.run(git, ["-C", checkout.path, "-c", "filter.lfs.smudge=", "-c", "filter.lfs.process=", "-c", "filter.lfs.required=false",
                               "checkout", "-q", "FETCH_HEAD"], environment: environment)
        }

        let sources = (grammar.path.map { checkout.appendingPathComponent($0) } ?? checkout).appendingPathComponent("src")
        var files = [sources.appendingPathComponent("parser.c").path]
        let scanner = sources.appendingPathComponent("scanner.c").path
        if manager.fileExists(atPath: scanner) { files.append(scanner) }
        let built = work.appendingPathComponent(library.lastPathComponent)
        try Self.run(compiler, prefix + ["-O2", "-std=c11", "-w", "-I", sources.path] + files + ["-o", built.path], environment: environment)
        // Another language sharing it may have finished first; either copy is the same.
        do { try manager.moveItem(at: built, to: library) } catch where manager.fileExists(atPath: library.path) {}
        return library
    }

    private static func tool(_ name: String, in environment: [String: String], needs: String) throws -> String {
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
        for directory in path.split(separator: ":") where FileManager.default.isExecutableFile(atPath: "\(directory)/\(name)") {
            return "\(directory)/\(name)"
        }
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/\(name)") { return "/usr/bin/\(name)" }
        throw Failure.needs(needs)
    }

    private static func run(_ executable: String, _ arguments: [String], environment: [String: String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let tail = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).suffix(3).joined(separator: "\n")
            let name = (executable as NSString).lastPathComponent
            throw Failure.failed("\(name) \(arguments.first ?? "") failed (\(process.terminationStatus))" + (tail.isEmpty ? "" : ":\n\(tail)"))
        }
    }
}

/// Opens compiled grammars once per process; the pointer is tree-sitter's `TSLanguage *`.
public enum GrammarLibraries {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var loaded: [String: UInt] = [:]

    public static func language(_ grammar: InstalledGrammar) -> OpaquePointer? {
        lock.lock()
        defer { lock.unlock() }
        let key = grammar.library + "#" + grammar.commit
        if let address = loaded[key] { return OpaquePointer(bitPattern: address) }
        guard let handle = dlopen(grammar.library, RTLD_NOW | RTLD_LOCAL),
              let symbol = dlsym(handle, grammar.symbol) else { return nil }
        typealias Entry = @convention(c) () -> OpaquePointer?
        guard let language = unsafeBitCast(symbol, to: Entry.self)() else { return nil }
        loaded[key] = UInt(bitPattern: language)
        return language
    }
}
