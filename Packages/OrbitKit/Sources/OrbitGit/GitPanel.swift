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
                VStack(spacing: 14) {
                    EmptyStateView("No Git Repository", systemImage: "arrow.triangle.branch", message: "This folder isn't under version control.")
                        .frame(maxHeight: 180)
                    Button("Initialize Repository") { model.initialize() }
                        .buttonStyle(.glass)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        // Picks up saves and edits made elsewhere while the panel is on screen.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                model.refresh()
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
                Label(model.branchTitle, systemImage: "arrow.triangle.branch")
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Switch Branch")

            if model.status.ahead > 0 || model.status.behind > 0 {
                Text(syncLabel)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
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
                    .font(.system(size: 12))
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
            .background(Theme.subtleFill, in: .rect(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.hairline))
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
                        .font(.system(size: 11, weight: .medium))
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
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 90)
            .fixedSize(horizontal: false, vertical: true)
            IconButton("xmark", help: "Dismiss", action: dismiss)
        }
        .padding(8)
        .background(.orange.opacity(0.1), in: .rect(cornerRadius: 7))
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }
}

private struct ChangesList: View {
    let model: GitModel

    var body: some View {
        let status = model.status
        if status.files.isEmpty {
            EmptyStateView("No Changes", systemImage: "checkmark.circle", message: "The working tree is clean.")
                .frame(maxHeight: 200)
            Spacer()
        } else {
            List {
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
                            IconButton("arrow.uturn.backward", help: "Discard All Changes") { model.discard(status.unstaged) }
                            IconButton("plus", help: "Stage All") { model.stage(status.unstaged) }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }
}

private struct SectionHeader<Actions: View>: View {
    let title: String
    let count: Int
    @ViewBuilder var actions: Actions

    init(title: String, count: Int, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.title = title
        self.count = count
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
            Image(systemName: FileIcon.systemImage(for: URL(fileURLWithPath: file.path)))
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
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
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

    private var color: Color {
        switch kind {
        case .added, .untracked: Theme.added
        case .deleted, .conflicted: Theme.removed
        case .renamed, .copied: .blue
        case .modified, .typeChanged: .orange
        }
    }
}
