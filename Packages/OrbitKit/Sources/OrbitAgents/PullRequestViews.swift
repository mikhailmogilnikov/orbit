import AppKit
import OrbitAPI
import OrbitUI
import SwiftUI

/// An isolated session's changes as a GitHub pull request (D133).
struct CreatePullRequestSheet: View {
    let session: AgentSession
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var branch = ""
    @State private var description = ""
    @State private var base: String?
    @State private var isLoadingBase = true
    @State private var isWorking = false
    @State private var error: String?

    private var canCreate: Bool {
        base != nil && !isWorking
            && !title.trimmingCharacters(in: .whitespaces).isEmpty
            && !branch.trimmingCharacters(in: .whitespaces).isEmpty && !branch.contains(" ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Create Pull Request")
                    .font(.orbit(.title, weight: .semibold))
                Group {
                    if let base {
                        Text("The agent's changes in the isolated copy, committed to a new branch and proposed into \(base). The project itself isn't touched.")
                    } else if isLoadingBase {
                        Text("Reading the copy's branch…")
                    } else {
                        Text("The copy isn't a git repository on a branch, so there's nothing to open a pull request against.")
                    }
                }
                .font(.orbit(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            field("Title") {
                TextField("Title", text: $title)
                    .textFieldStyle(.roundedBorder)
            }
            field("Branch") {
                TextField("Branch", text: $branch)
                    .textFieldStyle(.roundedBorder)
                    .font(.orbit(.code))
            }
            field("Description") {
                TextEditor(text: $description)
                    .font(.orbit(.body))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 150)
                    .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.smallCorner))
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.orbit(.caption))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                if isWorking {
                    ProgressView().controlSize(.small)
                    Text("Committing, pushing, opening the pull request…")
                        .font(.orbit(.caption))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Button("Create Pull Request", action: create)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
        .padding(20)
        .frame(width: 500)
        .task {
            title = session.title
            branch = session.suggestedBranch
            description = String(session.lastReply.prefix(4000))
            base = await session.baseBranch()
            isLoadingBase = false
        }
    }

    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.orbit(.caption, weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func create() {
        isWorking = true
        error = nil
        Task {
            do {
                try await session.createPullRequest(
                    branch: branch.trimmingCharacters(in: .whitespaces),
                    title: title.trimmingCharacters(in: .whitespaces),
                    body: description.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isWorking = false
        }
    }
}

/// "PR #12 ✓": opens it; refreshes its checks every minute while Orbit is in front.
struct PullRequestBadge: View {
    let session: AgentSession
    let url: URL

    var body: some View {
        let status = session.pullRequestStatus
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon(status))
                    .foregroundStyle(color(status))
                Text(status.map { "PR #\($0.number)" } ?? "Pull request")
            }
            .font(.orbit(.caption, weight: .medium))
        }
        .buttonStyle(.glass)
        .help(help(status))
        .task(id: url) {
            while !Task.isCancelled {
                if NSApp.isActive { await session.refreshPullRequest() }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func icon(_ status: PullRequestStatus?) -> String {
        guard let status else { return "arrow.triangle.pull" }
        switch status.state {
        case .merged: return "arrow.triangle.merge"
        case .closed: return "xmark.circle"
        case .open:
            switch status.checks {
            case .none: return "arrow.triangle.pull"
            case .pending: return "clock"
            case .passing: return "checkmark.circle.fill"
            case .failing: return "xmark.circle.fill"
            }
        }
    }

    private func color(_ status: PullRequestStatus?) -> Color {
        guard let status else { return .secondary }
        switch status.state {
        case .merged: return .purple
        case .closed: return .secondary
        case .open:
            switch status.checks {
            case .none, .pending: return .secondary
            case .passing: return .green
            case .failing: return .red
            }
        }
    }

    private func help(_ status: PullRequestStatus?) -> String {
        guard let status else { return "Open the pull request on GitHub" }
        let state: String = switch status.state {
        case .merged: "Merged"
        case .closed: "Closed"
        case .open:
            switch status.checks {
            case .none: "Open, no checks"
            case .pending: "Open, checks running"
            case .passing: "Open, checks passed"
            case .failing: "Open, checks failed"
            }
        }
        return "\(state). Open on GitHub"
    }
}
