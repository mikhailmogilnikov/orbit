import Foundation
import OrbitACP

/// An MCP server every agent gets when a chat starts (D86): `"mcpServers"` in
/// `~/.orbit/settings.json` and the project's `.orbit/settings.json`, in the
/// format of Claude Code's `.mcp.json`, Cursor's and Claude Desktop's configs.
struct MCPServer: Hashable, Sendable, Identifiable {
    enum Transport: Hashable, Sendable {
        case stdio(command: String, arguments: [String], environment: [String: String])
        case http(url: String, headers: [String: String])
        case sse(url: String, headers: [String: String])
    }

    var name: String
    var transport: Transport
    /// Whether it comes from the project's settings (they win over the user's by name).
    var isProject: Bool

    var id: String { name }

    var summary: String {
        switch transport {
        case .stdio(let command, let arguments, _): ([command] + arguments).joined(separator: " ")
        case .http(let url, _), .sse(let url, _): url
        }
    }

    /// The ACP `McpServer` for `session/new`, with `${VAR}` filled from the
    /// login shell and the command resolved through its PATH; nil when the
    /// agent can't take this transport.
    func acp(environment: [String: String], http: Bool, sse: Bool) -> JSONValue? {
        let expand = { (text: String) in Self.expand(text, environment) }
        let pairs = { (values: [String: String]) -> JSONValue in
            .array(values.sorted { $0.key < $1.key }.map { ["name": .string($0.key), "value": .string(expand($0.value))] })
        }
        switch transport {
        case .stdio(let command, let arguments, let env):
            return [
                "name": .string(name),
                "command": .string(Self.resolve(expand(command), path: environment["PATH"])),
                "args": .array(arguments.map { .string(expand($0)) }),
                "env": pairs(env),
            ]
        case .http(let url, let headers):
            guard http else { return nil }
            return ["type": "http", "name": .string(name), "url": .string(expand(url)), "headers": pairs(headers)]
        case .sse(let url, let headers):
            guard sse else { return nil }
            return ["type": "sse", "name": .string(name), "url": .string(expand(url)), "headers": pairs(headers)]
        }
    }

    // MARK: Settings files

    static func projectFile(root: URL) -> URL { root.appendingPathComponent(".orbit/settings.json") }
    static var userFile: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".orbit/settings.json") }

    /// The user's servers, then the project's over them by name; problems are
    /// files or entries that couldn't be read.
    static func load(project: URL?) -> (servers: [MCPServer], problems: [String]) {
        var byName: [String: MCPServer] = [:]
        var problems: [String] = []
        var files = [(userFile, "~/.orbit/settings.json", false)]
        if let project { files.append((projectFile(root: project), ".orbit/settings.json", true)) }
        for (url, display, isProject) in files {
            guard let data = try? Data(contentsOf: url) else { continue }
            let parsed = parse(data, displayPath: display, isProject: isProject)
            problems += parsed.problems
            for server in parsed.servers { byName[server.name] = server }
        }
        return (byName.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, problems)
    }

    static func parse(_ data: Data, displayPath: String, isProject: Bool) -> (servers: [MCPServer], problems: [String]) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ([], ["\(displayPath) isn't valid JSON."])
        }
        guard let value = object["mcpServers"] else { return ([], []) }
        guard let table = value as? [String: Any] else {
            return ([], ["\(displayPath): “mcpServers” should be an object keyed by server name."])
        }
        var servers: [MCPServer] = []
        var problems: [String] = []
        for (name, entry) in table {
            guard let entry = entry as? [String: Any] else {
                problems.append("\(displayPath): MCP server “\(name)” should be an object.")
                continue
            }
            if entry["disabled"] as? Bool == true || entry["enabled"] as? Bool == false { continue }
            let strings = { (key: String) in (entry[key] as? [String: Any] ?? [:]).compactMapValues { "\($0)" } }
            let type = (entry["type"] as? String)?.lowercased()
            let transport: Transport
            if let url = entry["url"] as? String ?? entry["serverUrl"] as? String {
                transport = type == "sse" ? .sse(url: url, headers: strings("headers")) : .http(url: url, headers: strings("headers"))
            } else if let command = entry["command"] as? String, !command.isEmpty {
                transport = .stdio(command: command, arguments: (entry["args"] as? [Any] ?? []).map { "\($0)" }, environment: strings("env"))
            } else {
                problems.append("\(displayPath): MCP server “\(name)” needs a “command” or a “url”.")
                continue
            }
            servers.append(MCPServer(name: name, transport: transport, isProject: isProject))
        }
        return (servers, problems)
    }

    /// Opens the settings file in the editor, adding an empty `"mcpServers"` when it has none.
    static func prepareForEditing(_ url: URL) {
        let manager = FileManager.default
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        if object?["mcpServers"] != nil { return }
        let updated: String
        if let object, !object.isEmpty, let brace = text.firstIndex(of: "{") {
            var copy = text
            copy.insert(contentsOf: "\n  \"mcpServers\": {\n  },", at: copy.index(after: brace))
            updated = copy
        } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || object != nil {
            updated = "{\n  \"mcpServers\": {\n  }\n}\n"
        } else {
            return  // Not JSON: leave it to the user.
        }
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? updated.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Helpers

    /// `${VAR}` and `${VAR:-default}`, as Claude Code expands them.
    static func expand(_ text: String, _ environment: [String: String]) -> String {
        guard text.contains("${") else { return text }
        var result = ""
        var rest = text[...]
        while let start = rest.range(of: "${"), let end = rest[start.upperBound...].firstIndex(of: "}") {
            result += rest[..<start.lowerBound]
            let body = rest[start.upperBound..<end]
            let parts = body.components(separatedBy: ":-")
            result += environment[parts[0]] ?? (parts.count > 1 ? parts.dropFirst().joined(separator: ":-") : "")
            rest = rest[rest.index(after: end)...]
        }
        return result + rest
    }

    /// Agents spawn the command without a login shell; a bare name is looked up
    /// on the shell's PATH so `npx` or `uvx` from Homebrew is found.
    static func resolve(_ command: String, path: String?) -> String {
        let command = (command as NSString).expandingTildeInPath
        guard !command.contains("/"), let path else { return command }
        for directory in path.split(separator: ":") {
            let candidate = "\(directory)/\(command)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return command
    }
}
