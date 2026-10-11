import Foundation
import OrbitACP
import OrbitAPI

/// One row in a session transcript. A class so streaming updates re-render
/// only the row that changed, not the whole list.
@MainActor
@Observable
final class TranscriptEntry: Identifiable {
    enum Kind { case user, agent, thought, tool, plan, notice }

    let id = UUID()
    let kind: Kind
    var text = ""

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

struct ConfigOption: Identifiable, Hashable {
    struct Choice: Hashable {
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

    init?(_ json: JSONValue) {
        guard let id = json["id"]?.string, json["type"]?.string == "select" else { return nil }
        self.id = id
        name = json["name"]?.string ?? id
        category = json["category"]?.string
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
