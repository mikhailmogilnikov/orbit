import OrbitAPI
import OrbitUI
import SwiftUI

/// Every window's agent stores, for the overview (D130). Held weakly and
/// dropped on shutdown: a closed window frees its own (D101).
@MainActor
@Observable
final class AgentDirectory {
    static let shared = AgentDirectory()

    private struct Entry { weak var store: AgentStore? }
    private var entries: [Entry] = []

    var stores: [AgentStore] { entries.compactMap(\.store) }

    func add(_ store: AgentStore) {
        entries.removeAll { $0.store == nil || $0.store === store }
        entries.append(Entry(store: store))
    }

    func remove(_ store: AgentStore) {
        entries.removeAll { $0.store == nil || $0.store === store }
    }

    /// Chats worth listing: started ones, not restored tabs that never ran or empty new chats.
    var chats: [(store: AgentStore, session: AgentSession)] {
        stores.flatMap { store in
            store.sessions
                .filter { $0.status != .dormant && !($0.isEmptyChat && $0.entries.isEmpty) }
                .map { (store, $0) }
        }
        .sorted { AgentActivity($0.session).rank < AgentActivity($1.session).rank }
    }

    var workingCount: Int { stores.reduce(0) { $0 + $1.sessions.filter { $0.status == .working }.count } }
    var waitingCount: Int { stores.reduce(0) { $0 + $1.sessions.filter(\.hasPendingPermission).count } }
}

/// What a chat is doing, as the overview shows it.
enum AgentActivity {
    case waiting(PermissionRequest)
    case working(since: Date?)
    case failed(String)
    case finished(TranscriptEntry)
    case idle

    @MainActor
    init(_ session: AgentSession) {
        if let request = session.firstPendingPermission {
            self = .waiting(request)
        } else if session.status == .working || session.status == .starting {
            self = .working(since: session.turnStartedAt)
        } else if case .failed(let message) = session.status {
            self = .failed(message)
        } else if let summary = session.lastSummary {
            self = .finished(summary)
        } else {
            self = .idle
        }
    }

    /// Waiting on the user first, then running, then the rest.
    var rank: Int {
        switch self {
        case .waiting: 0
        case .working: 1
        case .failed: 2
        case .finished: 3
        case .idle: 4
        }
    }
}

/// The status bar's agents item: counts over every window; click for the overview.
struct AgentActivityStatus: View {
    @Bindable var store: AgentStore

    var body: some View {
        let directory = AgentDirectory.shared
        let working = directory.workingCount
        let waiting = directory.waitingCount
        Button {
            store.isOverviewShown.toggle()
        } label: {
            HStack(spacing: 10) {
                if working > 0 {
                    Label("\(working) working", systemImage: "sparkles")
                        .foregroundStyle(.tint)
                }
                if waiting > 0 {
                    Label("\(waiting) needs approval", systemImage: "hand.raised.fill")
                        .foregroundStyle(.orange)
                }
                if working == 0, waiting == 0 {
                    Label("Agents", systemImage: "sparkles")
                        .foregroundStyle(.secondary)
                }
            }
            .orbitFont(.micro)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("All agents (⌃⌘A)")
        .popover(isPresented: $store.isOverviewShown, arrowEdge: .top) {
            AgentsOverview(close: { store.isOverviewShown = false })
        }
    }
}

/// Every chat in every window: who works, who waits for a permission, who's done (D130).
struct AgentsOverview: View {
    let close: () -> Void

    var body: some View {
        let chats = AgentDirectory.shared.chats
        VStack(alignment: .leading, spacing: 0) {
            Text("Agents")
                .orbitFont(.control, weight: .semibold)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)
            if chats.isEmpty {
                Text("No chats yet in any window.")
                    .orbitFont(.body)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(chats, id: \.session.id) { chat in
                            AgentOverviewRow(session: chat.session, showsProject: Set(chats.map { $0.session.project }).count > 1) {
                                chat.store.show(chat.session)
                                close()
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: 420)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 380, alignment: .leading)
    }
}

private struct AgentOverviewRow: View {
    let session: AgentSession
    let showsProject: Bool
    let open: () -> Void
    @State private var isHovering = false

    var body: some View {
        let activity = AgentActivity(session)
        HStack(alignment: .top, spacing: 10) {
            AgentIcon(provider: session.provider, size: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.title)
                        .orbitFont(.body, weight: .medium)
                        .lineLimit(1)
                    if showsProject {
                        Text(session.project.lastPathComponent)
                            .orbitFont(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                status(activity)
                    .orbitFont(.caption)
                    .lineLimit(2)
                if case .waiting(let request) = activity {
                    HStack(spacing: 6) {
                        if let deny = request.option(allow: false) {
                            Button("Deny") { request.choose(deny) }
                                .buttonStyle(.glass)
                        }
                        if let allow = request.option(allow: true) {
                            Button("Allow") { request.choose(allow) }
                                .buttonStyle(.glassProminent)
                        }
                    }
                    .controlSize(.small)
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
            if case .working = activity {
                ProgressView().controlSize(.mini)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(isHovering ? Theme.hoverFill : .clear, in: .rect(cornerRadius: Theme.corner))
        .contentShape(.rect)
        .onTapGesture(perform: open)
        .onHover { isHovering = $0 }
        .help("Show this chat")
    }

    @ViewBuilder
    private func status(_ activity: AgentActivity) -> some View {
        switch activity {
        case .waiting(let request):
            Label(request.title, systemImage: "hand.raised.fill")
                .foregroundStyle(.orange)
                .symbolEffect(.wiggle, options: .repeat(.periodic(delay: 3)))
        case .working(let since):
            if let since {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text("Working · \(TurnSummaryView.format(context.date.timeIntervalSince(since)))")
                        .foregroundStyle(.tint)
                }
            } else {
                Text("Starting…").foregroundStyle(.secondary)
            }
        case .failed(let message):
            Text(message).foregroundStyle(.red)
        case .finished(let summary):
            let files = summary.changedFiles.count
            Text("Done in \(TurnSummaryView.format(summary.duration))" + (files > 0 ? " · \(files) file\(files == 1 ? "" : "s") changed" : ""))
                .foregroundStyle(.secondary)
        case .idle:
            Text("Idle").foregroundStyle(.secondary)
        }
    }
}
