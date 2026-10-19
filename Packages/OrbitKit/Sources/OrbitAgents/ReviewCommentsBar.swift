import OrbitAPI
import OrbitUI
import SwiftUI

/// Review notes written in the editor, above the composer until they're sent
/// to the chat as one message (D125).
struct ReviewCommentsBar: View {
    let store: AgentStore
    @State private var isExpanded = true

    var body: some View {
        let comments = store.reviewComments.comments
        if !comments.isEmpty {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            DisclosureChevron(isExpanded: isExpanded)
                                .foregroundStyle(.secondary)
                            Text("\(comments.count) comment\(comments.count == 1 ? "" : "s") for the agent")
                                .font(.orbit(.caption, weight: .medium))
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "Hide the comments" : "Show the comments")
                    Spacer(minLength: 4)
                    Button("Discard") { store.reviewComments.removeAll() }
                        .buttonStyle(.glass)
                        .help("Delete every comment without sending")
                    Button("Send") { store.sendReviewComments() }
                        .buttonStyle(.glassProminent)
                        .help(sendHelp)
                }
                .controlSize(.small)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                if isExpanded {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(comments) { comment in
                                ReviewCommentRow(comment: comment, store: store)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                    }
                    .frame(maxHeight: 156)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .top) { Divider() }
        }
    }

    private var sendHelp: String {
        store.selected?.status == .working
            ? "Send to this chat as one message after the current turn"
            : "Send to this chat as one message"
    }
}

private struct ReviewCommentRow: View {
    let comment: ReviewComment
    let store: AgentStore
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.bubble")
                .font(.orbit(.caption))
                .foregroundStyle(.secondary)
            Text(comment.text)
                .font(.orbit(.body))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text("\(comment.url.lastPathComponent):\(comment.lines.lowerBound + 1)")
                .font(.orbit(.caption))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
            if isHovering {
                IconButton("xmark", help: "Delete this comment") { store.reviewComments.remove(comment.id) }
            }
        }
        .frame(height: 24)
        .padding(.horizontal, 8)
        .background(isHovering ? Theme.hoverFill : .clear, in: .rect(cornerRadius: Theme.smallCorner))
        .contentShape(.rect)
        .onTapGesture { store.workspace.openFile(comment.url, line: comment.lines.lowerBound) }
        .onHover { isHovering = $0 }
        .help(comment.text)
        .contextMenu {
            Button("Open") { store.workspace.openFile(comment.url, line: comment.lines.lowerBound) }
            Divider()
            Button("Delete", role: .destructive) { store.reviewComments.remove(comment.id) }
        }
    }
}
