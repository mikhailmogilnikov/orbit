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
                    SessionView(session: session, focusRequest: store.focusRequest, fileIndex: store.fileIndex)
                        .id(session.id)
                } else {
                    StartSessionView(store: store)
                }
            }
        }
        .environment(\.syntaxHighlighter, store.highlighter)
        .onAppear { store.loadAgentHistory() }
        .onChange(of: store.workspace.root) { store.loadAgentHistory() }
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
                let recent = store.recent.prefix(10)
                if !recent.isEmpty {
                    Section("Recent") {
                        ForEach(recent) { saved in
                            Button {
                                store.resume(saved)
                            } label: {
                                Label(saved.title, systemImage: store.provider(for: saved)?.icon ?? "clock")
                            }
                        }
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
        case .ready, .dormant:
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
            let recent = store.recent.prefix(8)
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recent")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 2)
                    ForEach(recent) { saved in
                        RecentSessionRow(saved: saved, icon: store.provider(for: saved)?.icon ?? "clock") {
                            store.resume(saved)
                        }
                    }
                }
                .frame(maxWidth: 320)
                .padding(.top, 8)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RecentSessionRow: View {
    let saved: SavedSession
    let icon: String
    let open: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(saved.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if saved.updatedAt > .distantPast {
                    Text(saved.updatedAt, format: .relative(presentation: .named))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isHovering ? AnyShapeStyle(Theme.subtleFill) : AnyShapeStyle(.clear), in: .rect(cornerRadius: Theme.smallCorner))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(saved.title)
    }
}

// MARK: - Session

struct SessionView: View {
    let session: AgentSession
    let focusRequest: Int
    let fileIndex: ProjectFileIndex?

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
            Composer(session: session, focusRequest: focusRequest, fileIndex: fileIndex)
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
        case .ready, .dormant:
            EmptyView()
        }
    }
}

struct EntryView: View {
    let entry: TranscriptEntry

    var body: some View {
        switch entry.kind {
        case .user:
            VStack(alignment: .leading, spacing: 6) {
                if !entry.attachments.isEmpty {
                    AttachmentChips(attachments: entry.attachments)
                }
                if !entry.text.isEmpty {
                    Text(entry.text)
                        .textSelection(.enabled)
                }
            }
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
                        CompactDiffView(old: old ?? "", new: new, url: URL(fileURLWithPath: path))
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
    let fileIndex: ProjectFileIndex?
    @FocusState private var isFocused: Bool
    @State private var mentionIndex = 0
    /// Escape hides the file list until the @-word changes.
    @State private var dismissedMention: String?
    @State private var isDropTargeted = false
    @State private var selection: TextSelection?
    @State private var paste = PasteInterceptor()

    var body: some View {
        // The file list sits in the layout above the composer (which is at the
        // bottom of the panel), so it grows upward instead of off the window.
        VStack(spacing: 6) {
            if !mentionMatches.isEmpty {
                MentionList(paths: mentionMatches, selected: mentionIndex) { pick($0) }
            }
            card
        }
        .padding(10)
        .onAppear {
            isFocused = true
            paste.install(for: session)
        }
        .onDisappear { paste.remove() }
        .onChange(of: isFocused, initial: true) { paste.isActive = isFocused }
        .onChange(of: focusRequest) { isFocused = true }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !session.attachments.isEmpty {
                AttachmentChips(attachments: session.attachments) { session.detach($0) }
            }
            TextField("Ask \(session.provider.name)… (@ to add files)", text: $session.draft, selection: $selection, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...10)
                .focused($isFocused)
                .onSubmit(session.send)
                .disabled(isDisabled)
                .onKeyPress(.upArrow) { moveMention(by: -1) }
                .onKeyPress(.downArrow) { moveMention(by: 1) }
                .onKeyPress(.tab) { pickMention() }
                .onKeyPress(.return) { pickMention() }
                .onKeyPress(.escape) {
                    guard let mention = activeMention else { return .ignored }
                    dismissedMention = mention
                    return .handled
                }
                .onChange(of: activeMention) { mentionIndex = 0 }
                .onChange(of: session.draft) { old, new in attachDroppedPaths(old, new) }

            HStack(spacing: 6) {
                Menu {
                    Button("Attach Files…", systemImage: "doc.badge.plus", action: chooseFiles)
                    Button("Paste Image", systemImage: "photo.on.rectangle", action: pasteImage)
                        .disabled(!NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil))
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Attach files or images (or drop them here)")
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
                    .disabled(!session.canSend)
                    .help("Send (↩)")
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 16).strokeBorder(.tint, lineWidth: 2)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls where url.isFileURL { session.attach(.from(fileURL: url)) }
            return urls.contains { $0.isFileURL }
        } isTargeted: { isDropTargeted = $0 }
    }

    /// A file dropped on the text field itself lands as its path (the field
    /// takes the drop before we can): turn freshly inserted paths of existing
    /// files into attachments.
    private func attachDroppedPaths(_ old: String, _ new: String) {
        guard new.count > old.count else { return }
        let prefix = zip(old, new).prefix { $0.0 == $0.1 }.count
        let suffix = zip(old.reversed(), new.reversed()).prefix { $0.0 == $0.1 }.count
        let start = new.index(new.startIndex, offsetBy: prefix)
        let end = new.index(new.endIndex, offsetBy: -min(suffix, old.count - prefix))
        guard start < end else { return }
        let inserted = String(new[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard inserted.hasPrefix("/") || inserted.hasPrefix("file://") else { return }
        let candidates = FileManager.default.fileExists(atPath: Self.path(inserted)) ? [inserted]
            : inserted.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let files = candidates.map(Self.path)
        var isDirectory: ObjCBool = false
        guard !files.isEmpty, files.allSatisfy({ FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory) && !isDirectory.boolValue }) else { return }
        session.draft = String(new[..<start]) + String(new[end...])
        for file in files { session.attach(.from(fileURL: URL(fileURLWithPath: file))) }
    }

    private static func path(_ text: String) -> String {
        if text.hasPrefix("file://"), let url = URL(string: text) { return url.path }
        // Some drops escape spaces as in a shell.
        return text.replacingOccurrences(of: "\\ ", with: " ")
    }

    private var isDisabled: Bool {
        if case .failed = session.status { return true }
        return false
    }

    // MARK: @-mentions

    /// The insertion point; the end of the draft until the field reports one.
    private var caret: String.Index {
        let draft = session.draft
        guard let selection, case .selection(let range) = selection.indices, range.isEmpty,
              range.upperBound <= draft.endIndex else { return draft.endIndex }
        return range.upperBound
    }

    /// The @-word the caret is in or right after: from the @ to the caret.
    private var mentionRange: Range<String.Index>? {
        let draft = session.draft
        let caret = caret
        guard let at = draft[..<caret].lastIndex(of: "@") else { return nil }
        let query = draft[draft.index(after: at)..<caret]
        guard !query.contains(where: \.isWhitespace) else { return nil }
        if at > draft.startIndex, !draft[draft.index(before: at)].isWhitespace { return nil }
        return at..<caret
    }

    private var activeMention: String? {
        mentionRange.map { String(session.draft[$0].dropFirst()) }
    }

    private var mentionMatches: [String] {
        guard isFocused, let fileIndex, let query = activeMention, query != dismissedMention else { return [] }
        return fileIndex.search(query, limit: 8)
    }

    private func moveMention(by offset: Int) -> KeyPress.Result {
        let count = mentionMatches.count
        guard count > 0 else { return .ignored }
        mentionIndex = (mentionIndex + offset + count) % count
        return .handled
    }

    private func pickMention() -> KeyPress.Result {
        let matches = mentionMatches
        guard !matches.isEmpty else { return .ignored }
        pick(matches[min(mentionIndex, matches.count - 1)])
        return .handled
    }

    /// The @-word is replaced by the file's chip.
    private func pick(_ path: String) {
        if let range = mentionRange {
            let offset = session.draft.distance(from: session.draft.startIndex, to: range.lowerBound)
            var draft = session.draft
            draft.removeSubrange(range)
            // Don't leave two spaces where the word was.
            if offset > 0, draft.index(draft.startIndex, offsetBy: offset) < draft.endIndex,
               draft[draft.index(draft.startIndex, offsetBy: offset)] == " ",
               draft[draft.index(draft.startIndex, offsetBy: offset - 1)] == " " {
                draft.remove(at: draft.index(draft.startIndex, offsetBy: offset))
            }
            session.draft = draft
            selection = TextSelection(insertionPoint: draft.index(draft.startIndex, offsetBy: offset))
        }
        session.attach(.file(session.cwd.appendingPathComponent(path).standardizedFileURL))
        dismissedMention = nil
        isFocused = true
    }

    // MARK: Files and images

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = session.cwd
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { session.attach(.from(fileURL: url)) }
    }

    private func pasteImage() {
        let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage
        if let attachment = PromptAttachment.imageAttachment(from: image) { session.attach(attachment) }
    }
}

/// ⌘V in the composer: images and files copied in Finder become attachments.
/// The text field would paste only their names (or nothing), and SwiftUI gives
/// no hook before it, so a local key monitor catches the shortcut first.
@MainActor
final class PasteInterceptor {
    var isActive = false
    private var monitor: Any?

    func install(for session: AgentSession) {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak session] event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v",
                  let self, let session else { return event }
            let handled = MainActor.assumeIsolated {
                guard self.isActive, let attachments = PasteInterceptor.attachments(in: .general) else { return false }
                for attachment in attachments { session.attach(attachment) }
                return true
            }
            return handled ? nil : event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Nil when the pasteboard is text to paste as usual.
    static func attachments(in pasteboard: NSPasteboard) -> [PromptAttachment]? {
        let files = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !files.isEmpty {
            return files.map { PromptAttachment.from(fileURL: $0) }
        }
        // Rich text from some apps carries an image too; text wins then.
        guard pasteboard.string(forType: .string) == nil,
              pasteboard.canReadObject(forClasses: [NSImage.self], options: nil),
              let image = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
              let attachment = PromptAttachment.imageAttachment(from: image) else { return nil }
        return [attachment]
    }
}

/// File suggestions for an @-mention, shown above the composer.
struct MentionList: View {
    let paths: [String]
    let selected: Int
    let pick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(paths.enumerated()), id: \.element) { index, path in
                let folder = (path as NSString).deletingLastPathComponent
                Button { pick(path) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: FileIcon.systemImage(for: URL(fileURLWithPath: path)))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        Text((path as NSString).lastPathComponent)
                            .lineLimit(1)
                            .layoutPriority(1)
                        if !folder.isEmpty {
                            Text(folder)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(index == selected ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
}

/// Attachment chips: in the composer (removable) and on sent messages.
struct AttachmentChips: View {
    let attachments: [PromptAttachment]
    var remove: ((PromptAttachment) -> Void)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(attachments) { attachment in
                    AttachmentChip(attachment: attachment, remove: remove.map { remove in { remove(attachment) } })
                }
            }
        }
        .scrollClipDisabled()
    }
}

private struct AttachmentChip: View {
    let attachment: PromptAttachment
    let remove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            if case .image(let data, _) = attachment, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 16, height: 16)
                    .clipShape(.rect(cornerRadius: 3))
            } else {
                Image(systemName: attachment.systemImage)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Text(attachment.label)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, height: 12)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Remove")
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, remove == nil ? 7 : 4)
        .frame(height: 22)
        .background(Theme.subtleFill, in: .capsule)
        .overlay(Capsule().strokeBorder(Theme.hairline))
        .help(help)
    }

    private var help: String {
        switch attachment {
        case .file(let url): url.path
        case .selection(let selection): "\(selection.url.path), lines \(selection.lines.lowerBound)–\(selection.lines.upperBound)"
        case .image(let data, _): "Image, \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))"
        }
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
