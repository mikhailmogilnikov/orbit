import OrbitAPI
import OrbitUI
import SwiftUI

struct AgentsPanel: View {
    let store: AgentStore

    var body: some View {
        VStack(spacing: 0) {
            if store.workspace.root == nil {
                EmptyStateView("No Folder Open", systemImage: "folder", message: "Agents work inside a project folder.")
            } else {
                if !store.sessions.isEmpty {
                    SessionTabs(store: store)
                    Divider()
                }
                if let session = store.selected {
                    SessionView(session: session, focusRequest: store.focusRequest)
                        .id(session.id)
                } else {
                    StartSessionView(store: store)
                }
            }
        }
    }
}

struct SessionTabs: View {
    let store: AgentStore

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(store.sessions) { session in
                        SessionChip(session: session, isSelected: store.selectedID == session.id) {
                            store.selectedID = session.id
                        } onClose: {
                            store.close(session)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            Menu {
                ForEach(store.providers) { provider in
                    Button {
                        store.newSession(provider)
                    } label: {
                        Label(provider.name, systemImage: provider.icon)
                    }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New session")
            .padding(.trailing, 10)
        }
        .frame(height: 36)
    }
}

struct SessionChip: View {
    let session: AgentSession
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            statusDot
            Text(session.title)
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: 140)
            if isHovering || isSelected {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(isSelected ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(isHovering ? Theme.subtleFill : .clear), in: .capsule)
        .contentShape(.capsule)
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }

    @ViewBuilder private var statusDot: some View {
        switch session.status {
        case .working, .starting:
            ProgressView().controlSize(.mini)
        case .failed:
            Circle().fill(.red).frame(width: 6, height: 6)
        case .ready:
            Image(systemName: session.provider.icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(session.hasPendingPermission ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        }
    }
}

struct StartSessionView: View {
    let store: AgentStore

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                OrbitMark()
                    .frame(width: 40, height: 40)
                    .foregroundStyle(.primary.opacity(0.85))
                    .padding(.bottom, 4)
                Text("Start an agent")
                    .font(.title3.weight(.semibold))
                Text("Agents work in this folder. Their edits\nshow up inline in the editor for review.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 8) {
                ForEach(store.providers) { provider in
                    Button {
                        store.newSession(provider)
                    } label: {
                        Label(provider.name, systemImage: provider.icon)
                            .frame(maxWidth: 200)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                }
            }
            Text("⇧⌘N new session · ⌘L focus chat")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Session

struct SessionView: View {
    let session: AgentSession
    let focusRequest: Int

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(session.entries) { entry in
                        EntryView(entry: entry)
                    }
                    StatusFooter(session: session)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            Composer(session: session, focusRequest: focusRequest)
        }
    }
}

struct StatusFooter: View {
    let session: AgentSession

    var body: some View {
        switch session.status {
        case .starting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Starting \(session.provider.name)…")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        case .working:
            if !session.hasPendingPermission {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Working…")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        case .failed(let message):
            Label {
                Text(message).textSelection(.enabled)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .font(.callout)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.08), in: .rect(cornerRadius: Theme.corner))
        case .ready:
            EmptyView()
        }
    }
}

struct EntryView: View {
    let entry: TranscriptEntry

    var body: some View {
        switch entry.kind {
        case .user:
            Text(entry.text)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.tint.opacity(0.08), in: .rect(cornerRadius: Theme.corner))
        case .agent:
            MarkdownText(entry.text)
        case .thought:
            ThoughtView(entry: entry)
        case .tool:
            ToolCallCard(entry: entry)
        case .plan:
            PlanView(items: entry.plan)
        case .notice:
            Text(entry.text)
                .font(.callout)
                .foregroundStyle(entry.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .textSelection(.enabled)
        }
    }
}

struct ThoughtView: View {
    let entry: TranscriptEntry
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "brain")
                    Text("Thinking")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if isExpanded {
                Text(entry.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Theme.hairline).frame(width: 2)
                    }
            }
        }
    }
}

struct PlanView: View {
    let items: [PlanItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Plan", systemImage: "list.bullet.clipboard")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: icon(item.status))
                        .foregroundStyle(item.status == "completed" ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                        .font(.caption)
                    Text(item.content)
                        .font(.callout)
                        .strikethrough(item.status == "completed", color: .secondary)
                        .foregroundStyle(item.status == "completed" ? .secondary : .primary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.corner))
    }

    private func icon(_ status: String) -> String {
        switch status {
        case "completed": "checkmark.circle.fill"
        case "in_progress": "circle.dotted.circle"
        default: "circle"
        }
    }
}

struct ToolCallCard: View {
    let entry: TranscriptEntry
    @State private var isExpanded: Bool?

    var body: some View {
        let expanded = isExpanded ?? defaultExpanded
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { isExpanded = !expanded }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(entry.title.isEmpty ? entry.toolKind.capitalized : entry.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    statusIcon
                    if hasDetails {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if expanded && hasDetails {
                Divider().opacity(0.6)
                details
            }

            if let permission = entry.permission, permission.isPending {
                Divider().opacity(0.6)
                PermissionBar(request: permission)
            } else if let resolution = entry.permission?.resolution {
                Text(resolution)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
        }
        .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.corner))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.corner)
                .strokeBorder(entry.permission?.isPending == true ? AnyShapeStyle(.orange.opacity(0.6)) : AnyShapeStyle(Theme.hairline))
        )
    }

    /// Live commands stay open while they run and when they fail.
    private var defaultExpanded: Bool {
        if let terminal = entry.terminal, terminal.exitStatus?.succeeded != true { return true }
        return entry.permission?.isPending == true || entry.contents.contains { if case .diff = $0 { true } else { false } }
    }

    private var hasDetails: Bool {
        !entry.contents.isEmpty || !entry.output.isEmpty || entry.command != nil || entry.terminal != nil
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let command = entry.command, command != entry.title {
                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(6)
            }
            ForEach(entry.contents) { content in
                switch content {
                case .text(let text):
                    Text(text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(20)
                        .textSelection(.enabled)
                case .diff(let path, let old, let new):
                    VStack(alignment: .leading, spacing: 4) {
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        CompactDiffView(old: old ?? "", new: new)
                            .clipShape(.rect(cornerRadius: Theme.smallCorner))
                    }
                }
            }
            if let terminal = entry.terminal {
                AgentTerminalOutput(terminal: terminal)
            } else if !entry.output.isEmpty {
                ScrollView {
                    Text(entry.output.split(separator: "\n", omittingEmptySubsequences: false).suffix(200).joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .defaultScrollAnchor(.bottom)
            }
        }
        .padding(10)
    }

    private var icon: String {
        switch entry.toolKind {
        case "read": "doc.text"
        case "edit": "pencil"
        case "delete": "trash"
        case "move": "arrow.right.doc.on.clipboard"
        case "search": "magnifyingglass"
        case "execute": "terminal"
        case "think": "brain"
        case "fetch": "globe"
        case "switch_mode": "arrow.triangle.branch"
        default: "wrench.and.screwdriver"
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch entry.status {
        case "completed":
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.green)
        case "failed":
            Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.red)
        default:
            if entry.permission?.isPending == true {
                Image(systemName: "hand.raised.fill").font(.system(size: 10)).foregroundStyle(.orange)
            } else {
                ProgressView().controlSize(.mini)
            }
        }
    }
}

/// Output of a command the agent runs in one of our terminals, live while it runs.
struct AgentTerminalOutput: View {
    let terminal: AgentTerminal

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !terminal.output.isEmpty {
                ScrollView {
                    Text(tail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .defaultScrollAnchor(.bottom)
            }
            HStack(spacing: 6) {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(isFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                Spacer(minLength: 4)
                if terminal.isRunning, terminal.ownsProcess {
                    Button("Stop") { terminal.kill() }
                        .buttonStyle(.glass)
                }
                Button("Show in Terminal", systemImage: "terminal") { terminal.reveal() }
                    .buttonStyle(.glass)
            }
            .controlSize(.small)
        }
    }

    private var tail: String {
        terminal.output.split(separator: "\n", omittingEmptySubsequences: false).suffix(200).joined(separator: "\n")
    }

    private var isFailure: Bool {
        guard let exit = terminal.exitStatus else { return false }
        return !exit.succeeded
    }

    private var status: String {
        guard let exit = terminal.exitStatus else { return "Running…" }
        if let code = exit.exitCode { return code == 0 ? "Done" : "Exited with code \(code)" }
        if let signal = exit.signal { return "Stopped (\(signal))" }
        return "Ended"
    }
}

struct PermissionBar: View {
    let request: PermissionRequest

    var body: some View {
        HStack(spacing: 6) {
            Text("Allow?")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            Spacer(minLength: 0)
            ForEach(request.options.sorted { rank($0) < rank($1) }) { option in
                if option.kind == "allow_once" {
                    Button(option.name) { request.choose(option) }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                } else {
                    Button(option.name) { request.choose(option) }
                        .buttonStyle(.glass)
                }
            }
        }
        .controlSize(.small)
        .padding(8)
    }

    private func rank(_ option: PermissionRequest.Option) -> Int {
        switch option.kind {
        case "reject_once": 0
        case "reject_always": 1
        case "allow_always": 2
        default: 3
        }
    }
}

// MARK: - Composer

struct Composer: View {
    @Bindable var session: AgentSession
    let focusRequest: Int
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Ask \(session.provider.name)…", text: $session.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...10)
                .focused($isFocused)
                .onSubmit(session.send)
                .disabled(isDisabled)

            HStack(spacing: 6) {
                ForEach(session.configOptions) { option in
                    Menu {
                        Picker(option.name, selection: Binding(
                            get: { option.currentValue },
                            set: { session.setConfigOption(option, value: $0) }
                        )) {
                            ForEach(option.choices, id: \.value) { choice in
                                Text(choice.name).tag(choice.value)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Text(option.currentName)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .help(option.name)
                }
                Spacer()
                if session.status == .working {
                    Button(action: session.stop) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .tint(.primary)
                    .help("Stop (⌘.)")
                } else {
                    Button(action: session.send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .disabled(session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.status != .ready)
                    .help("Send (↩)")
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .padding(10)
        .onAppear { isFocused = true }
        .onChange(of: focusRequest) { isFocused = true }
    }

    private var isDisabled: Bool {
        if case .failed = session.status { return true }
        return false
    }
}

struct AgentActivityStatus: View {
    let store: AgentStore

    var body: some View {
        let working = store.sessions.filter { $0.status == .working }.count
        let waiting = store.sessions.filter(\.hasPendingPermission).count
        HStack(spacing: 10) {
            if working > 0 {
                Label("\(working) working", systemImage: "sparkles")
                    .foregroundStyle(.tint)
            }
            if waiting > 0 {
                Label("\(waiting) needs approval", systemImage: "hand.raised.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
    }
}
