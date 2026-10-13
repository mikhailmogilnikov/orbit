import Foundation
import OrbitACP

/// A language server Orbit knows how to find and run (D54). Our own table:
/// which files it serves and how to launch it; installing missing servers
/// comes later from the Mason registry.
struct LanguageServerConfig: Sendable {
    var id: String
    var name: String
    /// File extension → LSP `languageId`.
    var languages: [String: String]
    /// The command in this environment for a project at `root`; nil when the
    /// server isn't installed (`missing` says what to install).
    var resolve: @Sendable (_ root: URL, _ environment: [String: String]) -> AgentCommand?
    var missing: String

    static let all: [LanguageServerConfig] = [swift, typescript]

    static func config(for url: URL) -> LanguageServerConfig? {
        let ext = url.pathExtension.lowercased()
        return all.first { $0.languages[ext] != nil }
    }

    func languageID(for url: URL) -> String {
        languages[url.pathExtension.lowercased()] ?? id
    }

    /// SourceKit-LSP ships with Xcode (and Swift toolchains).
    static let swift = LanguageServerConfig(
        id: "sourcekit-lsp",
        name: "Swift",
        languages: ["swift": "swift"],
        resolve: { _, environment in
            if let path = Shell.output("/usr/bin/xcrun", ["--find", "sourcekit-lsp"]), FileManager.default.isExecutableFile(atPath: path) {
                return AgentCommand(executable: path)
            }
            return Shell.which("sourcekit-lsp", in: environment).map { AgentCommand(executable: $0) }
        },
        missing: "Install Xcode or a Swift toolchain."
    )

    /// typescript-language-server over tsserver: the project's own copy first,
    /// then a global one, else npx fetches both packages (needs Node.js).
    static let typescript = LanguageServerConfig(
        id: "typescript-language-server",
        name: "TypeScript",
        languages: [
            "ts": "typescript", "mts": "typescript", "cts": "typescript", "tsx": "typescriptreact",
            "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascriptreact",
        ],
        resolve: { root, environment in
            let local = root.appendingPathComponent("node_modules/.bin/typescript-language-server").path
            if FileManager.default.isExecutableFile(atPath: local) {
                return AgentCommand(executable: local, arguments: ["--stdio"])
            }
            if let global = Shell.which("typescript-language-server", in: environment) {
                return AgentCommand(executable: global, arguments: ["--stdio"])
            }
            if let npx = Shell.which("npx", in: environment) {
                return AgentCommand(executable: npx, arguments: [
                    "-y", "-p", "typescript-language-server", "-p", "typescript", "typescript-language-server", "--stdio",
                ])
            }
            return nil
        },
        missing: "Install Node.js, or typescript-language-server in the project."
    )
}

enum Shell {
    static func which(_ name: String, in environment: [String: String]) -> String? {
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
        for directory in path.split(separator: ":") {
            let candidate = "\(directory)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// First line of a short command's output; nil when it fails.
    static func output(_ tool: String, _ arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let line = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).first.map(String.init)
        return line?.isEmpty == false ? line : nil
    }
}
