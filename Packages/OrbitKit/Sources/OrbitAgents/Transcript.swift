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

    // Thoughts: live ones are timed ("Thought for 8s"), replayed ones aren't.
    var startedAt: Date?
    var endedAt: Date?

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

    /// The title without the Markdown backticks agents put around commands.
    var plainTitle: String { title.replacingOccurrences(of: "`", with: "") }

    /// The command, when the title doesn't already say it.
    var shownCommand: String? {
        guard let command = command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty,
              command != plainTitle.trimmingCharacters(in: .whitespaces) else { return nil }
        return command
    }

    /// Text contents worth opening the call for, code fences taken apart.
    var shownTexts: [FencedText] {
        contents.compactMap { content in
            guard case .text(let text) = content else { return nil }
            let fenced = FencedText(text)
            return fenced.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : fenced
        }
    }

    /// False when opening the call would show nothing (a quiet command's
    /// "Done", a title repeated): such calls get no chevron.
    var hasDetails: Bool {
        if shownCommand != nil || !shownTexts.isEmpty || !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if contents.contains(where: { if case .diff = $0 { true } else { false } }) { return true }
        guard let terminal else { return false }
        return !terminal.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || terminal.exitStatus.map { !$0.succeeded } ?? true
    }
}

/// A tool's text output; agents often wrap it in a code fence ("```console").
struct FencedText: Hashable {
    var language: String
    var code: String

    init(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 2, let first = lines.first, first.hasPrefix("```"), lines.last?.hasPrefix("```") == true else {
            language = ""
            code = text
            return
        }
        language = first.dropFirst(3).trimmingCharacters(in: .whitespaces)
        lines.removeFirst()
        lines.removeLast()
        code = lines.joined(separator: "\n")
    }
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

    /// "3 of 7 done".
    static func progress(_ items: [PlanItem]) -> String {
        "\(items.count { $0.status == "completed" }) of \(items.count) done"
    }
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

enum ThoughtLabel {
    /// "Thinking…" while it streams, "Thought for 8s" after, "Thought" when replayed.
    static func text(startedAt: Date?, endedAt: Date?) -> String {
        guard let startedAt else { return "Thought" }
        guard let endedAt else { return "Thinking…" }
        return "Thought for \(TurnSummaryView.format(endedAt.timeIntervalSince(startedAt)))"
    }
}

enum TurnActivity {
    /// What the agent is doing in its current turn, for the "Working…" line.
    /// A running call or a thought still streaming already says so in its own
    /// (shimmering) row, so the line doesn't repeat it (D163).
    @MainActor
    static func describe(_ entries: [TranscriptEntry]) -> String {
        var last: TranscriptEntry?
        for entry in entries.reversed() {
            if entry.kind == .user { break }
            if entry.kind == .tool, entry.isRunning, entry.permission?.isPending != true { return "Working" }
            if last == nil, entry.kind != .plan, entry.kind != .notice { last = entry }
        }
        switch last?.kind {
        case .thought: return last?.startedAt != nil && last?.endedAt == nil ? "Working" : "Thinking"
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

    let id = UUID()
    let options: [Option]
    /// What the agent wants to do ("Edit App.swift"), for lists outside the transcript.
    var title = "Permission requested"
    private(set) var resolution: String?
    @ObservationIgnored var onChoose: ((Option) -> Void)?
    private var continuation: CheckedContinuation<JSONValue, Error>?

    init(options: [Option], continuation: CheckedContinuation<JSONValue, Error>) {
        self.options = options
        self.continuation = continuation
    }

    var isPending: Bool { continuation != nil }

    /// Allow once (or always), or reject once: by the ACP kinds, else the first of its side.
    func option(allow: Bool, always: Bool = false) -> Option? {
        let kind = allow ? (always ? "allow_always" : "allow_once") : "reject_once"
        return options.first { $0.kind == kind } ?? (always ? nil : options.first { $0.isAllow == allow })
    }

    func choose(_ option: Option) {
        resolution = option.name
        continuation?.resume(returning: ["outcome": ["outcome": "selected", "optionId": .string(option.id)]])
        continuation = nil
        onChoose?(option)
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

/// A transcript row: an entry, or a run of tool calls (and the thoughts
/// between them) folded into one line, like Claude Code's "Ran 4 commands".
@MainActor
enum TranscriptRow: Identifiable {
    case entry(TranscriptEntry)
    case group([TranscriptEntry])

    /// The first entry's id: a call that grows into a group keeps its place.
    nonisolated var id: UUID {
        switch self {
        case .entry(let entry): entry.id
        case .group(let entries): entries[0].id
        }
    }

    /// A call waiting for permission stays out: it needs an answer.
    static func isFoldable(_ entry: TranscriptEntry) -> Bool {
        switch entry.kind {
        case .thought: true
        case .tool: entry.permission?.isPending != true
        default: false
        }
    }

    static func rows(_ entries: [TranscriptEntry]) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        var run: [TranscriptEntry] = []
        func flush() {
            if run.count(where: { $0.kind == .tool }) > 1 { rows.append(.group(run)) } else { rows += run.map(TranscriptRow.entry) }
            run = []
        }
        for entry in entries {
            if isFoldable(entry) {
                run.append(entry)
            } else {
                flush()
                rows.append(.entry(entry))
            }
        }
        flush()
        return rows
    }

    /// "Read 3 files, ran 2 commands", kinds in the order they came.
    static func summary(_ entries: [TranscriptEntry]) -> String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for entry in entries where entry.kind == .tool {
            let kind = phrase(entry.toolKind, 1) == nil ? "other" : entry.toolKind
            if counts[kind] == nil { order.append(kind) }
            counts[kind, default: 0] += 1
        }
        let text = order.compactMap { phrase($0, counts[$0]!) }.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    private nonisolated static func phrase(_ kind: String, _ n: Int) -> String? {
        func count(_ noun: String) -> String { n == 1 ? "a \(noun)" : "\(n) \(noun)s" }
        return switch kind {
        case "read": "read \(count("file"))"
        case "edit": "edited \(count("file"))"
        case "delete": "deleted \(count("file"))"
        case "move": "moved \(count("file"))"
        case "search": n == 1 ? "searched once" : "searched \(n) times"
        case "execute": "ran \(count("command"))"
        case "fetch": "fetched \(count("page"))"
        case "other": "used \(count("tool"))"
        default: nil
        }
    }
}
