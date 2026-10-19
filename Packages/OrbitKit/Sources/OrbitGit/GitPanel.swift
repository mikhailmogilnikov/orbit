import OrbitAPI
import OrbitUI
import SwiftUI

struct GitPanel: View {
    @Bindable var model: GitModel

    var body: some View {
        Group {
            switch model.state {
            case .noFolder:
                EmptyStateView("No Folder Open", systemImage: "folder", message: "Open a project to use source control.")
            case .loading:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .notRepository:
                EmptyStateView("No Git Repository", systemImage: "arrow.triangle.branch", message: "This folder isn't under version control.") {
                    Button("Initialize Repository") { model.initialize() }
                        .buttonStyle(.glass)
                        .tint(nil)
                }
            case .ready:
                VStack(spacing: 0) {
                    GitHeader(model: model)
                    CommitBox(model: model)
                    if let error = model.error {
                        ErrorBanner(message: error) { model.error = nil }
                    }
                    ChangesList(model: model)
                }
            }
        }
        // Picks up saves and edits made elsewhere while the panel is on screen;
        // in the background there's no one to see it (activation refreshes).
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if NSApp.isActive { model.refresh() }
            }
        }
    }
}

private struct GitHeader: View {
    let model: GitModel
    @State private var isNamingBranch = false
    @State private var newBranch = ""

    var body: some View {
        HStack(spacing: 4) {
            Menu {
                ForEach(model.branches, id: \.self) { branch in
                    Button {
                        model.switchBranch(branch)
                    } label: {
                        if branch == model.status.branch {
                            Label(branch, systemImage: "checkmark")
                        } else {
                            Text(branch)
                        }
                    }
                    .disabled(branch == model.status.branch)
                }
                Divider()
                Button("New Branch…") {
                    newBranch = ""
                    isNamingBranch = true
                }
            } label: {
                // Our own label, so a long branch name truncates instead of
                // widening the panel past the sidebar.
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                    Text(model.branchTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.orbit(.glyph, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .font(.orbit(.body, weight: .medium))
                .contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help("Switch Branch (\(model.branchTitle))")

            if model.status.ahead > 0 || model.status.behind > 0 {
                Text(syncLabel)
                    .font(.orbit(.caption).monospacedDigit())
                    .contentTransition(.numericText())
                    .animation(.snappy, value: syncLabel)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .help("\(model.status.ahead) to push, \(model.status.behind) to pull")
            }
            Spacer(minLength: 4)
            if model.isBusy {
                ProgressView().controlSize(.mini)
            }
            IconButton("arrow.down", help: "Pull") { model.pull() }
                .disabled(model.isBusy)
            IconButton("arrow.up", help: model.status.upstream == nil ? "Publish Branch" : "Push") { model.push() }
                .disabled(model.isBusy)
            Menu {
                Button("Fetch") { model.fetch() }
                Button("Refresh") { model.refresh() }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Fetch, Refresh")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .alert("New Branch", isPresented: $isNamingBranch) {
            TextField("Branch name", text: $newBranch)
            Button("Create") {
                let name = newBranch.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { model.switchBranch(name, create: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Creates a branch from the current commit and switches to it. Uncommitted changes come along.")
        }
    }

    private var syncLabel: String {
        [model.status.ahead > 0 ? "↑\(model.status.ahead)" : nil, model.status.behind > 0 ? "↓\(model.status.behind)" : nil]
            .compactMap { $0 }
            .joined(separator: " ")
    }
}

private struct CommitBox: View {
    @Bindable var model: GitModel

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 4) {
                TextField(model.isGenerating ? "Writing a message…" : "Message (⌘↩ to commit)", text: $model.commitMessage, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.orbit(.body))
                    .lineLimit(1...8)
                    .disabled(model.isGenerating)
                if let agent = model.messageAgent {
                    GenerateButton(isGenerating: model.isGenerating, agentName: agent.agentName) { model.generateMessage() }
                        .disabled(model.status.files.isEmpty)
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .padding(.vertical, 6)
            .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.smallCorner))
            .overlay(RoundedRectangle(cornerRadius: Theme.smallCorner).strokeBorder(Theme.hairline))
            .onKeyPress(.return, phases: .down) { press in
                // ⌘↩ commits from the field; plain Return keeps adding lines.
                guard press.modifiers.contains(.command) else { return .ignored }
                model.commit()
                return .handled
            }
            Button {
                model.commit()
            } label: {
                Label(model.status.staged.isEmpty ? "Commit All" : "Commit", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.regular)
            .disabled(!model.canCommit || model.isBusy)
            .help(model.status.staged.isEmpty ? "Stage every change and commit" : "Commit staged changes")
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        // Get the agent running while the user looks at their changes.
        .onAppear { if !model.status.files.isEmpty { model.messageAgent?.prewarm() } }
        .onChange(of: model.status.files.isEmpty) { _, isEmpty in
            if !isEmpty { model.messageAgent?.prewarm() }
        }
    }
}

/// Sparkle in the message field; turns into a stop button while the agent writes.
private struct GenerateButton: View {
    let isGenerating: Bool
    let agentName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isGenerating {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "sparkles")
                        .font(.orbit(.caption, weight: .medium))
                        .foregroundStyle(.tint)
                }
            }
            .frame(width: 18, height: 16)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(isGenerating ? "Stop" : "Generate Commit Message with \(agentName)")
    }
}

private struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            ScrollView {
                Text(message)
                    .font(.orbit(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 90)
            .fixedSize(horizontal: false, vertical: true)
            IconButton("xmark", help: "Dismiss", action: dismiss)
        }
        .padding(8)
        .background(.orange.opacity(0.1), in: .rect(cornerRadius: Theme.smallCorner))
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }
}

private struct ChangesList: View {
    @Bindable var model: GitModel
    @State private var showsStashes = true
    @State private var showsHistory = true
    @State private var stashMessage = ""

    var body: some View {
        let status = model.status
        Group {
            if status.files.isEmpty, model.stashes.isEmpty, model.history.isEmpty, model.historyQuery.isEmpty, model.historyScope == .current {
                EmptyStateView("No Changes", systemImage: "checkmark.circle", message: "The working tree is clean.")
                    .frame(maxHeight: 200)
                Spacer()
            } else {
                List {
                    if status.files.isEmpty {
                        Label("No changes, the working tree is clean", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    if !status.conflicted.isEmpty {
                        Section {
                            ForEach(status.conflicted, id: \.path) { file in
                                ChangeRow(file: file, kind: .conflicted, model: model, section: .unstaged)
                            }
                        } header: {
                            SectionHeader(title: "Merge Conflicts", count: status.conflicted.count)
                        }
                    }
                    if !status.staged.isEmpty {
                        Section {
                            ForEach(status.staged, id: \.path) { file in
                                ChangeRow(file: file, kind: file.staged ?? .modified, model: model, section: .staged)
                            }
                        } header: {
                            SectionHeader(title: "Staged Changes", count: status.staged.count) {
                                IconButton("minus", help: "Unstage All") { model.unstage(status.staged) }
                            }
                        }
                    }
                    if !status.unstaged.isEmpty {
                        Section {
                            ForEach(status.unstaged, id: \.path) { file in
                                ChangeRow(file: file, kind: file.unstaged ?? .modified, model: model, section: .unstaged)
                            }
                        } header: {
                            SectionHeader(title: "Changes", count: status.unstaged.count) {
                                IconButton("tray.and.arrow.down", help: "Stash All Changes") { model.isNamingStash = true }
                                IconButton("arrow.uturn.backward", help: "Discard All Changes") { model.discard(status.unstaged) }
                                IconButton("plus", help: "Stage All") { model.stage(status.unstaged) }
                            }
                        }
                    }
                    if !model.stashes.isEmpty {
                        Section(isExpanded: $showsStashes) {
                            ForEach(model.stashes) { stash in
                                StashRow(stash: stash, model: model)
                            }
                        } header: {
                            SectionHeader(title: "Stashes", count: model.stashes.count, isExpanded: $showsStashes)
                        }
                    }
                    if status.hasCommits {
                        Section(isExpanded: $showsHistory) {
                            HistoryRows(model: model)
                        } header: {
                            SectionHeader(title: "History", count: model.history.count, isExpanded: $showsHistory)
                        }
                    }
                }
                .listStyle(.sidebar)
                // History rows are as tall as their graph cell, so its lines meet (D136).
                .environment(\.defaultMinListRowHeight, 20)
            }
        }
        .alert("Stash Changes", isPresented: $model.isNamingStash) {
            TextField("Message (optional)", text: $stashMessage)
            Button("Stash") {
                model.stash(message: stashMessage)
                stashMessage = ""
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Puts all changes, new files included, aside and leaves a clean working tree.")
        }
    }
}

private struct StashRow: View {
    let stash: GitStash
    let model: GitModel
    @State private var isHovered = false
    @State private var isExpanded = false

    var body: some View {
        row
        if isExpanded, !stash.hash.isEmpty {
            // A stash is a commit on top of HEAD: its files, as a commit's (D154).
            CommitFiles(
                commit: GitCommit(hash: stash.hash, shortHash: stash.ref, author: "", date: stash.date, subject: stash.message),
                model: model, passing: [], graphWidth: 0, spacing: 0
            )
        }
    }

    private var row: some View {
        HStack(spacing: 6) {
            DisclosureChevron(isExpanded: isExpanded)
                .foregroundStyle(.tertiary)
                .frame(width: 10)
                .contentShape(.rect)
                .onTapGesture { withAnimation(.snappy(duration: 0.15)) { isExpanded.toggle() } }
                .help(isExpanded ? "Hide Files" : "Show Files")
            Image(systemName: "tray.full")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(stash.message.isEmpty ? stash.ref : stash.message)
                .lineLimit(1)
            Spacer(minLength: 4)
            if isHovered {
                IconButton("trash", help: "Delete Stash…") { model.dropStash(stash) }
                IconButton("tray.and.arrow.up", help: "Pop (apply and delete)") { model.applyStash(stash, drop: true) }
            } else {
                Text(stash.date, format: .relative(presentation: .named))
                    .font(.orbit(.caption))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) { isExpanded.toggle() }
        .contextMenu {
            Button(isExpanded ? "Hide Files" : "Show Files") { isExpanded.toggle() }
            Divider()
            Button("Pop (Apply and Delete)") { model.applyStash(stash, drop: true) }
            Button("Apply") { model.applyStash(stash, drop: false) }
            Divider()
            Button("Delete…") { model.dropStash(stash) }
        }
        .help("\(stash.ref): \(stash.message)")
    }
}

/// A commit; expanding it lists its files, clicking one opens what changed in it.
/// Branch picker and search, then the commits with their graph (D136).
private struct HistoryRows: View {
    @Bindable var model: GitModel
    @State private var expanded: Set<String> = []

    private static let laneSpacing: CGFloat = 12
    private static let maxLanes = 8

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                Picker("Show", selection: $model.historyScope) {
                    Text("Current Branch").tag(GitModel.HistoryScope.current)
                    Text("All Branches").tag(GitModel.HistoryScope.all)
                    if !model.branches.isEmpty {
                        Divider()
                        ForEach(model.branches, id: \.self) { branch in
                            Text(branch).tag(GitModel.HistoryScope.branch(branch))
                        }
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label(scopeTitle, systemImage: "arrow.triangle.branch")
                    .font(.orbit(.caption))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Which branches' history to show")
            TextField("Search commits", text: $model.historyQuery)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .help("Message, author or hash")
        }
        .listRowInsets(EdgeInsets(top: 2, leading: 2, bottom: 4, trailing: 4))
        let graph = model.graph
        let lanes = min(Self.maxLanes, graph.map(\.laneCount).max() ?? 0)
        let width = lanes == 0 ? 0 : CGFloat(lanes) * Self.laneSpacing
        ForEach(Array(model.history.enumerated()), id: \.element.id) { index, commit in
            let row = index < graph.count ? graph[index] : nil
            CommitRow(commit: commit, model: model, graph: row, graphWidth: width, spacing: Self.laneSpacing,
                      isExpanded: expanded.contains(commit.hash)) {
                if expanded.remove(commit.hash) == nil { expanded.insert(commit.hash) }
            }
            if expanded.contains(commit.hash) {
                CommitFiles(commit: commit, model: model, passing: row?.continuing ?? [], graphWidth: width, spacing: Self.laneSpacing)
            }
        }
        if model.history.isEmpty, !model.historyQuery.isEmpty {
            Text("No commits match")
                .font(.orbit(.caption))
                .foregroundStyle(.secondary)
        }
    }

    private var scopeTitle: String {
        switch model.historyScope {
        case .current: "Current"
        case .all: "All"
        case .branch(let name): name
        }
    }
}

/// Two lines (D156): the message across the whole width, then its branches,
/// author and age; the graph runs the full height. A click lists its files.
private struct CommitRow: View {
    let commit: GitCommit
    let model: GitModel
    let graph: GitGraphRow?
    let graphWidth: CGFloat
    let spacing: CGFloat
    let isExpanded: Bool
    let toggle: () -> Void
    @State private var isHovered = false

    static let height: CGFloat = 38

    var body: some View {
        HStack(spacing: 6) {
            if graphWidth > 0 {
                GitGraphCell(row: graph, width: graphWidth, spacing: spacing,
                             isMerge: commit.parents.count > 1, isHead: RefBadges.isHead(commit.refs))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(commit.subject.isEmpty ? commit.shortHash : commit.subject)
                    .font(.orbit(.body))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    RefBadges(refs: commit.refs)
                    Text("\(commit.author) · \(Self.age(commit.date))")
                        .font(.orbit(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: Self.height)
        .background(isHovered ? Theme.hoverFill : isExpanded ? Theme.subtleFill : .clear, in: .rect(cornerRadius: Theme.smallCorner))
        .contentShape(.rect)
        .onTapGesture(perform: toggle)
        .onHover { isHovered = $0 }
        .listRowInsets(EdgeInsets(top: 0, leading: 2, bottom: 0, trailing: 4))
        .help("\(commit.shortHash) · \(commit.author) · \(commit.date.formatted(date: .abbreviated, time: .shortened))\n\(commit.subject)\n\n\(isExpanded ? "Click to hide its files" : "Click to show its files")")
        .contextMenu {
            Button(isExpanded ? "Hide Files" : "Show Files", action: toggle)
            Divider()
            Button("Copy Commit Hash") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commit.hash, forType: .string)
            }
            Button("Copy Message") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commit.subject, forType: .string)
            }
        }
    }

    /// "now", "5m", "3h", "2d", "4w", "3mo", "2y": short enough for a narrow sidebar.
    static func age(_ date: Date, now: Date = Date()) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60), hours = minutes / 60, days = hours / 24
        if minutes < 1 { return "now" }
        if hours < 1 { return "\(minutes)m" }
        if days < 1 { return "\(hours)h" }
        if days < 14 { return "\(days)d" }
        if days < 60 { return "\(days / 7)w" }
        if days < 365 { return "\(days / 30)mo" }
        return "\(days / 365)y"
    }
}

/// Branch and tag names on a commit (D156): a local branch and its `origin/`
/// copy are one badge with a cloud; `origin/HEAD` is left out; the checked-out
/// branch is filled.
struct RefBadges: View {
    let refs: [String]

    struct Badge: Equatable, Sendable {
        enum Kind: Equatable { case local, remote, synced, tag }
        var name: String
        var kind: Kind
        var isHead = false
    }

    nonisolated static func isHead(_ refs: [String]) -> Bool {
        refs.contains { $0 == "HEAD" || $0.hasPrefix("HEAD -> ") }
    }

    nonisolated static func badges(_ refs: [String]) -> [Badge] {
        var badges: [Badge] = []
        var remotes: [String] = []
        for ref in refs {
            if ref == "HEAD" || ref.hasSuffix("/HEAD") { continue }
            if ref.hasPrefix("tag: ") {
                badges.append(Badge(name: String(ref.dropFirst(5)), kind: .tag))
            } else if ref.hasPrefix("HEAD -> ") {
                badges.append(Badge(name: String(ref.dropFirst(8)), kind: .local, isHead: true))
            } else if ref.hasPrefix("origin/") || ref.hasPrefix("upstream/") {
                remotes.append(ref)
            } else {
                badges.append(Badge(name: ref, kind: .local))
            }
        }
        for remote in remotes {
            let name = String(remote[remote.index(after: remote.firstIndex(of: "/")!)...])
            if let index = badges.firstIndex(where: { $0.kind == .local && $0.name == name }) {
                badges[index].kind = .synced
            } else {
                badges.append(Badge(name: remote, kind: .remote))
            }
        }
        // The checked-out branch first, tags last.
        return badges.sorted { ($0.isHead ? 0 : $0.kind == .tag ? 2 : 1) < ($1.isHead ? 0 : $1.kind == .tag ? 2 : 1) }
    }

    var body: some View {
        let badges = Self.badges(refs)
        ForEach(badges.prefix(2), id: \.name) { badge in
            let color: Color = badge.kind == .tag ? .orange : badge.kind == .remote ? .secondary : Theme.accent
            OrbitUI.Badge(tint: color, prominent: badge.isHead) {
                HStack(spacing: 2) {
                    Image(systemName: badge.kind == .tag ? "tag.fill" : badge.kind == .remote ? "cloud" : badge.kind == .synced ? "checkmark.icloud" : "arrow.triangle.branch")
                        .font(.orbit(.glyph, weight: .semibold))
                    Text(badge.name)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: 120, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .help(badge.kind == .synced ? "\(badge.name), same as on origin" : badge.isHead ? "\(badge.name) (checked out)" : badge.name)
        }
        if badges.count > 2 {
            Text("+\(badges.count - 2)")
                .font(.orbit(.micro))
                .foregroundStyle(.tertiary)
                .help(badges.dropFirst(2).map(\.name).joined(separator: "\n"))
        }
    }
}

/// A commit's files under it, the graph's lines passing beside them.
private struct CommitFiles: View {
    let commit: GitCommit
    let model: GitModel
    let passing: [Int]
    let graphWidth: CGFloat
    let spacing: CGFloat
    @State private var files: [GitCommitFile]?

    var body: some View {
        Group {
            if let files {
                ForEach(files) { file in
                    row { CommitFileRow(file: file) }
                        .onTapGesture { model.openDiff(file, in: commit) }
                }
            } else {
                row { ProgressView().controlSize(.mini) }
            }
        }
        .task { if files == nil { files = await model.files(in: commit) } }
    }

    private func row(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 6) {
            if graphWidth > 0 {
                GitGraphCell(row: nil, passing: passing, width: graphWidth, spacing: spacing)
            }
            content()
                .padding(.leading, 14)
        }
        .frame(height: 22)
        .listRowInsets(EdgeInsets(top: 0, leading: 2, bottom: 0, trailing: 4))
    }
}

private struct CommitFileRow: View {
    let file: GitCommitFile

    var body: some View {
        let name = (file.path as NSString).lastPathComponent
        let folder = (file.path as NSString).deletingLastPathComponent
        HStack(spacing: 6) {
            FileIconView(url: URL(fileURLWithPath: file.path))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(name)
                .strikethrough(file.status == .deleted)
                .lineLimit(1)
                .layoutPriority(1)
            if !folder.isEmpty {
                Text(folder)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            Text(String(file.status.rawValue))
                .font(.orbit(.caption, weight: .semibold, design: .monospaced))
                .foregroundStyle(file.status.color)
                .frame(width: 12)
        }
        .contentShape(.rect)
        .help(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
    }
}

private struct SectionHeader<Actions: View>: View {
    let title: String
    let count: Int
    /// A collapsible section: a click anywhere on the header toggles it, not
    /// only on the list's chevron at its end.
    var isExpanded: Binding<Bool>?
    @ViewBuilder var actions: Actions

    init(title: String, count: Int, isExpanded: Binding<Bool>? = nil, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.title = title
        self.count = count
        self.isExpanded = isExpanded
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: 2) {
            Text(title)
            Text("\(count)")
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
            Spacer()
            actions
        }
        .contentShape(.rect)
        .onTapGesture {
            guard let isExpanded else { return }
            withAnimation(.snappy(duration: 0.2)) { isExpanded.wrappedValue.toggle() }
        }
    }
}

private struct ChangeRow: View {
    enum Section { case staged, unstaged }

    let file: GitFileStatus
    let kind: GitFileStatus.Kind
    let model: GitModel
    let section: Section
    @State private var isHovered = false

    var body: some View {
        let name = (file.path as NSString).lastPathComponent
        let folder = (file.path as NSString).deletingLastPathComponent
        HStack(spacing: 6) {
            FileIconView(url: URL(fileURLWithPath: file.path))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(name)
                .strikethrough(kind == .deleted)
                .lineLimit(1)
                .layoutPriority(1)
            if !folder.isEmpty {
                Text(folder)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            if isHovered, kind != .conflicted {
                if section == .unstaged {
                    IconButton("arrow.uturn.backward", help: "Discard Changes") { model.discard([file]) }
                    IconButton("plus", help: "Stage") { model.stage([file]) }
                } else {
                    IconButton("minus", help: "Unstage") { model.unstage([file]) }
                }
            } else if kind == .conflicted, isHovered {
                IconButton("plus", help: "Mark Resolved") { model.stage([file]) }
            }
            Text(String(kind.rawValue))
                .font(.orbit(.caption, weight: .semibold, design: .monospaced))
                .foregroundStyle(kind.color)
                .frame(width: 12)
        }
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .onTapGesture { model.openDiff(file, staged: section == .staged) }
        .contextMenu {
            if kind != .conflicted {
                Button("Open Changes") { model.openDiff(file, staged: section == .staged) }
            }
            Button("Open File") { model.open(file) }
            Divider()
            if section == .staged {
                Button("Unstage") { model.unstage([file]) }
            } else {
                Button("Stage") { model.stage([file]) }
                if kind != .conflicted {
                    Button("Discard Changes…") { model.discard([file]) }
                }
            }
            Divider()
            Button("Reveal in Finder") { model.reveal(file) }
        }
        .help(file.originalPath.map { "\($0) → \(file.path)" } ?? file.path)
    }

}

extension GitFileStatus.Kind {
    @MainActor var color: Color {
        switch self {
        case .added, .untracked: Theme.added
        case .deleted: Theme.removed
        case .conflicted: Theme.conflict
        case .renamed, .copied: Theme.renamed
        case .modified, .typeChanged: Theme.modified
        }
    }
}
