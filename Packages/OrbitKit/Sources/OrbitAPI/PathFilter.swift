import Foundation

/// "Files to include / exclude" in Find in Project, and the files Settings →
/// Files hides everywhere (D178): comma-separated globs, VS Code style. `*.swift` matches at any depth, a folder name matches
/// everything inside it, and a leading `/` anchors at the project root.
public struct PathFilter: Sendable {
    private let includes: [NSRegularExpression]
    private let excludes: [NSRegularExpression]

    public init(include: String = "", exclude: String = "") {
        includes = Self.compile(include)
        excludes = Self.compile(exclude)
    }

    public var isEmpty: Bool { includes.isEmpty && excludes.isEmpty }

    public func allows(_ path: String) -> Bool {
        if !includes.isEmpty, !includes.contains(where: { Self.matches($0, path) }) { return false }
        return !excludes.contains { Self.matches($0, path) }
    }

    /// The pattern may match the path itself or any folder it lives in.
    private static func matches(_ regex: NSRegularExpression, _ path: String) -> Bool {
        var prefix = ""
        for component in path.split(separator: "/") {
            prefix = prefix.isEmpty ? String(component) : prefix + "/" + component
            if regex.firstMatch(in: prefix, range: NSRange(location: 0, length: (prefix as NSString).length)) != nil { return true }
        }
        return false
    }

    private static func compile(_ list: String) -> [NSRegularExpression] {
        split(list).compactMap { try? NSRegularExpression(pattern: regexPattern(for: $0), options: [.caseInsensitive]) }
    }

    /// Splits on commas outside `{…}`, so `*.{h,m}` stays one pattern.
    public static func split(_ list: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        for character in list {
            switch character {
            case "{": depth += 1
            case "}": depth = max(0, depth - 1)
            case "," where depth == 0:
                parts.append(current)
                current = ""
                continue
            default: break
            }
            current.append(character)
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func regexPattern(for glob: String) -> String {
        var glob = Substring(glob)
        if glob.hasPrefix("./") { glob = glob.dropFirst(2) }
        let anchored = glob.hasPrefix("/")
        if anchored { glob = glob.drop { $0 == "/" } }
        while glob.hasSuffix("/") { glob = glob.dropLast() }

        let characters = Array(glob)
        var pattern = anchored ? "^" : "^(?:.*/)?"
        var braceDepth = 0
        var index = 0
        while index < characters.count {
            let character = characters[index]
            index += 1
            switch character {
            case "*" where index < characters.count && characters[index] == "*":
                index += 1
                if index < characters.count, characters[index] == "/" {
                    index += 1
                    pattern += "(?:.*/)?"
                } else {
                    pattern += ".*"
                }
            case "*":
                pattern += "[^/]*"
            case "?":
                pattern += "[^/]"
            case "{":
                braceDepth += 1
                pattern += "(?:"
            case "}" where braceDepth > 0:
                braceDepth -= 1
                pattern += ")"
            case "," where braceDepth > 0:
                pattern += "|"
            case "[":
                guard let close = characters[index...].firstIndex(of: "]"), close > index else {
                    pattern += "\\["
                    continue
                }
                var members = characters[index..<close]
                pattern += "["
                if members.first == "!" || members.first == "^" {
                    pattern += "^"
                    members = members.dropFirst()
                }
                for member in members {
                    pattern += member == "-" || member.isLetter || member.isNumber ? String(member) : "\\" + String(member)
                }
                pattern += "]"
                index = close + 1
            default:
                pattern += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        pattern += String(repeating: ")", count: braceDepth)
        return pattern + "$"
    }
}
