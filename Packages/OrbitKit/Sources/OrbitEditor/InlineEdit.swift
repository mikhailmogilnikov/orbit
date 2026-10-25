import AppKit
import OrbitAPI
import OrbitUI
import SwiftUI

/// ⌘K, like Cursor: an instruction for the selected lines (or code to write at
/// the caret) goes to a hidden read-only agent session; its code replaces the
/// lines in the buffer as an agent change, kept or undone inline (D127).
enum InlineEdit {
    /// Lines the reply replaces; empty means it's inserted at `lowerBound`.
    struct Target: Equatable {
        var lines: Range<Int>
        var original: [String]
    }

    /// The selected lines; without a selection the caret's line when it's
    /// blank, else a new line after it.
    static func target(fileLines: [String], selected: ClosedRange<Int>, hasSelection: Bool) -> Target {
        let last = max(0, fileLines.count - 1)
        let first = min(selected.lowerBound, last)
        if hasSelection {
            let lines = first..<(min(selected.upperBound, last) + 1)
            return Target(lines: lines, original: Array(fileLines[lines]))
        }
        if fileLines.isEmpty || fileLines[first].trimmingCharacters(in: .whitespaces).isEmpty {
            let lines = first..<min(first + 1, fileLines.count)
            return Target(lines: lines, original: Array(fileLines[lines]))
        }
        return Target(lines: (first + 1)..<(first + 1), original: [])
    }

    static func prompt(instruction: String, path: String, fileLines: [String], target: Target) -> String {
        let language = (path as NSString).pathExtension.lowercased()
        let instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let rules = """
        You may read the file and the project for context, but don't edit or create any files. \
        Reply with only the code, in one fenced code block, indented as the file is. No explanation.
        """
        if target.lines.isEmpty {
            let line = target.lines.lowerBound
            let before = fileLines[max(0, line - 8)..<min(line, fileLines.count)]
            let after = fileLines[min(line, fileLines.count)..<min(line + 8, fileLines.count)]
            return """
            Write code to insert into `\(path)` before line \(line + 1). \(rules)

            Instruction: \(instruction)

            The code around that place (the new code goes where ⟨here⟩ is):
            \(fence(Array(before) + ["⟨here⟩"] + Array(after), language: language))
            """
        }
        let range = target.lines.count == 1
            ? "line \(target.lines.lowerBound + 1)"
            : "lines \(target.lines.lowerBound + 1)–\(target.lines.upperBound)"
        return """
        Rewrite \(range) of `\(path)` as instructed. \(rules) Your code replaces exactly those lines.

        Instruction: \(instruction)

        The lines to rewrite:
        \(fence(target.original, language: language))
        """
    }

    /// The reply's first fenced block, else the whole reply.
    static func code(fromReply reply: String) -> String {
        let lines = LineDiff.lines(reply)
        guard let open = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }) else {
            return reply.trimmingCharacters(in: .newlines)
        }
        let marker = String(lines[open].trimmingCharacters(in: .whitespaces).prefix { $0 == "`" })
        let body = lines[(open + 1)...]
        let close = body.firstIndex { $0.trimmingCharacters(in: .whitespaces) == marker } ?? lines.endIndex
        return lines[(open + 1)..<close].joined(separator: "\n")
    }

    static func apply(_ code: String, to fileLines: [String], target: Target) -> [String] {
        var lines = fileLines
        lines.replaceSubrange(target.lines, with: LineDiff.lines(code))
        return lines
    }

    private static func fence(_ lines: [String], language: String) -> String {
        "```\(language)\n\(lines.joined(separator: "\n"))\n```"
    }
}

@MainActor
@Observable
final class InlineEditModel {
    enum State: Equatable {
        case idle, running
        case failed(String)
    }

    var instruction = ""
    private(set) var state = State.idle
    let agentName: String
    let isInsert: Bool
    @ObservationIgnored var onDone: () -> Void = {}

    private let document: TextDocument
    private let target: InlineEdit.Target
    private let path: String
    // Weak: a prompt left open must not keep the Agents and Review plugins'
    // models after they're turned off (D246).
    private weak var completion: AgentCompletion?
    private weak var changes: ChangeTracking?
    private let directory: URL
    @ObservationIgnored private var task: Task<Void, Never>?

    init(document: TextDocument, target: InlineEdit.Target, path: String, directory: URL, completion: AgentCompletion, changes: ChangeTracking?) {
        self.document = document
        self.target = target
        self.path = path
        self.directory = directory
        self.completion = completion
        self.changes = changes
        agentName = completion.agentName
        isInsert = target.lines.isEmpty
        completion.prewarm()
    }

    var canRun: Bool { state != .running && !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func run() {
        guard canRun else { return }
        guard let completion else { return state = .failed("Agents is turned off.") }
        state = .running
        let prompt = InlineEdit.prompt(instruction: instruction, path: path, fileLines: LineDiff.lines(document.text), target: target)
        task = Task { [weak self, completion, directory] in
            do {
                let reply = try await completion.complete(prompt, in: directory)
                guard let self, !Task.isCancelled else { return }
                if let problem = self.apply(InlineEdit.code(fromReply: reply)) {
                    self.state = .failed(problem)
                } else {
                    self.state = .idle
                    self.onDone()
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.state = .failed("\(self.agentName) couldn't make the edit: \(error.localizedDescription)")
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .idle
    }

    /// Into the buffer (unsaved, like the user's typing) as an agent change.
    private func apply(_ code: String) -> String? {
        let lines = LineDiff.lines(document.text)
        guard target.lines.upperBound <= lines.count, Array(lines[target.lines]) == target.original else {
            return "The code changed while \(agentName) was working. Try again."
        }
        let updated = InlineEdit.apply(code, to: lines, target: target).joined(separator: "\n")
        guard updated != document.text else { return "\(agentName) left the code as it was." }
        changes?.recordBaseline(document.text, for: document.url)
        document.text = updated
        return nil
    }
}

/// The ⌘K popover: the instruction, then progress or what went wrong.
struct InlineEditPrompt: View {
    @Bindable var model: InlineEditModel
    let close: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.secondary)
                TextField(
                    model.isInsert ? "Write code here with \(model.agentName)…" : "Edit the selection with \(model.agentName)…",
                    text: $model.instruction, axis: .vertical
                )
                .textFieldStyle(.plain)
                .orbitFont(.body)
                .lineLimit(1...6)
                .focused($isFocused)
                .disabled(model.state == .running)
                .onSubmit(model.run)
                .onExitCommand(perform: close)
            }
            HStack(spacing: 8) {
                switch model.state {
                case .running:
                    ProgressView().controlSize(.mini)
                    Text("\(model.agentName) is writing…")
                        .foregroundStyle(.secondary)
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(message)
                case .idle:
                    Text("The change shows inline to Keep or Undo")
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                Button(model.state == .running ? "Stop" : "Cancel", action: close)
                    .buttonStyle(.glass)
                Button(action: model.run) {
                    Text("\(model.state == .running ? "Working" : "Generate ")\(Text("↩").foregroundStyle(.secondary))")
                }
                .buttonStyle(.glassProminent)
                .disabled(!model.canRun)
            }
            .orbitFont(.caption)
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 420)
        .onAppear { isFocused = true }
        .onChange(of: model.state) { _, state in
            if state != .running { isFocused = true }
        }
    }
}

extension CodeEditor.Coordinator {
    /// ⌘K: opens the instruction popover over the selection.
    func startInlineEdit(completion: AgentCompletion, changes: ChangeTracking?, root: URL?, path: String) {
        guard let textView, textView.window != nil else { return }
        inlineEditPopover?.close()
        let fileLines = LineDiff.lines(document.text)
        let target = InlineEdit.target(fileLines: fileLines, selected: selectedLines, hasSelection: textView.textSelection.length > 0)
        let model = InlineEditModel(
            document: document, target: target, path: path,
            directory: root ?? document.url.deletingLastPathComponent(),
            completion: completion, changes: changes
        )
        let popover = NSPopover()
        // Clicking away hides it; the agent keeps working and its edit still lands.
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: InlineEditPrompt(model: model) { [weak popover] in
            model.cancel()
            popover?.close()
        }.tint(Theme.controlTint).pillControls())
        model.onDone = { [weak self, weak popover] in
            popover?.close()
            self?.reveal(line: target.lines.lowerBound)
        }
        inlineEditPopover = popover
        let anchorLine = min(target.lines.lowerBound, max(0, fileLines.count - 1))
        let rect = inlineDiff.lineRect(anchorLine)
            ?? CGRect(x: textView.visibleRect.midX, y: textView.visibleRect.midY, width: 1, height: 1)
        textView.scrollToVisible(rect.insetBy(dx: 0, dy: -80))
        popover.show(relativeTo: CGRect(x: rect.minX, y: rect.minY, width: max(1, min(rect.width, 240)), height: rect.height), of: textView, preferredEdge: .minY)
    }
}
