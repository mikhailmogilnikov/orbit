import AppKit
import UserNotifications

/// What a session wants the user to know while Orbit isn't in front (D87).
enum AgentAttention {
    case finished(summary: String)
    case failed(String)
    case permission(String)
}

/// System notifications and the Dock badge for agents that finished or wait
/// for a permission while Orbit is in the background. In front, the chat
/// itself shows it, so nothing is posted.
@MainActor
final class AgentNotifier: NSObject, UNUserNotificationCenterDelegate {
    var isEnabled = true
    /// A notification was clicked: show this session.
    var onOpen: (UUID) -> Void = { _ in }
    /// Sessions that wanted the user since Orbit went to the background.
    private var waiting: Set<UUID> = []
    private var isAuthorized: Bool?
    // Only an app bundle can use the notification center (not the test runner).
    private let center: UNUserNotificationCenter? = Bundle.main.bundleURL.pathExtension == "app" ? .current() : nil

    override init() {
        super.init()
        center?.delegate = self
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.clear() }
        }
    }

    func post(_ attention: AgentAttention, session: UUID, agent: String, chat: String) {
        guard isEnabled, !NSApp.isActive else { return }
        waiting.insert(session)
        NSApp.dockTile.badgeLabel = "\(waiting.count)"
        let content = UNMutableNotificationContent()
        content.subtitle = chat
        content.sound = .default
        content.threadIdentifier = session.uuidString
        content.userInfo = ["session": session.uuidString]
        switch attention {
        case .finished(let summary):
            content.title = "\(agent) finished"
            content.body = summary
        case .failed(let message):
            content.title = "\(agent) stopped"
            content.body = message
        case .permission(let action):
            content.title = "\(agent) needs your permission"
            content.body = action
            NSApp.requestUserAttention(.informationalRequest)
        }
        Task { await deliver(content, id: session.uuidString) }
    }

    private func deliver(_ content: UNMutableNotificationContent, id: String) async {
        guard let center else { return }
        if isAuthorized == nil {
            isAuthorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
        guard isAuthorized == true else { return }
        // One notification per chat: a newer one replaces it.
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    private func clear() {
        waiting.removeAll()
        NSApp.dockTile.badgeLabel = nil
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = (response.notification.request.content.userInfo["session"] as? String).flatMap(UUID.init) else { return }
        await MainActor.run { onOpen(id) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        []
    }
}
