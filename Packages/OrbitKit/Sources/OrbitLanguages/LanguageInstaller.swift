import Foundation
import OrbitACP

/// Installs language servers from the Mason registry (D57) into
/// `~/.orbit/languages/<package>`: npm and PyPI packages, Go and Cargo
/// builds, GitHub release assets and plain downloads. Only the data of the
/// registry is used; installing is our own code (curl, tar, unzip, npm, pip…).
struct LanguageInstaller: Sendable {
    let root: URL

    static let shared = LanguageInstaller(
        root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".orbit/languages")
    )

    static let registryURL = URL(string: "https://github.com/mason-org/mason-registry/releases/latest/download/registry.json.zip")!

    func directory(for package: String) -> URL {
        root.appendingPathComponent(package)
    }

    // MARK: Receipts

    /// What's installed for a package, and how to run its binaries.
    struct Receipt: Codable, Sendable, Hashable {
        struct Binary: Codable, Sendable, Hashable {
            /// Relative to the package directory, or a tool looked up on PATH (`node`).
            var executable: String
            var arguments: [String]
            var isRelative: Bool
        }

        var package: String
        var version: String
        var binaries: [String: Binary]
    }

    func receipt(for package: String) -> Receipt? {
        let file = directory(for: package).appendingPathComponent("orbit-receipt.json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Receipt.self, from: data)
    }

    /// The command for an installed binary; nil when it's not installed (or its runtime is missing).
    func command(package: String, binary: String, arguments: [String], environment: [String: String]) -> AgentCommand? {
        guard let receipt = receipt(for: package), let entry = receipt.binaries[binary] else { return nil }
        let directory = directory(for: package)
        let own = entry.arguments.map { $0.hasPrefix("./") ? directory.appendingPathComponent(String($0.dropFirst(2))).path : $0 }
        if entry.isRelative {
            let path = directory.appendingPathComponent(entry.executable).path
            guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
            return AgentCommand(executable: path, arguments: own + arguments)
        }
        guard let tool = Shell.which(entry.executable, in: environment) else { return nil }
        return AgentCommand(executable: tool, arguments: own + arguments)
    }

    func uninstall(_ package: String) throws {
        let directory = directory(for: package)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: Registry

    /// The registry's packages by name, downloaded at most once a day.
    func registry(maxAge: TimeInterval = 24 * 3600) throws -> [String: JSONValue] {
        let cache = root.appendingPathComponent("registry.json")
        let age = (try? cache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { -$0.timeIntervalSinceNow }
        if age == nil || age! > maxAge {
            do {
                try refreshRegistry(into: cache)
            } catch where FileManager.default.fileExists(atPath: cache.path) {
                // Offline: yesterday's list still installs.
            }
        }
        let packages = try JSONDecoder().decode([JSONValue].self, from: Data(contentsOf: cache))
        var byName: [String: JSONValue] = [:]
        for package in packages {
            if let name = package["name"]?.string { byName[name] = package }
        }
        return byName
    }

    private func refreshRegistry(into cache: URL) throws {
        let work = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let archive = work.appendingPathComponent("registry.json.zip")
        try Self.download(Self.registryURL, to: archive)
        try Self.run("/usr/bin/unzip", ["-q", "-o", archive.path, "-d", work.path])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: cache.path) { try FileManager.default.removeItem(at: cache) }
        try FileManager.default.moveItem(at: work.appendingPathComponent("registry.json"), to: cache)
    }

    // MARK: Installing

    enum Failure: LocalizedError {
        case unsupported(String)
        case needs(String)
        case noBuild(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let what): "Orbit can't install \(what) packages yet."
            case .needs(let tool): "Needs \(tool). Install it, then try again."
            case .noBuild(let package): "\(package) has no build for this Mac."
            case .failed(let message): message
            }
        }
    }

    /// Installs (or replaces) a package. Blocking: call off the main actor.
    @discardableResult
    func install(_ package: JSONValue, environment: [String: String]) throws -> Receipt {
        guard let name = package["name"]?.string, let id = package["source"]?["id"]?.string,
              let purl = PackageURL(id) else { throw Failure.failed("The registry entry is malformed.") }
        let source = package["source"] ?? .null
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let work = root.appendingPathComponent(".install-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        var context: [String: JSONValue] = ["version": .string(purl.version)]
        let targets = Self.targets
        switch purl.type {
        case "npm":
            let npm = try Self.tool("npm", "Node.js", environment)
            let extras = (source["extra_packages"]?.array ?? []).compactMap(\.string)
            try Self.run(npm, ["install", "--prefix", work.path, "--no-save", "--no-audit", "--no-fund", "--no-package-lock",
                               "--loglevel=error", "\(purl.fullName)@\(purl.version)"] + extras, environment: environment)
        case "pypi":
            let python = try Self.tool("python3", "Python 3", environment)
            try Self.run(python, ["-m", "venv", work.appendingPathComponent("venv").path], environment: environment)
            let extras = (source["extra_packages"]?.array ?? []).compactMap(\.string)
            let pip = work.appendingPathComponent("venv/bin/python").path
            try Self.run(pip, ["-m", "pip", "install", "--quiet", "--disable-pip-version-check",
                               "\(purl.fullName)==\(purl.version)"] + extras, environment: environment)
        case "golang":
            let go = try Self.tool("go", "Go", environment)
            var env = environment
            env["GOBIN"] = work.appendingPathComponent("bin").path
            try Self.run(go, ["install", "\(purl.fullName)@\(purl.version)"], environment: env)
        case "cargo":
            let cargo = try Self.tool("cargo", "Rust (cargo)", environment)
            try Self.run(cargo, ["install", "--root", work.path, purl.name, "--version", purl.version, "--locked"], environment: environment)
        case "github":
            guard let asset = Self.pick(source["asset"], for: targets) else { throw Failure.noBuild(name) }
            context["source"] = ["asset": asset]
            let files = asset["file"]?.array?.compactMap(\.string) ?? asset["file"]?.string.map { [$0] } ?? []
            for spec in files {
                let (file, destination) = Self.split(Self.render(spec, context))
                let url = URL(string: "https://github.com/\(purl.fullName)/releases/download/\(purl.version)/\(file)")!
                try fetch(url, named: (file as NSString).lastPathComponent, into: work.appendingPathComponent(destination))
            }
        case "generic":
            guard let download = Self.pick(source["download"], for: targets) else { throw Failure.noBuild(name) }
            context["source"] = ["download": download]
            for (spec, address) in download["files"]?.object ?? [:] {
                guard let url = URL(string: Self.render(address.string ?? "", context)) else { continue }
                let (file, destination) = Self.split(spec)
                try fetch(url, named: file, into: work.appendingPathComponent(destination))
            }
        default:
            throw Failure.unsupported(purl.type)
        }

        var binaries: [String: Receipt.Binary] = [:]
        for (binary, expression) in package["bin"]?.object ?? [:] {
            guard let expression = expression.string else { continue }
            binaries[binary] = try Self.binary(Self.render(expression, context), in: work)
        }
        let receipt = Receipt(package: name, version: purl.version, binaries: binaries)
        try JSONEncoder().encode(receipt).write(to: work.appendingPathComponent("orbit-receipt.json"))

        // Swap in the new version only once everything worked.
        let destination = directory(for: name)
        let old = root.appendingPathComponent(".old-\(name)-\(UUID().uuidString)")
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.moveItem(at: destination, to: old) }
        try FileManager.default.moveItem(at: work, to: destination)
        try? FileManager.default.removeItem(at: old)
        return receipt
    }

    /// Downloads a file into `directory`, unpacking archives there.
    private func fetch(_ url: URL, named file: String, into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(file)
        try Self.download(url, to: target)
        let lower = file.lowercased()
        if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") || lower.hasSuffix(".tar.xz") || lower.hasSuffix(".tar.bz2") || lower.hasSuffix(".tar") {
            try Self.run("/usr/bin/tar", ["-xf", target.path, "-C", directory.path])
            try FileManager.default.removeItem(at: target)
        } else if lower.hasSuffix(".zip") || lower.hasSuffix(".vsix") {
            try Self.run("/usr/bin/unzip", ["-q", "-o", target.path, "-d", directory.path])
            try FileManager.default.removeItem(at: target)
        } else if lower.hasSuffix(".gz") {
            try Self.run("/usr/bin/gunzip", ["-f", target.path])
            Self.makeExecutable(target.deletingPathExtension())
        } else {
            Self.makeExecutable(target)
        }
    }

    // MARK: Pieces

    /// Mason's names for this machine, most specific first.
    static var targets: [String] {
        #if os(macOS)
        #if arch(arm64)
        return ["darwin_arm64", "darwin", "unix"]
        #else
        return ["darwin_x64", "darwin", "unix"]
        #endif
        #else
        #if arch(arm64)
        return ["linux_arm64_gnu", "linux_arm64", "linux", "unix"]
        #else
        return ["linux_x64_gnu", "linux_x64", "linux", "unix"]
        #endif
        #endif
    }

    /// The asset (or download) entry for the first matching target.
    static func pick(_ entries: JSONValue?, for targets: [String]) -> JSONValue? {
        let entries = entries?.array ?? (entries.map { [$0] } ?? [])
        for target in targets {
            if let match = entries.first(where: { entry in
                let names = entry["target"]?.array?.compactMap(\.string) ?? entry["target"]?.string.map { [$0] } ?? []
                return names.contains(target)
            }) {
                return match
            }
        }
        return nil
    }

    /// `name.tar.gz:libexec/` → the file and the folder it unpacks into.
    static func split(_ spec: String) -> (file: String, destination: String) {
        guard let colon = spec.lastIndex(of: ":") else { return (spec, "") }
        return (String(spec[..<colon]), String(spec[spec.index(after: colon)...]))
    }

    /// Mason's `{{ path | filter "arg" }}` templates; rendered until stable (values may hold templates).
    static func render(_ template: String, _ context: [String: JSONValue]) -> String {
        var text = template
        for _ in 0..<3 where text.contains("{{") {
            text = renderOnce(text, context)
        }
        return text
    }

    private static func renderOnce(_ template: String, _ context: [String: JSONValue]) -> String {
        var output = ""
        var rest = Substring(template)
        while let open = rest.range(of: "{{") {
            output += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "}}") else {
                rest = rest[open.lowerBound...]
                break
            }
            let expression = rest[open.upperBound..<close.lowerBound]
            output += evaluate(String(expression), context)
            rest = rest[close.upperBound...]
        }
        return output + rest
    }

    private static func evaluate(_ expression: String, _ context: [String: JSONValue]) -> String {
        let parts = expression.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let path = parts.first else { return "" }
        var value: JSONValue? = .object(context)
        for key in path.split(separator: ".") { value = value?[String(key)] }
        var text = value?.string ?? ""
        for filter in parts.dropFirst() {
            let words = filter.split(separator: " ", maxSplits: 1).map(String.init)
            let argument = words.count > 1 ? words[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) : ""
            switch words.first {
            case "strip_prefix" where text.hasPrefix(argument): text.removeFirst(argument.count)
            case "strip_suffix" where text.hasSuffix(argument): text.removeLast(argument.count)
            default: break
            }
        }
        return text
    }

    /// `npm:x`, `pypi:x`, `golang:x`, `cargo:x`, `exec:path`, `node:path`, or a path.
    static func binary(_ expression: String, in directory: URL) throws -> Receipt.Binary {
        let (kind, value): (String, String) = if let colon = expression.firstIndex(of: ":") {
            (String(expression[..<colon]), String(expression[expression.index(after: colon)...]))
        } else {
            ("", expression)
        }
        switch kind {
        case "npm": return .init(executable: "node_modules/.bin/\(value)", arguments: [], isRelative: true)
        // Scripts in a venv remember where it was built; its python finds the venv from its own path.
        case "pypi": return .init(executable: "venv/bin/python", arguments: ["./venv/bin/\(value)"], isRelative: true)
        case "golang", "cargo": return .init(executable: "bin/\(value)", arguments: [], isRelative: true)
        case "node": return .init(executable: "node", arguments: ["./\(value)"], isRelative: false)
        case "python": return .init(executable: "python3", arguments: ["./\(value)"], isRelative: false)
        case "exec", "":
            makeExecutable(directory.appendingPathComponent(value))
            return .init(executable: value, arguments: [], isRelative: true)
        default:
            throw Failure.unsupported(kind)
        }
    }

    private static func makeExecutable(_ file: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    private static func tool(_ name: String, _ product: String, _ environment: [String: String]) throws -> String {
        guard let path = Shell.which(name, in: environment) else { throw Failure.needs(product) }
        return path
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func download(_ url: URL, to file: URL) throws {
        try run("/usr/bin/curl", ["-fsSL", "--retry", "2", "-o", file.path, url.absoluteString])
    }

    /// Runs a tool to completion; its last stderr lines become the error.
    static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let tail = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).suffix(4).joined(separator: "\n")
            let command = ([(executable as NSString).lastPathComponent] + arguments.prefix(2)).joined(separator: " ")
            throw Failure.failed("\(command) failed (\(process.terminationStatus))" + (tail.isEmpty ? "" : ":\n\(tail)"))
        }
    }
}

/// `pkg:type/namespace/name@version`, as Mason writes sources.
struct PackageURL: Sendable, Hashable {
    var type: String
    var namespace: String?
    var name: String
    var version: String

    init?(_ string: String) {
        guard string.hasPrefix("pkg:") else { return nil }
        var rest = String(string.dropFirst(4))
        if let query = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) { rest = String(rest[..<query]) }
        guard let slash = rest.firstIndex(of: "/"), let at = rest.lastIndex(of: "@"), slash < at else { return nil }
        type = String(rest[..<slash])
        version = String(rest[rest.index(after: at)...]).removingPercentEncoding ?? ""
        let path = rest[rest.index(after: slash)..<at].split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        guard let last = path.last else { return nil }
        name = last
        namespace = path.count > 1 ? path.dropLast().joined(separator: "/") : nil
    }

    /// `@scope/name`, `owner/repo`, `golang.org/x/tools/gopls`.
    var fullName: String {
        namespace.map { "\($0)/\(name)" } ?? name
    }
}
