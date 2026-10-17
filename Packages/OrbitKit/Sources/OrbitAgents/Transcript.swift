import Foundation
import OrbitACP
import OrbitAPI

/// One row in a session transcript. A class so streaming updates re-render
/// only the row that changed, not the whole list.
@MainActor
@Observable
final class TranscriptEntry: Identifiable {
    enum Kind { case user, agent, thought, tool, plan, notice, summary }

    let id = UUID()
    let kind: Kind
    var text = ""
    /// User messages: what was attached to the prompt.
    var attachments: [PromptAttachment] = []
    /// User messages: the project's restore point from before it was sent.
    var checkpoint: String?

    // Tool calls
    var toolCallID: String?
    var title = ""
    var toolKind = "other"
    var status = "pending"
    var contents: [ToolContent] = []
    var output = ""
    var command: String?
    var permission: PermissionRequest?
    /// The command's terminal, when the agent runs it through us (ACP `terminal/*`).
    var terminalID: String?
    var terminal: AgentTerminal?

    // Plans
    var plan: [PlanItem] = []

    // Turn summaries
    var duration: TimeInterval = 0
    /// Files the turn left with unreviewed changes.
    var changedFiles: [URL] = []

    var isError = false

    init(kind: Kind, text: String = "") {
        self.kind = kind
        self.text = text
    }

    var isRunning: Bool { status == "pending" || status == "in_progress" }
}

enum ToolContent: Identifiable {
    case text(String)
    case diff(path: String, old: String?, new: String)

    var id: String {
        switch self {
        case .text(let text): "text:\(text.hashValue)"
        case .diff(let path, _, let new): "diff:\(path):\(new.hashValue)"
        }
    }
}

struct PlanItem: Hashable {
    var content: String
    var status: String
}

/// A command the agent offers (ACP `available_commands_update`), sent as "/name …".
struct SlashCommand: Hashable, Identifiable {
    var name: String
    var description: String
    /// What to type after the name, when the command takes input.
    var hint: String?

    var id: String { name }

    init?(_ json: JSONValue) {
        guard let name = json["name"]?.string, !name.isEmpty else { return nil }
        self.name = name
        description = json["description"]?.string ?? ""
        hint = json["input"]?["hint"]?.string
    }

    init(name: String, description: String = "", hint: String? = nil) {
        self.name = name
        self.description = description
        self.hint = hint
    }

    /// Name prefix matches first, then names containing the query; the agent's order otherwise.
    static func matches(_ query: String, in commands: [SlashCommand]) -> [SlashCommand] {
        guard !query.isEmpty else { return commands }
        let prefix = commands.filter { $0.name.range(of: query, options: [.caseInsensitive, .anchored]) != nil }
        let contains = commands.filter { !prefix.contains($0) && $0.name.localizedCaseInsensitiveContains(query) }
        return prefix + contains
    }
}

enum TurnActivity {
    /// What the agent is doing in its current turn, for the "Working…" line.
    @MainActor
    static func describe(_ entries: [TranscriptEntry]) -> String {
        var last: TranscriptEntry?
        for entry in entries.reversed() {
            if entry.kind == .user { break }
            if entry.kind == .tool, entry.isRunning, entry.permission?.isPending != true {
                let title = entry.title.isEmpty ? entry.toolKind.capitalized : entry.title
                return title.replacingOccurrences(of: "`", with: "")
            }
            if last == nil, entry.kind != .plan, entry.kind != .notice { last = entry }
        }
        switch last?.kind {
        case .thought: return "Thinking"
        case .agent: return "Writing"
        default: return "Working"
        }
    }

    /// Files whose unreviewed changes appeared or changed during a turn.
    static func changedFiles(before: [URL: DiffStats], after: [(URL, DiffStats)]) -> [URL] {
        after.compactMap { url, stats in before[url] == stats ? nil : url }
    }
}

struct DiffStats: Hashable {
    var added: Int
    var removed: Int
}

@MainActor
@Observable
final class PermissionRequest {
    struct Option: Identifiable, Hashable {
        var id: String
        var name: String
        var kind: String
        var isAllow: Bool { kind.hasPrefix("allow") }
    }

    let options: [Option]
    private(set) var resolution: String?
    private var continuation: CheckedContinuation<JSONValue, Error>?

    init(options: [Option], continuation: CheckedContinuation<JSONValue, Error>) {
        self.options = options
        self.continuation = continuation
    }

    var isPending: Bool { continuation != nil }

    func choose(_ option: Option) {
        resolution = option.name
        continuation?.resume(returning: ["outcome": ["outcome": "selected", "optionId": .string(option.id)]])
        continuation = nil
    }

    func cancel() {
        guard continuation != nil else { return }
        resolution = "Cancelled"
        continuation?.resume(returning: ["outcome": ["outcome": "cancelled"]])
        continuation = nil
    }
}

struct ConfigOption: Identifiable, Hashable, Codable {
    struct Choice: Hashable, Codable {
        var value: String
        var name: String
        var description: String?
    }

    var id: String
    var name: String
    var category: String?
    var currentValue: String
    var choices: [Choice]

    var currentName: String { choices.first { $0.value == currentValue }?.name ?? currentValue }
    var description: String?

    static let onValues: Set<String> = ["on", "true", "enabled"]
    private static let offValues: Set<String> = ["off", "false", "disabled"]

    /// Two choices that read as on and off (Claude's Fast mode): shown as a switch.
    var isToggle: Bool {
        let values = Set(choices.map { $0.value.lowercased() })
        return values.count == 2 && values.contains(where: Self.onValues.contains) && values.contains(where: Self.offValues.contains)
    }

    var isOn: Bool { Self.onValues.contains(currentValue.lowercased()) }
    var isFastMode: Bool { isToggle && (id.lowercased().contains("fast") || name.lowercased().contains("fast")) }

    init?(_ json: JSONValue) {
        guard let id = json["id"]?.string, json["type"]?.string == "select" else { return nil }
        self.id = id
        name = json["name"]?.string ?? id
        category = json["category"]?.string
        description = json["description"]?.string
        currentValue = json["currentValue"]?.string ?? ""
        choices = (json["options"]?.array ?? []).compactMap { option in
            guard let value = option["value"]?.string else { return nil }
            return Choice(value: value, name: option["name"]?.string ?? value, description: option["description"]?.string)
        }
    }

    init(id: String, name: String, category: String?, currentValue: String, choices: [Choice]) {
        self.id = id
        self.name = name
        self.category = category
        self.currentValue = currentValue
        self.choices = choices
    }
}
