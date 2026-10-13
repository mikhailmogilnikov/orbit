import Foundation

/// The repository's own formatter, when it has one (D60): Prettier or Biome
/// installed in its `node_modules` and configured. Language servers format by
/// their built-in rules, which a repo with Prettier doesn't follow.
struct ProjectFormatter: Sendable, Equatable {
    enum Tool: String, Sendable {
        case prettier, biome
    }

    var tool: Tool
    var executable: String
    /// Where the config was found; the formatter runs there.
    var directory: URL

    private static let prettierConfigs = [
        ".prettierrc", ".prettierrc.json", ".prettierrc.json5", ".prettierrc.yaml", ".prettierrc.yml", ".prettierrc.toml",
        ".prettierrc.js", ".prettierrc.cjs", ".prettierrc.mjs", ".prettierrc.ts",
        "prettier.config.js", "prettier.config.cjs", "prettier.config.mjs", "prettier.config.ts",
    ]
    private static let prettierTypes: Set<String> = [
        "js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts", "json", "jsonc", "json5", "css", "scss", "less",
        "html", "vue", "yaml", "yml", "md", "mdx", "graphql", "gql", "hbs", "handlebars",
    ]
    private static let biomeTypes: Set<String> = ["js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts", "json", "jsonc", "css", "graphql", "gql"]

    /// The nearest configured formatter above `file`, not looking past `root`.
    static func find(for file: URL, root: URL?) -> ProjectFormatter? {
        let type = file.pathExtension.lowercased()
        guard prettierTypes.contains(type) || biomeTypes.contains(type) else { return nil }
        let manager = FileManager.default
        for directory in ancestors(of: file.deletingLastPathComponent(), root: root) {
            func has(_ name: String) -> Bool { manager.fileExists(atPath: directory.appendingPathComponent(name).path) }
            if biomeTypes.contains(type), has("biome.json") || has("biome.jsonc"),
               let executable = binary("biome", from: directory, root: root) {
                return ProjectFormatter(tool: .biome, executable: executable, directory: directory)
            }
            if prettierTypes.contains(type), prettierConfigs.contains(where: has) || packageConfiguresPrettier(directory),
               let executable = binary("prettier", from: directory, root: root) {
                return ProjectFormatter(tool: .prettier, executable: executable, directory: directory)
            }
        }
        return nil
    }

    /// The file's whole new text.
    func format(_ text: String, file: URL, environment: [String: String]) async throws -> String {
        let arguments = switch tool {
        case .prettier: ["--stdin-filepath", file.path]
        case .biome: ["format", "--stdin-file-path=\(file.path)"]
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let box = ProcessBox(process)
        return try await withTaskCancellationHandler {
            try await Task.detached {
                try process.run()
                let stdin = input.fileHandleForWriting
                Task.detached {
                    stdin.write(Data(text.utf8))
                    try? stdin.close()
                }
                // Both pipes drain at once: a big file's errors mustn't block its output.
                let errorData = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let failure = await errorData.value
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    let tail = String(decoding: failure, as: UTF8.self).split(whereSeparator: \.isNewline).prefix(6).joined(separator: "\n")
                    throw LanguageInstaller.Failure.failed("\(tool.rawValue) failed" + (tail.isEmpty ? "" : ":\n\(tail)"))
                }
                return String(decoding: data, as: UTF8.self)
            }.value
        } onCancel: {
            box.terminate()
        }
    }

    private final class ProcessBox: @unchecked Sendable {
        let process: Process
        init(_ process: Process) { self.process = process }
        func terminate() { if process.isRunning { process.terminate() } }
    }

    private static func packageConfiguresPrettier(_ directory: URL) -> Bool {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("package.json")),
              let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return package["prettier"] != nil
    }

    /// The repo's own copy only: a global one may be another major version.
    private static func binary(_ name: String, from directory: URL, root: URL?) -> String? {
        for directory in ancestors(of: directory, root: root) {
            let path = directory.appendingPathComponent("node_modules/.bin/\(name)").path
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// `directory` and its parents up to `root` (or `/`).
    static func ancestors(of directory: URL, root: URL?) -> [URL] {
        var result: [URL] = []
        var current = directory.standardizedFileURL
        let stop = root?.standardizedFileURL.path
        while true {
            result.append(current)
            if current.path == stop || current.path == "/" { break }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return result
    }
}

/// How a file is indented: from `.editorconfig`, else guessed from the file.
struct Indentation: Sendable, Equatable {
    var size: Int
    var spaces: Bool

    static func of(_ file: URL, text: String, root: URL?) -> Indentation {
        let guessed = guess(text)
        guard let config = EditorConfig.properties(for: file, root: root) else { return guessed }
        var result = guessed
        if let style = config["indent_style"] { result.spaces = style != "tab" }
        let size = config["indent_size"].flatMap { $0 == "tab" ? config["tab_width"] : $0 } ?? config["tab_width"]
        if let size = size.flatMap(Int.init), size > 0 { result.size = size }
        return result
    }

    /// The most common step between consecutive indented lines. Not the smallest
    /// indent: a JSDoc block's ` * ` lines are indented by one space.
    static func guess(_ text: String) -> Indentation {
        var steps: [Int: Int] = [:]
        var tabs = 0, spaced = 0, previous = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(2000) {
            let body = line.drop { $0 == " " || $0 == "\t" }
            if body.isEmpty || body.hasPrefix("*") { continue }
            if line.hasPrefix("\t") {
                tabs += 1
                continue
            }
            let indent = line.count - body.count
            if indent > 0 { spaced += 1 }
            let step = abs(indent - previous)
            if step > 0, step <= 8 { steps[step, default: 0] += 1 }
            previous = indent
        }
        if tabs > spaced { return Indentation(size: 4, spaces: false) }
        // Ties go to the smaller step: 2 and 4 are both common in a 2-space file.
        let size = steps.max { lhs, rhs in lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key }?.key ?? 4
        return Indentation(size: size, spaces: true)
    }
}

/// The `.editorconfig` properties for a file: files nearer to it win, later sections win.
enum EditorConfig {
    static func properties(for file: URL, root: URL?) -> [String: String]? {
        var layers: [[String: String]] = []
        for directory in ProjectFormatter.ancestors(of: file.deletingLastPathComponent(), root: root) {
            guard let text = try? String(contentsOf: directory.appendingPathComponent(".editorconfig"), encoding: .utf8) else { continue }
            let relative = String(file.standardizedFileURL.path.dropFirst(directory.path == "/" ? 1 : directory.path.count + 1))
            let (properties, isRoot) = parse(text, for: relative)
            layers.append(properties)
            if isRoot { break }
        }
        guard !layers.isEmpty else { return nil }
        var merged: [String: String] = [:]
        for layer in layers.reversed() { merged.merge(layer) { _, new in new } }
        return merged
    }

    /// The properties that apply to `path` (relative to the file's folder), and whether it says `root = true`.
    static func parse(_ text: String, for path: String) -> (properties: [String: String], isRoot: Bool) {
        var properties: [String: String] = [:]
        var isRoot = false
        var matches: Bool?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                matches = glob(String(line.dropFirst().dropLast()), matches: path)
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces).lowercased()
            switch matches {
            case nil: if key == "root" { isRoot = value == "true" }
            case true?: properties[key] = value
            case false?: break
            }
        }
        return (properties, isRoot)
    }

    /// EditorConfig globs: `*`, `**`, `?`, `[…]`, `{a,b}`; one without a `/` matches the file name anywhere.
    static func glob(_ pattern: String, matches path: String) -> Bool {
        var pattern = pattern
        if pattern.hasPrefix("/") { pattern.removeFirst() } else if !pattern.contains("/") { pattern = "**/" + pattern }
        var regex = "^"
        var chars = Array(pattern)[...]
        var braces = 0
        while let char = chars.popFirst() {
            switch char {
            case "*":
                if chars.first == "*" {
                    chars.removeFirst()
                    if chars.first == "/" {
                        chars.removeFirst()
                        regex += "(?:.*/)?"
                    } else {
                        regex += ".*"
                    }
                } else {
                    regex += "[^/]*"
                }
            case "?": regex += "[^/]"
            case "[":
                var set = ""
                while let next = chars.popFirst(), next != "]" { set.append(next == "!" && set.isEmpty ? "^" : next) }
                regex += "[\(set.replacingOccurrences(of: "\\", with: "\\\\"))]"
            case "{":
                braces += 1
                regex += "(?:"
            case "}" where braces > 0:
                braces -= 1
                regex += ")"
            case "," where braces > 0: regex += "|"
            default: regex += NSRegularExpression.escapedPattern(for: String(char))
            }
        }
        regex += "$"
        return path.range(of: regex, options: .regularExpression) != nil
    }
}
