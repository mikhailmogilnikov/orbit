import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Syntax highlighting beyond the grammars built into the editor (D58):
/// installed with a language's support, compiled on this Mac from the
/// grammar's source at a pinned commit, colored by Zed's highlight queries
/// (the capture names Zed themes style). Nothing loads until a file of that
/// language opens.
public struct GrammarSource: Sendable, Hashable {
    /// Also the C symbol: `tree_sitter_<name>`.
    public var name: String
    public var fileTypes: [String]
    public var fileNames: [String]
    public var repository: String
    public var commit: String
    /// The grammar's folder in a repository holding several (`tsx`).
    public var path: String?
    /// Folder URL with `highlights.scm`, pinned to a commit.
    public var queries: String

    public init(name: String, fileTypes: [String], fileNames: [String] = [], repository: String, commit: String, path: String? = nil, queries: String) {
        self.name = name
        self.fileTypes = fileTypes
        self.fileNames = fileNames
        self.repository = repository
        self.commit = commit
        self.path = path
        self.queries = queries
    }

    private static func zedExtension(_ repository: String, _ commit: String, _ language: String) -> String {
        "https://raw.githubusercontent.com/\(repository)/\(commit)/languages/\(language)"
    }

    /// Languages Orbit has a server for but the editor has no grammar for (or a poor stand-in).
    public static let all: [GrammarSource] = [
        GrammarSource(
            name: "lua", fileTypes: ["lua"],
            repository: "https://github.com/tree-sitter-grammars/tree-sitter-lua", commit: "10fe0054734eec83049514ea2e718b2a56acd0c9",
            queries: zedExtension("zed-extensions/lua", "ce3fde1f675b32ce2de032e32609aba18cbf8121", "lua")
        ),
        GrammarSource(
            name: "zig", fileTypes: ["zig", "zon"],
            repository: "https://github.com/tree-sitter-grammars/tree-sitter-zig", commit: "6479aa13f32f701c383083d8b28360ebd682fb7d",
            queries: zedExtension("zed-extensions/zig", "996432e66cb5bb2eed5a30ad2afaaa90349a3817", "zig")
        ),
        GrammarSource(
            name: "hcl", fileTypes: ["tf", "tfvars", "hcl"],
            repository: "https://github.com/tree-sitter-grammars/tree-sitter-hcl", commit: "fad991865fee927dd1de5e172fb3f08ac674d914",
            queries: zedExtension("zed-extensions/terraform", "99bcfa52db879b6f71b803307a9640e04e336623", "terraform")
        ),
        GrammarSource(
            name: "dockerfile", fileTypes: ["dockerfile"], fileNames: ["Dockerfile", "Containerfile"],
            repository: "https://github.com/camdencheek/tree-sitter-dockerfile", commit: "868e44ce378deb68aac902a9db68ff82d2299dd0",
            queries: zedExtension("zed-extensions/dockerfile", "812fbe0e227d06e2c9e17864cd96985b064125ef", "dockerfile")
        ),
        GrammarSource(
            name: "kotlin", fileTypes: ["kt", "kts"],
            repository: "https://github.com/fwcd/tree-sitter-kotlin", commit: "1852ea17b7f60fb3f9d84e0b1555d56b46b39fb1",
            queries: zedExtension("zed-extensions/zed-kotlin", "861761c3813fd6497ede7b67bd6341e49571ef37", "kotlin")
        ),
        GrammarSource(
            name: "svelte", fileTypes: ["svelte"],
            repository: "https://github.com/tree-sitter-grammars/tree-sitter-svelte", commit: "3f06f705410683adb17d146b5eca28c62fe81ba6",
            queries: zedExtension("zed-extensions/svelte", "ca6c2c6c891583a23820d9b23772e116426cc57d", "svelte")
        ),
        GrammarSource(
            name: "scss", fileTypes: ["scss"],
            repository: "https://github.com/simeonoff/tree-sitter-scss", commit: "3f918284a73a54b53e4f326b0aa8c74ccbf4ee4d",
            queries: zedExtension("bajrangCoder/zed-scss", "18deab7712272b64a4ca24ed0950618631d77fa8", "scss")
        ),
        // The built-in TypeScript grammar can't read JSX.
        GrammarSource(
            name: "tsx", fileTypes: ["tsx", "jsx"],
            repository: "https://github.com/tree-sitter/tree-sitter-typescript", commit: "f975a621f4e7f532fe322e13c4f79495e0a7b2e7", path: "tsx",
            queries: "https://raw.githubusercontent.com/zed-industries/zed/26363aabdb31a0c016728634202e1ad5067033aa/crates/grammars/src/tsx"
        ),
    ]

    public static func source(for url: URL) -> GrammarSource? {
        let ext = url.pathExtension.lowercased(), name = url.lastPathComponent
        return all.first { $0.fileTypes.contains(ext) || $0.fileNames.contains(name) }
    }
}

/// A compiled grammar on disk, as the editor loads it.
public struct InstalledGrammar: Codable, Sendable, Hashable {
    public var name: String
    public var commit: String
    public var fileTypes: [String]
    public var fileNames: [String]
    /// Absolute paths.
    public var library: String
    public var highlights: String

    public var symbol: String { "tree_sitter_\(name)" }
}

/// `~/.orbit/grammars/<name>/`: the library, its queries and `grammar.json`.
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

    public func installed(_ name: String) -> InstalledGrammar? {
        let manifest = root.appendingPathComponent(name).appendingPathComponent("grammar.json")
        guard let data = try? Data(contentsOf: manifest) else { return nil }
        return try? JSONDecoder().decode(InstalledGrammar.self, from: data)
    }

    public func all() -> [InstalledGrammar] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.compactMap(installed)
    }

    public func grammar(for url: URL, in grammars: [InstalledGrammar]) -> InstalledGrammar? {
        let ext = url.pathExtension.lowercased(), name = url.lastPathComponent
        return grammars.first { $0.fileTypes.contains(ext) || $0.fileNames.contains(name) }
    }

    public func uninstall(_ name: String) throws {
        let directory = root.appendingPathComponent(name)
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

    /// Fetches the grammar at its commit, compiles it and its queries in; blocking.
    @discardableResult
    public func install(_ source: GrammarSource, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> InstalledGrammar {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let work = root.appendingPathComponent(".install-\(source.name)-\(UUID().uuidString)")
        let checkout = work.appendingPathComponent("source")
        try manager.createDirectory(at: checkout, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: work) }

        let git = try Self.tool("git", in: environment, needs: "git (Xcode Command Line Tools)")
        try Self.run(git, ["-C", checkout.path, "init", "-q"], environment: environment)
        try Self.run(git, ["-C", checkout.path, "fetch", "-q", "--depth", "1", source.repository, source.commit], environment: environment)
        try Self.run(git, ["-C", checkout.path, "checkout", "-q", "FETCH_HEAD"], environment: environment)

        let grammar = source.path.map { checkout.appendingPathComponent($0) } ?? checkout
        let sources = grammar.appendingPathComponent("src")
        var files = [sources.appendingPathComponent("parser.c").path]
        let scanner = sources.appendingPathComponent("scanner.c").path
        if manager.fileExists(atPath: scanner) { files.append(scanner) }
        #if os(macOS)
        let library = work.appendingPathComponent("lib\(source.name).dylib")
        let (compiler, prefix) = ("/usr/bin/xcrun", ["clang", "-dynamiclib"])
        #else
        let library = work.appendingPathComponent("lib\(source.name).so")
        let (compiler, prefix) = (try Self.tool("clang", in: environment, needs: "clang"), ["-shared", "-fPIC"])
        #endif
        try Self.run(compiler, prefix + ["-O2", "-std=c11", "-w", "-I", sources.path] + files + ["-o", library.path], environment: environment)

        let highlights = work.appendingPathComponent("highlights.scm")
        try Self.run("/usr/bin/curl", ["-fsSL", "--retry", "2", "-o", highlights.path, source.queries + "/highlights.scm"], environment: environment)
        try? manager.removeItem(at: checkout)

        let destination = root.appendingPathComponent(source.name)
        let installed = InstalledGrammar(
            name: source.name, commit: source.commit, fileTypes: source.fileTypes, fileNames: source.fileNames,
            library: destination.appendingPathComponent(library.lastPathComponent).path,
            highlights: destination.appendingPathComponent("highlights.scm").path
        )
        try JSONEncoder().encode(installed).write(to: work.appendingPathComponent("grammar.json"))
        let old = root.appendingPathComponent(".old-\(source.name)-\(UUID().uuidString)")
        if manager.fileExists(atPath: destination.path) { try manager.moveItem(at: destination, to: old) }
        try manager.moveItem(at: work, to: destination)
        try? manager.removeItem(at: old)
        return installed
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
