import Foundation

/// How a file is indented: from `.editorconfig`, else guessed from the file.
public struct Indentation: Sendable, Equatable {
    /// Columns per level; also how wide a tab is drawn.
    public var size: Int
    public var spaces: Bool

    public init(size: Int, spaces: Bool) {
        self.size = size
        self.spaces = spaces
    }

    /// One level, as typed.
    public var unit: String { spaces ? String(repeating: " ", count: size) : "\t" }

    public static func of(_ file: URL, text: String, root: URL?) -> Indentation {
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
    public static func guess(_ text: String) -> Indentation {
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
public enum EditorConfig {
    public static func properties(for file: URL, root: URL?) -> [String: String]? {
        var layers: [[String: String]] = []
        for directory in ancestors(of: file.deletingLastPathComponent(), root: root) {
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
    public static func parse(_ text: String, for path: String) -> (properties: [String: String], isRoot: Bool) {
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
    public static func glob(_ pattern: String, matches path: String) -> Bool {
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

    /// A folder and the ones above it, up to the workspace root.
    public static func ancestors(of directory: URL, root: URL?) -> [URL] {
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
