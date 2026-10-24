import OrbitAPI
import OrbitUI
import SwiftUI

struct AgentsPanel: View {
    let store: AgentStore

    var body: some View {
        VStack(spacing: 0) {
            if store.workspace.root == nil {
                EmptyStateView("No Folder Open", systemImage: "folder", message: "Agents work inside a project folder.")
            } else if store.providers.isEmpty {
                EmptyStateView(
                    "No Agents Installed",
                    systemImage: "sparkles",
                    message: "Install Claude Code, Codex, Gemini CLI or another ACP agent to start a chat."
                ) {
                    Button("Browse Agents") { store.ui.showSettings("agents") }
                        .buttonStyle(.glassProminent)
                }
            } else {
                SessionTabs(store: store)
                Divider()
                if let session = store.selected {
                    SessionView(session: session, store: store)
                        .id(session.id)
                } else {
                    Spacer()
                }
            }
        }
        .environment(\.syntaxHighlighter, store.highlighter)
        .onAppear { store.loadAgentHistory() }
        .onChange(of: store.workspace.root) { store.loadAgentHistory() }
    }
}

/// Agent tabs in the window's top row, the same height and look as the editor's.
struct SessionTabs: View {
    let store: AgentStore

    var body: some View {
        HStack(spacing: 4) {
            // Measured outside the scroll view: on it, the min width below fed back into its size (D103).
            GeometryReader { geometry in
                let width = geometry.size.width
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            ForEach(store.sessions) { session in
                                // Closing the only, empty chat would just open another one.
                                let isClosable = !(store.sessions.count == 1 && session.isEmptyChat)
                                SessionChip(
                                    session: session,
                                    isSelected: store.selectedID == session.id,
                                    // One chat is a title, not a tab; tabs start with the second (D174).
                                    isTitle: store.sessions.count == 1,
                                    onSelect: { store.selectedID = session.id },
                                    onClose: isClosable ? { store.close(session) } : nil
                                )
                                .id(session.id)
                            }
                        }
                        .padding(.horizontal, 8)
                        // Free space in the row is title bar: it drags the window.
                        .frame(minWidth: width, maxHeight: .infinity, alignment: .leading)
                        .background {
                            Color.clear
                                .contentShape(.rect)
                                .gesture(WindowDragGesture())
                        }
                    }
                    .modifier(TabRowFade())
                    .scrollsToActiveTab(store.selectedID, in: proxy, width: width)
                }
            }
            Menu {
                Button("New Chat", systemImage: "plus.bubble") { store.newChat() }
                Button("New Isolated Chat", systemImage: "square.on.square.dashed") { store.newChat(isolated: true) }
                let recent = store.recent.prefix(10)
                if !recent.isEmpty {
                    Section("Recent") {
                        ForEach(recent) { saved in
                            Button {
                                store.resume(saved)
                            } label: {
                                AgentLabel(title: saved.title, provider: store.provider(for: saved))
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "plus")
                    .orbitFont(.control, weight: .medium)
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            } primaryAction: {
                store.newChat()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New chat (⇧⌘N); hold for more")
        }
        .padding(.trailing, 8)
        .frame(height: Theme.topBarHeight)
    }
}

struct SessionChip: View {
    let session: AgentSession
    let isSelected: Bool
    var isTitle = false
    let onSelect: () -> Void
    let onClose: (() -> Void)?

    var body: some View {
        Group {
            if isTitle {
                HStack(spacing: 6) {
                    icons.orbitFont(.micro)
                    Text(session.title)
                        .orbitFont(.body, weight: .medium)
                        .lineLimit(1)
                }
                .padding(.horizontal, 6)
                .frame(height: 26)
                .contextMenu {
                    if let onClose { Button("Close Chat", action: onClose) }
                }
            } else {
                TabChip(session.title, isActive: isSelected, onSelect: onSelect, onClose: onClose) { icons }
            }
        }
        .help(session.title)
    }

    private var icons: some View {
        HStack(spacing: 4) {
            statusIcon
            if session.isIsolated {
                Image(systemName: "square.on.square.dashed")
                    .orbitFont(.micro, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .help("Works in an isolated copy of the project")
            }
        }
    }

    @ViewBuilder private var statusIcon: some View {
        if session.status == .working {
            ProgressView().controlSize(.mini)
        } else if session.hasFailed {
            Circle().fill(.red).frame(width: 6, height: 6).frame(width: 13)
        } else if session.hasPendingPermission {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
                // A nudge every few seconds: this chat waits for you.
                .symbolEffect(.wiggle, options: .repeat(.periodic(delay: 3)))
                .frame(width: 13)
        } else {
            AgentIcon(provider: session.provider, size: 13)
                .foregroundStyle(.secondary)
        }
    }
}

/// What the composer can take, for a chat nothing was sent in yet.
struct ComposerHints: View {
    private static let hints: [(key: String, text: String)] = [
        ("@", "attach a file"),
        ("/", "the agent's commands"),
        ("⌘L", "add the editor's selection"),
        ("⌘V", "paste an image or files"),
    ]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            ForEach(Self.hints, id: \.key) { hint in
                GridRow {
                    Text(hint.key)
                        .orbitFont(.caption, weight: .medium)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.tinyCorner))
                        .overlay(RoundedRectangle(cornerRadius: Theme.tinyCorner).strokeBorder(Theme.hairline))
                        .gridColumnAlignment(.trailing)
                    Text(hint.text)
                        .orbitFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .fixedSize()
    }
}

/// What an empty chat shows above the composer: earlier conversations to pick up.
struct NewChatView: View {
    let session: AgentSession
    let store: AgentStore
    @State private var showsAll = false

    var body: some View {
        let all = store.recent
        let recent = showsAll ? all[...] : all.prefix(15)
        GeometryReader { geometry in
            let width = geometry.size.width
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if session.hasFailed {
                        StatusFooter(session: session)
                    }
                    if recent.isEmpty {
                        VStack(spacing: 8) {
                            OrbitMark()
                                .frame(width: 36, height: 36)
                                .foregroundStyle(.primary.opacity(0.85))
                                .padding(.bottom, 4)
                            Text("What should we build?")
                                .orbitFont(.title, weight: .semibold)
                            Text("Edits show up inline in the editor for review.")
                                .orbitFont(.body)
                                .foregroundStyle(.secondary)
                            ComposerHints()
                                .padding(.top, 14)
                        }
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Recent")
                                .orbitFont(.micro, weight: .semibold)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.bottom, 4)
                            ForEach(recent) { saved in
                                RecentSessionRow(saved: saved, provider: store.provider(for: saved)) {
                                    store.resume(saved)
                                }
                            }
                            if all.count > recent.count {
                                Button("Show \(all.count - recent.count) More") { showsAll = true }
                                    .buttonStyle(.plain)
                                    .orbitFont(.body)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 12)
                // A width the scroller coming and going doesn't change (D245).
                .frame(width: SteadyScroll.contentWidth(in: width), alignment: .leading)
            }
        }
    }
}

struct RecentSessionRow: View {
    let saved: SavedSession
    let provider: AgentProvider?
    let open: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Group {
                    if let provider {
                        AgentIcon(provider: provider, size: 13)
                    } else {
                        Image(systemName: "clock").orbitFont(.micro, weight: .semibold)
                    }
                }
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
            .orbitFont(.body)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isHovering ? Theme.hoverFill : .clear, in: .capsule)
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
    let store: AgentStore
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if session.isEmptyChat && session.entries.isEmpty {
                NewChatView(session: session, store: store)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else if session.isLoadingHistory {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TranscriptView(session: session)
            }
            if let plan = session.pinnedPlan {
                PinnedPlanView(items: plan)
            }
            if let waiting = store.sessions.first(where: { $0.id != session.id && $0.hasPendingPermission }) {
                WaitingSessionBar(session: waiting) { store.selectedID = waiting.id }
            }
            ReviewCommentsBar(store: store)
            if session.isIsolated {
                IsolationBar(session: session)
            } else if let changes = store.changes {
                ChangesBarSlot(changes: changes, store: store)
            }
            Composer(session: session, store: store)
        }
        // The chat's own text size (D181), else the interface's.
        .orbitTextSize(Preferences.shared.effectiveChatTextSize)
        // Files and editor tabs dropped anywhere on the chat attach (D91).
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            for url in files { session.attach(.from(fileURL: url)) }
            return !files.isEmpty
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: Theme.panelCorner)
                    .fill(Theme.dropFill)
                    .strokeBorder(Theme.dropBorder, lineWidth: 1.5)
                    .overlay {
                        Label("Add to Chat", systemImage: "paperclip")
                            .orbitFont(.body, weight: .medium)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .glassEffect(.regular, in: .capsule)
                    }
                    .padding(8)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.15), value: isDropTargeted)
    }
}

/// The transcript's scroll view. Its own view, with no scroll state bound to
/// it: a binding the scroll view writes on every frame (`scrollPosition`)
/// re-ran the whole chat's body while scrolling and made long chats lag.
struct TranscriptView: View {
    let session: AgentSession
    @State private var isAtBottom = true
    private static let bottomID = "transcript-bottom"

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        TranscriptRows(session: session)
                        StatusFooter(session: session)
                        Color.clear.frame(height: 1).id(Self.bottomID)
                    }
                    // Replies' prose had the system's 13 pt; now it follows the chat's size.
                    .orbitFont(.control)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    // A width the scroller coming and going doesn't change (D245).
                    .frame(width: SteadyScroll.contentWidth(in: geometry.size.width), alignment: .leading)
                }
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                // Follow new output only from the bottom; scrolled up, what you read stays put.
                .defaultScrollAnchor(isAtBottom ? .bottom : .top, for: .sizeChanges)
                // Runs per frame but only yields a Bool: the action fires when it flips.
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 60
                } action: { _, atBottom in
                    isAtBottom = atBottom
                }
                .overlay(alignment: .bottom) {
                    JumpToLatestButton(isVisible: !isAtBottom) {
                        withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    }
                }
                .environment(\.keyedPermission, session.firstPendingPermission.map(ObjectIdentifier.init))
            }
        }
    }
}

/// The rows alone, so the scroll view's own state never rebuilds them.
private struct TranscriptRows: View {
    let session: AgentSession

    var body: some View {
        let replies = TranscriptRow.replies(session.entries, isWorking: session.status == .working)
        ForEach(TranscriptRow.rows(session.entries)) { row in
            switch row {
            case .entry(let entry): EntryView(entry: entry, session: session, reply: replies[entry.id])
            case .group(let entries): ToolGroupView(entries: entries, reveal: session.reveal)
            }
        }
    }
}

private struct JumpToLatestButton: View {
    let isVisible: Bool
    let action: () -> Void

    var body: some View {
        Group {
            if isVisible {
                Button(action: action) {
                    Image(systemName: "arrow.down")
                        .orbitFont(.body, weight: .semibold)
                        .frame(width: 26, height: 26)
                        .contentShape(.circle)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("Jump to the latest")
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.snappy(duration: 0.15), value: isVisible)
    }
}

/// The changed-files bar, in a view of its own: reading `changedFiles`
/// (a disk check per file) stays out of the chat's body.
private struct ChangesBarSlot: View {
    let changes: ChangeTracking
    let store: AgentStore

    var body: some View {
        if !changes.changedFiles.isEmpty {
            AgentChangesBar(changes: changes, store: store)
        }
    }
}

/// State of an isolated session's copy, with Apply.
struct IsolationBar: View {
    let session: AgentSession
    @State private var isCreatingPullRequest = false
    @State private var pushFailure: String?

    var body: some View {
        let count = session.unappliedChanges.count
        HStack(spacing: 8) {
            Image(systemName: "square.on.square.dashed")
                .foregroundStyle(.secondary)
            Group {
                if session.isolatedCopy == nil {
                    Text("Making an isolated copy…")
                } else if count == 0 {
                    Text("Isolated copy · no changes to apply")
                } else {
                    Text("Isolated copy · \(count) file\(count == 1 ? "" : "s") changed")
                        .help(session.unappliedChanges.map(\.lastPathComponent).joined(separator: "\n"))
                }
            }
            .orbitFont(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            Spacer(minLength: 4)
            if let copy = session.isolatedCopy {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([copy.directory])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Show the copy in Finder")
            }
            if let url = session.isolatedCopy?.pullRequest {
                PullRequestBadge(session: session, url: url)
                if session.unpushedChanges > 0, session.pullRequestStatus?.state != .merged, session.pullRequestStatus?.state != .closed {
                    Button(session.isPushing ? "Pushing…" : "Push \(session.unpushedChanges)") {
                        Task {
                            do { try await session.pushToPullRequest() } catch { pushFailure = error.localizedDescription }
                        }
                    }
                    .buttonStyle(.glass)
                    .disabled(session.isPushing || session.status == .working)
                    .help(session.status == .working
                        ? "Wait for the agent to finish"
                        : "Commit the \(session.unpushedChanges) file\(session.unpushedChanges == 1 ? "" : "s") changed since the last push and push them to the pull request")
                }
            } else if session.isolatedCopy != nil {
                Button("Create PR") { isCreatingPullRequest = true }
                    .buttonStyle(.glass)
                    .disabled(session.status == .working)
                    .help(session.status == .working ? "Wait for the agent to finish" : "Commit the agent's changes in the copy to a new branch and open a GitHub pull request")
            }
            Button(session.isApplying ? "Applying…" : "Apply") { session.applyIsolatedChanges() }
                .buttonStyle(.glassProminent)
                .disabled(count == 0 || session.isApplying || session.status == .working)
                .help(session.status == .working ? "Wait for the agent to finish" : "Bring these changes into the project for review")
        }
        .sheet(isPresented: $isCreatingPullRequest) {
            CreatePullRequestSheet(session: session)
        }
        .alert("Couldn't push to the pull request", isPresented: Binding { pushFailure != nil } set: { if !$0 { pushFailure = nil } }) {
            Button("OK") {}
        } message: {
            Text(pushFailure ?? "")
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .overlay(alignment: .top) { Divider() }
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
                    .shimmer()
            }
            .orbitFont(.body)
        case .working:
            if !session.hasPendingPermission {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(TurnActivity.describe(session.entries) + "…")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .shimmer()
                    if let start = session.turnStartedAt {
                        Text(timerInterval: start...Date.distantFuture, countsDown: false)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                    }
                }
                .orbitFont(.body)
            }
        case .failed(let message):
            Label {
                Text(message).textSelection(.enabled)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .orbitFont(.body)
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
    let session: AgentSession
    var reply: [TranscriptEntry]?

    var body: some View {
        switch entry.kind {
        case .user:
            UserMessageView(entry: entry, session: session)
        case .agent:
            AgentMessageView(entry: entry, reply: reply)
        case .thought:
            ThoughtView(entry: entry)
        case .tool:
            ToolCallRow(entry: entry, reveal: session.reveal)
        case .plan:
            PlanView(items: entry.plan)
        case .notice:
            Text(entry.text)
                .orbitFont(.body)
                .foregroundStyle(entry.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .textSelection(.enabled)
        case .summary:
            TurnSummaryView(entry: entry, tracker: session.reviewTracker)
        }
    }
}

/// The end of a long turn or one that changed files: how long it took and
/// what's left to review from it, with the way into the inline review.
struct TurnSummaryView: View {
    let entry: TranscriptEntry
    let tracker: ChangeTracking?
    @State private var isExpanded = false

    var body: some View {
        let files = entry.changedFiles
        let pending = files.filter { tracker?.hasChanges($0) == true }
        let stats = pending.compactMap { tracker?.stats(for: $0) }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.added)
                Text("Worked for \(Self.format(entry.duration))")
                    .lineLimit(1)
                if !files.isEmpty {
                    Text("·").foregroundStyle(.tertiary)
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text("\(files.count) file\(files.count == 1 ? "" : "s") changed")
                                .contentTransition(.numericText(value: Double(files.count)))
                                .animation(.snappy, value: files.count)
                                .lineLimit(1)
                            DisclosureChevron(isExpanded: isExpanded)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "Hide the files" : "Show the files")
                    if !pending.isEmpty {
                        DiffStatBadge(added: stats.reduce(0) { $0 + $1.added }, removed: stats.reduce(0) { $0 + $1.removed })
                    }
                    Spacer(minLength: 4)
                    if let first = pending.first {
                        Button("Review") { tracker?.openReview(for: first) }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                            .help("Open the first change of this turn")
                    } else {
                        Text("Reviewed")
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .orbitFont(.body)
            .foregroundStyle(.secondary)
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(files, id: \.self) { url in
                        TurnFileRow(url: url, tracker: tracker)
                    }
                }
                .transition(.opacity)
            }
        }
    }

    /// "2m 5s". By hand so tests get it too: outside the app bundle the system formatter speaks the Mac's language (D211).
    nonisolated static func format(_ duration: TimeInterval) -> String {
        let total = max(1, Int(duration.rounded()))
        let hours = total / 3600, minutes = total % 3600 / 60, seconds = total % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
    }
}

private struct TurnFileRow: View {
    let url: URL
    let tracker: ChangeTracking?
    @State private var isHovering = false

    var body: some View {
        let isPending = tracker?.hasChanges(url) == true
        Button {
            tracker?.openReview(for: url)
        } label: {
            HStack(spacing: 6) {
                FileIconView(url: url, size: 13)
                Text(url.lastPathComponent)
                    .lineLimit(1)
                Text(url.deletingLastPathComponent().lastPathComponent)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isPending, let stats = tracker?.stats(for: url) {
                    DiffStatBadge(added: stats.added, removed: stats.removed)
                } else {
                    Text("Reviewed").foregroundStyle(.tertiary)
                }
            }
            .orbitFont(.body)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(isHovering && isPending ? Theme.hoverFill : .clear, in: .capsule)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isPending)
        .onHover { isHovering = $0 }
        .help(url.path)
    }
}

/// An agent message. The last one of a finished turn has Copy under it on
/// hover, for the whole reply's Markdown source (D230).
struct AgentMessageView: View {
    let entry: TranscriptEntry
    var reply: [TranscriptEntry]?
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            MarkdownText(entry.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let reply {
                MessageActions(isVisible: isHovering) {
                    CopyMessageButton(help: "Copy the reply") {
                        reply.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
                    }
                }
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
    }
}

/// A message's actions in a quiet row under it, as in chat apps (D209): gray
/// icons that show on hover; the row keeps its height so nothing jumps.
private struct MessageActions<Content: View>: View {
    let isVisible: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 2) { content }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
    }
}

private struct MessageActionIcon: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .contentTransition(.symbolEffect(.replace))
            .orbitFont(.caption, weight: .medium)
            .frame(width: 20, height: 20)
            .contentShape(.rect)
    }
}

private struct CopyMessageButton: View {
    let help: String
    let text: () -> String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text(), forType: .string)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
        } label: {
            MessageActionIcon(systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .help(help)
        .accessibilityLabel(spokenName(help))
    }
}

/// Messages written while the agent works (D88), sent one by one as its turns end.
struct QueuedMessagesView: View {
    let session: AgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if session.isQueuePaused {
                Text("Queue paused: Send Now to go on")
                    .orbitFont(.micro)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            ForEach(session.queue) { message in
                HStack(spacing: 8) {
                    Image(systemName: "clock")
                        .orbitFont(.micro)
                        .foregroundStyle(.secondary)
                    Text(message.text.isEmpty ? message.attachments.map(\.label).joined(separator: ", ") : message.text)
                        .orbitFont(.body)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 2) {
                        Button("Send Now", systemImage: "arrow.up") { session.sendQueuedNow(message.id) }
                            .help(session.status == .working ? "Stop the current turn and send this" : "Send now")
                        Button("Edit", systemImage: "pencil") { session.editQueued(message.id) }
                            .help("Edit in the composer")
                            .disabled(!session.draft.isEmpty || !session.attachments.isEmpty)
                        Button("Remove", systemImage: "xmark") { session.removeQueued(message.id) }
                            .help("Remove from the queue")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .orbitFont(.micro, weight: .semibold)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.corner))
            }
        }
    }
}

struct UserMessageView: View {
    let entry: TranscriptEntry
    let session: AgentSession
    @State private var isHovering = false
    @State private var isConfirming = false

    /// A bubble on the right, like Claude Code, so each turn's start is easy to find.
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            VStack(alignment: .leading, spacing: 6) {
                if !entry.attachments.isEmpty {
                    AttachmentChips(attachments: entry.attachments)
                }
                // Replayed prompts end in a newline, an empty last line in the bubble.
                let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    Text(text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.tint.opacity(0.16), in: .rect(cornerRadius: Theme.largeCorner))
            .padding(.leading, 40)
            MessageActions(isVisible: isHovering || isConfirming) {
                let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    CopyMessageButton(help: "Copy the message") { text }
                }
                if entry.checkpoint != nil {
                    let help = session.canRestore ? "Go back to before this message: chat and files" : "Wait for the agent to finish"
                    Button { isConfirming = true } label: {
                        MessageActionIcon(systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!session.canRestore)
                    .help(help)
                    .accessibilityLabel("Go back to before this message")
                }
            }
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .confirmationDialog("Go back to before this message?", isPresented: $isConfirming) {
            Button("Rewind Chat and Files") { session.rewind(to: entry) }
            Button("Restore Files Only") { session.restore(to: entry) }
        } message: {
            Text("Changes made since, by the agent or by you, are undone; they show as changes in the editor, so any of them can be brought back. Rewinding also takes this message and what followed out of the chat and puts the message back in the composer to edit.")
        }
    }
}

struct ThoughtView: View {
    let entry: TranscriptEntry
    @State private var isExpanded = false

    private var label: String { ThoughtLabel.text(startedAt: entry.startedAt, endedAt: entry.endedAt) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "brain")
                    Text(label)
                    DisclosureChevron(isExpanded: isExpanded)
                }
                .orbitFont(.micro, weight: .medium)
                .foregroundStyle(.secondary)
                .shimmer(entry.startedAt != nil && entry.endedAt == nil)
            }
            .buttonStyle(.plain)
            if isExpanded {
                Text(entry.text)
                    .orbitFont(.body)
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

/// The plan in the transcript: one line ("Plan · 3 of 7 done") that expands;
/// the live list is pinned above the composer (`PinnedPlanView`).
struct PlanView: View {
    let items: [PlanItem]
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "list.bullet.clipboard")
                    Text("Plan · \(PlanItem.progress(items))")
                    DisclosureChevron(isExpanded: isExpanded)
                }
                .orbitFont(.micro, weight: .medium)
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if isExpanded {
                PlanItemsList(items: items)
                    .padding(.leading, 2)
            }
        }
    }
}

struct PlanItemsList: View {
    let items: [PlanItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: Self.icon(item.status))
                        .foregroundStyle(item.status == "completed" ? AnyShapeStyle(.green) : item.status == "in_progress" ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .orbitFont(.micro)
                    Text(item.content)
                        .orbitFont(.body, weight: item.status == "in_progress" ? .medium : .regular)
                        .strikethrough(item.status == "completed", color: .secondary)
                        .foregroundStyle(item.status == "completed" ? .secondary : .primary)
                }
            }
        }
    }

    static func icon(_ status: String) -> String {
        switch status {
        case "completed": "checkmark.circle.fill"
        case "in_progress": "circle.dotted.circle"
        default: "circle"
        }
    }
}

/// The running turn's plan above the composer, like Claude Code's task list:
/// the step in progress when folded, every step when open.
struct PinnedPlanView: View {
    let items: [PlanItem]
    @State private var isExpanded = true

    var body: some View {
        let current = items.first { $0.status == "in_progress" } ?? items.first { $0.status != "completed" }
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    DisclosureChevron(isExpanded: isExpanded)
                        .foregroundStyle(.secondary)
                    Text("Plan")
                        .orbitFont(.caption, weight: .medium)
                    Text(PlanItem.progress(items))
                        .orbitFont(.caption)
                        .foregroundStyle(.secondary)
                    if !isExpanded, let current {
                        Text(current.content)
                            .orbitFont(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Fold the plan" : "Show the whole plan")
            if isExpanded {
                ScrollView {
                    PlanItemsList(items: items)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // About eight steps, then it scrolls; the transcript keeps the space.
                .frame(maxHeight: 170)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 15)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .overlay(alignment: .top) { Divider() }
    }
}

/// A tool call as one quiet line ("Read Transcript.swift ›") that opens into
/// its details, like Claude Code; framed only while it asks for permission.
struct ToolCallRow: View {
    let entry: TranscriptEntry
    /// Opens a file the call touched in the editor.
    var reveal: ((String) -> Void)?
    /// A line in a group's frame, padded like its neighbours.
    var inGroup = false
    @State private var isExpanded: Bool?

    var body: some View {
        let expanded = isExpanded ?? defaultExpanded
        let asking = entry.permission?.isPending == true
        let inset: CGFloat = inGroup || asking ? 10 : 0
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { isExpanded = !expanded }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: Self.symbol(for: entry.toolKind))
                        .orbitFont(.caption, weight: .medium)
                        .foregroundStyle(entry.status == "failed" ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
                        .frame(width: 14)
                    Text(Self.styledTitle(entry.title.isEmpty ? entry.toolKind.capitalized : entry.title))
                        .orbitFont(.body)
                        .foregroundStyle(asking ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .shimmer(entry.isRunning && !asking)
                    if hasDetails {
                        DisclosureChevron(isExpanded: expanded)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 4)
                    if let resolution = entry.permission?.resolution {
                        Text(resolution)
                            .orbitFont(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    if let stats = diffStats {
                        DiffStatBadge(added: stats.added, removed: stats.removed)
                    }
                    statusIcon
                }
                .padding(.horizontal, inset)
                .padding(.vertical, inset > 0 ? 7 : 1)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if expanded && hasDetails {
                // In a group the group's card is the box; alone the details get one (D163).
                details
                    .background(inGroup ? Color.clear : Theme.subtleFill, in: .rect(cornerRadius: Theme.smallCorner))
                    .padding(.leading, inGroup ? inset + 12 : inset)
                    .padding(.trailing, inset)
                    .padding(.top, inGroup ? 0 : 2)
                    .padding(.bottom, inset > 0 ? 8 : 2)
            }

            if let permission = entry.permission, permission.isPending {
                Divider().opacity(0.6)
                PermissionBar(request: permission)
            }
        }
        .background(asking ? AnyShapeStyle(Theme.subtleFill) : AnyShapeStyle(.clear), in: .rect(cornerRadius: Theme.corner))
        .overlay {
            if asking {
                RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(.orange.opacity(0.6))
            }
        }
    }

    /// What kind of step it was, at a glance: ACP's tool kinds.
    static func symbol(for kind: String) -> String {
        switch kind {
        case "read": "doc.text"
        case "edit": "pencil"
        case "delete": "trash"
        case "move": "arrow.right.doc.on.clipboard"
        case "search": "magnifyingglass"
        case "execute": "terminal"
        case "think": "brain"
        case "fetch": "globe"
        case "switch_mode": "arrow.triangle.2.circlepath"
        default: "wrench.and.screwdriver"
        }
    }

    /// Live commands stay open while they run and when they fail.
    private var defaultExpanded: Bool {
        if let terminal = entry.terminal, terminal.exitStatus?.succeeded != true { return true }
        return entry.permission?.isPending == true
    }

    /// Summed over the call's diffs; nil when it has none.
    private var diffStats: (added: Int, removed: Int)? {
        var total: (added: Int, removed: Int)?
        for content in entry.contents {
            guard case .diff(_, let old, let new) = content else { continue }
            let stats = CompactDiffView.stats(old: old ?? "", new: new)
            total = ((total?.added ?? 0) + stats.added, (total?.removed ?? 0) + stats.removed)
        }
        return total
    }

    private var hasDetails: Bool { entry.hasDetails }

    /// Code in backticks ("Run `make build`") in code type and full color,
    /// so the command stands out of the gray line.
    static func styledTitle(_ title: String) -> AttributedString {
        var result = AttributedString()
        for (index, part) in title.split(separator: "`", omittingEmptySubsequences: false).enumerated() where !part.isEmpty {
            var run = AttributedString(part)
            if index % 2 == 1 {
                run.font = .orbit(.code)
                run.foregroundColor = .primary
            }
            result += run
        }
        return result
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let command = entry.shownCommand {
                HighlightedCode(command, language: "bash")
                    .orbitFont(.code)
                    .textSelection(.enabled)
                    .lineLimit(6)
            }
            ForEach(entry.shownTexts, id: \.self) { text in
                HighlightedCode(text.code, language: text.language)
                    .orbitFont(.code)
                    .foregroundStyle(.secondary)
                    .lineLimit(20)
                    .textSelection(.enabled)
            }
            ForEach(entry.contents) { content in
                switch content {
                case .text:
                    EmptyView()
                case .diff(let path, let old, let new):
                    VStack(alignment: .leading, spacing: 4) {
                        DiffFileLink(path: path, reveal: reveal)
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
                        .orbitFont(.caption, design: .monospaced)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .defaultScrollAnchor(.bottom)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var statusIcon: some View {
        switch entry.status {
        case "completed":
            EmptyView()
        case "failed":
            Image(systemName: "xmark").orbitFont(.micro, weight: .bold).foregroundStyle(.red)
        default:
            if entry.permission?.isPending == true {
                Image(systemName: "hand.raised.fill").orbitFont(.micro).foregroundStyle(.orange)
            } else {
                ProgressView().controlSize(.mini)
            }
        }
    }
}

/// Another chat waits for a permission: shown above this chat's composer, so
/// it isn't missed while you read this one.
struct WaitingSessionBar: View {
    let session: AgentSession
    let show: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
            Text("\(session.title) needs approval")
                .orbitFont(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button("Show", action: show)
                .buttonStyle(.glass)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.06))
        .overlay(alignment: .top) { Divider() }
    }
}

/// The file name over a tool card's diff; a click opens it in the editor.
private struct DiffFileLink: View {
    let path: String
    let reveal: ((String) -> Void)?
    @State private var isHovering = false

    var body: some View {
        let name = Text(URL(fileURLWithPath: path).lastPathComponent)
            .orbitFont(.micro, weight: .medium)
        if let reveal {
            Button { reveal(path) } label: {
                HStack(spacing: 3) {
                    name.underline(isHovering)
                    Image(systemName: "arrow.up.forward")
                        .orbitFont(.glyph, weight: .semibold)
                        .opacity(isHovering ? 1 : 0)
                }
                .foregroundStyle(isHovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .help("Open in the editor")
        } else {
            name.foregroundStyle(.secondary)
        }
    }
}

/// A run of tool calls as one line ("Ran 4 commands ›") that opens into a
/// framed list of them, like Claude Code.
struct ToolGroupView: View {
    let entries: [TranscriptEntry]
    var reveal: ((String) -> Void)?
    @State private var isExpanded = false

    var body: some View {
        let running = entries.last { $0.kind == .tool && $0.isRunning }
        let failed = entries.count { $0.kind == .tool && $0.status == "failed" }
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(TranscriptRow.summary(entries))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    DisclosureChevron(isExpanded: isExpanded)
                        .foregroundStyle(.tertiary)
                    if failed > 0 {
                        Text("\(failed) failed")
                            .foregroundStyle(.red)
                    }
                    if !isExpanded, let running {
                        Text(running.plainTitle)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .shimmer()
                    }
                    Spacer(minLength: 0)
                }
                .orbitFont(.body)
                .padding(.vertical, 1)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide the steps" : "Show the steps")

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider().opacity(0.6) }
                        if entry.kind == .thought {
                            ThoughtView(entry: entry)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                        } else {
                            ToolCallRow(entry: entry, reveal: reveal, inGroup: true)
                        }
                    }
                }
                .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.corner, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).strokeBorder(Theme.hairline))
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
                        .orbitFont(.caption, design: .monospaced)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .defaultScrollAnchor(.bottom)
            }
            HStack(spacing: 6) {
                // A clean exit says nothing: the output is the result (D163).
                if let status {
                    Text(status)
                        .orbitFont(.micro)
                        .foregroundStyle(isFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                }
                Spacer(minLength: 4)
                if terminal.isRunning, terminal.ownsProcess {
                    Button("Stop") { terminal.kill() }
                        .buttonStyle(.glass)
                }
                IconButton("macwindow", help: "Show in Terminal") { terminal.reveal() }
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

    private var status: String? {
        guard let exit = terminal.exitStatus else { return "Running…" }
        if let code = exit.exitCode { return code == 0 ? nil : "Exited with code \(code)" }
        if let signal = exit.signal { return "Stopped (\(signal))" }
        return "Ended"
    }
}

extension EnvironmentValues {
    /// The permission request in view that the keyboard answers (one per chat, the oldest).
    @Entry var keyedPermission: ObjectIdentifier?
}

struct PermissionBar: View {
    let request: PermissionRequest
    @Environment(\.keyedPermission) private var keyedPermission

    var body: some View {
        let keyed = keyedPermission == ObjectIdentifier(request)
        HStack(spacing: 6) {
            Text("Allow?")
                .orbitFont(.micro, weight: .semibold)
                .foregroundStyle(.orange)
            Spacer(minLength: 0)
            ForEach(request.options.sorted { rank($0) < rank($1) }) { option in
                let key = keyed ? Self.shortcut(for: option.kind) : nil
                let help = key.map { "\(option.name) (\(Self.label(for: $0)))" } ?? option.name
                if option.kind == "allow_once" {
                    Button(option.name) { request.choose(option) }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(key)
                        .help(help)
                } else {
                    Button(option.name) { request.choose(option) }
                        .buttonStyle(.glass)
                        .keyboardShortcut(key)
                        .help(help)
                }
            }
        }
        .controlSize(.small)
        .padding(8)
    }

    /// ⌘↩ allows once; the rest take ⌃⌘, clear of the review's ⌥⌘ / ⇧⌘ keys and of ⌘⌫ (Move to Trash).
    static func shortcut(for kind: String) -> KeyboardShortcut? {
        switch kind {
        case "allow_once": KeyboardShortcut(.return, modifiers: .command)
        case "allow_always": KeyboardShortcut(.return, modifiers: [.control, .command])
        case "reject_once": KeyboardShortcut(.delete, modifiers: [.control, .command])
        default: nil
        }
    }

    private static func label(for shortcut: KeyboardShortcut) -> String {
        (shortcut.modifiers.contains(.control) ? "⌃" : "") + "⌘" + (shortcut.key == .return ? "↩" : "⌫")
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
    let store: AgentStore
    /// macOS 26's glass is clearer: over the inspector's own glass the
    /// composer all but vanished into the panel (D241).
    private static var glassFill: Color {
        if #unavailable(macOS 27) { Theme.activeFill } else { .clear }
    }
    private var focusRequest: Int { store.focusRequest }
    private var fileIndex: ProjectFileIndex? { store.fileIndex }
    @FocusState private var isFocused: Bool
    @State private var mentionIndex = 0
    /// Escape hides the file or command list until its word changes ("@word", "/word").
    @State private var dismissedWord: String?
    @State private var isDropTargeted = false
    @State private var selection: TextSelection?
    @State private var paste = PasteInterceptor()
    @State private var scroller = ComposerScroller()
    /// Where ↑ / ↓ are in the sent messages; nil while typing your own.
    @State private var historyIndex: Int?

    var body: some View {
        // The file list sits in the layout above the composer (which is at the
        // bottom of the panel), so it grows upward instead of off the window.
        VStack(spacing: 6) {
            if !commandMatches.isEmpty {
                CommandList(commands: commandMatches, selected: mentionIndex) { pick($0) }
            } else if !mentionMatches.isEmpty {
                MentionList(paths: mentionMatches, selected: mentionIndex) { pick($0) }
            } else if !session.queue.isEmpty {
                QueuedMessagesView(session: session)
            }
            card
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .onAppear {
            isFocused = true
            paste.install(for: session)
            scroller.install()
        }
        .onDisappear {
            paste.remove()
            scroller.remove()
        }
        .onChange(of: isFocused, initial: true) {
            paste.isActive = isFocused
            scroller.isActive = isFocused
            // Another window's composer keeps its focus too (D101): only this window's paste counts.
            if isFocused {
                paste.window = NSApp.keyWindow
                scroller.window = NSApp.keyWindow
            }
        }
        .onChange(of: focusRequest) { isFocused = true }
        .onChange(of: session.awaitsCorrection) { if session.awaitsCorrection { isFocused = true } }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !session.attachments.isEmpty {
                AttachmentChips(attachments: session.attachments) { session.detach($0) }
            }
            TextField(placeholder, text: $session.draft, selection: $selection, axis: .vertical)
                .textFieldStyle(.plain)
                .orbitFont(.control)
                .lineLimit(1...10)
                .focused($isFocused)
                .onSubmit(session.submit)
                .disabled(isDisabled)
                .onKeyPress(.upArrow) { moveSuggestion(by: -1) == .handled ? .handled : recall(by: 1) }
                .onKeyPress(.downArrow) { moveSuggestion(by: 1) == .handled ? .handled : recall(by: -1) }
                // ⇧Tab arrives as backtab.
                .onKeyPress(keys: [.tab, KeyEquivalent("\u{19}")]) { press in
                    if press.modifiers.contains(.shift) || press.key == KeyEquivalent("\u{19}") {
                        return session.cycleMode() ? .handled : .ignored
                    }
                    return pickSuggestion()
                }
                // ⇧↩ would submit too (only ⌥↩ breaks a line in a text field).
                .onKeyPress(.return, phases: .down) { press in
                    press.modifiers.contains(.shift) ? insertLineBreak() : pickSuggestion()
                }
                .onKeyPress(.escape) {
                    if !commandMatches.isEmpty, let command = activeCommand {
                        dismissedWord = "/" + command
                    } else if let mention = activeMention {
                        dismissedWord = "@" + mention
                    } else if session.status == .working {
                        session.stop()
                    } else {
                        return .ignored
                    }
                    return .handled
                }
                .onChange(of: session.draft) {
                    if let index = historyIndex, session.promptHistory.indices.contains(index), session.draft != session.promptHistory[index] {
                        historyIndex = nil
                    }
                }
                .onChange(of: activeMention) { mentionIndex = 0 }
                .onChange(of: activeCommand) { mentionIndex = 0 }
                .onChange(of: session.draft) { old, new in attachDroppedPaths(old, new) }

            HStack(spacing: 6) {
                Menu {
                    Button("Attach Files…", systemImage: "doc.badge.plus", action: chooseFiles)
                    Button("Paste Image", systemImage: "photo.on.rectangle", action: pasteImage)
                        .disabled(!NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil))
                } label: {
                    Image(systemName: "plus")
                        .orbitFont(.body, weight: .semibold)
                        .frame(width: 18, height: 18)
                }
                // A round "+" like Messages and Apple Intelligence (D163).
                .menuStyle(.button)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.small)
                .tint(nil)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Attach files or images (or drop them here)")
                SessionOptionsButton(session: session, store: store)
                Spacer()
                if !session.usage.isEmpty {
                    UsageButton(session: session)
                }
                if session.status == .working {
                    Button(action: session.stop) {
                        Image(systemName: "stop.fill")
                            .orbitFont(.micro, weight: .bold)
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .controlSize(.small)
                    .tint(.primary)
                    .help("Stop (⌘.)")
                } else {
                    Button(action: session.send) {
                        Image(systemName: "arrow.up")
                            .orbitFont(.body, weight: .bold)
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .controlSize(.small)
                    .disabled(!session.canSend)
                    .help("Send (↩)")
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 7)
        .background(Self.glassFill, in: .rect(cornerRadius: Theme.panelCorner))
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.panelCorner))
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: Theme.panelCorner).strokeBorder(.tint, lineWidth: 2)
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
        // Files copied in Finder paste as their names if ⌘V slipped past PasteInterceptor
        // (Edit ▸ Paste, another shortcut).
        let pasteboard = NSPasteboard.general
        if inserted == pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !files.isEmpty {
            session.draft = String(new[..<start]) + String(new[end...])
            for file in files { session.attach(.from(fileURL: file)) }
            return
        }
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

    /// ↑ goes back through the sent messages from an empty draft (or one recalled), ↓ forward.
    private func recall(by step: Int) -> KeyPress.Result {
        guard caretIsOnEdgeLine(up: step > 0) else { return .ignored }
        let history = session.promptHistory
        let recalled = historyIndex.map { history.indices.contains($0) ? history[$0] : "" }
        guard session.draft.isEmpty || session.draft == recalled else { return .ignored }
        let next = (historyIndex ?? -1) + step
        if next < 0 {
            guard historyIndex != nil else { return .ignored }
            historyIndex = nil
            session.draft = ""
            return .handled
        }
        guard history.indices.contains(next) else { return .ignored }
        historyIndex = next
        session.draft = history[next]
        selection = TextSelection(insertionPoint: session.draft.endIndex)
        return .handled
    }

    /// ↑ recalls only from the first line and ↓ only from the last, so the
    /// arrows still move through a recalled message of several lines (D219).
    private func caretIsOnEdgeLine(up: Bool) -> Bool {
        let draft = session.draft
        guard case .selection(let range)? = selection?.indices, range.upperBound <= draft.endIndex else { return true }
        return !(up ? draft[..<range.lowerBound] : draft[range.upperBound...]).contains("\n")
    }

    private var placeholder: String {
        if session.awaitsCorrection, session.status != .working {
            return "Tell \(session.provider.name) what to do instead…"
        }
        return session.status == .working
            ? "Queue a message for when \(session.provider.name) finishes…"
            : session.slashCommands.isEmpty
                ? "Ask \(session.provider.name)… (@ to add files)"
                : "Ask \(session.provider.name)… (@ for files, / for commands)"
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
        guard isFocused, let fileIndex, let query = activeMention, "@" + query != dismissedWord else { return [] }
        return fileIndex.search(query, limit: 8)
    }

    /// The command being typed: the draft's first word while the caret is in it ("/rev" → "rev").
    /// Agents read a command only at the start of the message.
    private var activeCommand: String? {
        let draft = session.draft
        guard draft.hasPrefix("/"), !session.slashCommands.isEmpty else { return nil }
        let caret = caret
        guard caret > draft.startIndex else { return nil }
        let word = draft[draft.index(after: draft.startIndex)..<caret]
        guard !word.contains(where: \.isWhitespace) else { return nil }
        return String(word)
    }

    private var commandMatches: [SlashCommand] {
        guard isFocused, let query = activeCommand, "/" + query != dismissedWord else { return [] }
        return SlashCommand.matches(query, in: session.slashCommands)
    }

    private func moveSuggestion(by offset: Int) -> KeyPress.Result {
        let count = commandMatches.isEmpty ? mentionMatches.count : commandMatches.count
        guard count > 0 else { return .ignored }
        mentionIndex = (mentionIndex + offset + count) % count
        return .handled
    }

    /// Through the field editor, as ⌥↩ does, so ⌘Z takes it back like typing (D219).
    private func insertLineBreak() -> KeyPress.Result {
        if NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil) { return .handled }
        var draft = session.draft
        var range = draft.endIndex..<draft.endIndex
        if case .selection(let selected)? = selection?.indices, selected.upperBound <= draft.endIndex {
            range = selected
        }
        let offset = draft.distance(from: draft.startIndex, to: range.lowerBound)
        draft.replaceSubrange(range, with: "\n")
        session.draft = draft
        selection = TextSelection(insertionPoint: draft.index(draft.startIndex, offsetBy: offset + 1))
        return .handled
    }

    private func pickSuggestion() -> KeyPress.Result {
        let commands = commandMatches
        if !commands.isEmpty {
            pick(commands[min(mentionIndex, commands.count - 1)])
            return .handled
        }
        let matches = mentionMatches
        guard !matches.isEmpty else { return .ignored }
        pick(matches[min(mentionIndex, matches.count - 1)])
        return .handled
    }

    /// The first word becomes the command, followed by a space for its input.
    private func pick(_ command: SlashCommand) {
        let draft = session.draft
        let rest = draft.firstIndex(where: \.isWhitespace).map { String(draft[$0...]) } ?? ""
        let head = "/" + command.name + (rest.isEmpty ? " " : "")
        session.draft = head + rest
        selection = TextSelection(insertionPoint: session.draft.index(session.draft.startIndex, offsetBy: head.count + (rest.isEmpty ? 0 : 1)))
        dismissedWord = nil
        isFocused = true
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
        dismissedWord = nil
        isFocused = true
    }

    // MARK: Files and images

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = session.cwd
        panel.prompt = "Attach"
        guard panel.runSheetModal() == .OK else { return }
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
    weak var window: NSWindow?
    private var monitor: Any?
    private nonisolated static let vKeyCode: UInt16 = 9

    func install(for session: AgentSession) {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak session] event in
            // The V key by position too: with a Russian layout it types "м".
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.keyCode == Self.vKeyCode || event.charactersIgnoringModifiers == "v",
                  let self, let session else { return event }
            let handled = MainActor.assumeIsolated {
                guard self.isActive, event.window === self.window, let attachments = PasteInterceptor.attachments(in: .general) else { return false }
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

/// The wheel and trackpad scroll a composer draft taller than its ten lines.
/// The field editor follows the caret but ignores scroll events (it has a clip
/// view, not a scroll view), so a local monitor scrolls it by hand.
@MainActor
final class ComposerScroller {
    var isActive = false
    weak var window: NSWindow?
    private var monitor: Any?

    func install() {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            let handled = MainActor.assumeIsolated { self.scroll(by: event) }
            return handled ? nil : event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func scroll(by event: NSEvent) -> Bool {
        guard isActive, let window, event.window === window,
              let textView = window.firstResponder as? NSTextView, textView.isFieldEditor else { return false }
        let visible = textView.visibleRect
        let overflow = textView.bounds.height - visible.height
        guard overflow > 1, visible.contains(textView.convert(event.locationInWindow, from: nil)) else { return false }
        var delta = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas, let font = textView.font {
            delta *= font.ascender - font.descender + font.leading
        }
        // The field editor is flipped: a positive delta shows the lines above.
        var target = visible
        target.origin.y = min(max(visible.minY - delta, 0), overflow)
        textView.scrollToVisible(target)
        return true
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
                        FileIconView(url: URL(fileURLWithPath: path), size: 13)
                            .orbitFont(.caption)
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
                    .orbitFont(.body)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(index == selected ? Theme.selectedFill : .clear, in: .capsule)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.largeCorner))
    }
}

/// The agent's slash commands matching what's typed, shown above the composer.
struct CommandList: View {
    let commands: [SlashCommand]
    let selected: Int
    let pick: (SlashCommand) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                        Button { pick(command) } label: {
                            HStack(spacing: 7) {
                                Text("/" + command.name)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                    .layoutPriority(2)
                                if let hint = command.hint, !hint.isEmpty {
                                    Text(hint)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                        .layoutPriority(1)
                                }
                                if !command.description.isEmpty {
                                    Text(command.description)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .orbitFont(.body)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(index == selected ? Theme.selectedFill : .clear, in: .capsule)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .help(command.description)
                        .id(index)
                    }
                }
                .padding(5)
            }
            // About eight rows, then it scrolls.
            .frame(maxHeight: 210)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: selected) { proxy.scrollTo(selected) }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.largeCorner))
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
                    .clipShape(.rect(cornerRadius: Theme.tinyCorner))
            } else if case .file(let url) = attachment {
                FileIconView(url: url, size: 12)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: attachment.systemImage)
                    .orbitFont(.micro)
                    .foregroundStyle(.secondary)
            }
            Text(attachment.label)
                .orbitFont(.caption, weight: .medium)
                .lineLimit(1)
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .orbitFont(.glyph, weight: .bold)
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

