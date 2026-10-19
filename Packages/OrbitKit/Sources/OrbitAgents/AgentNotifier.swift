import AppKit
import UserNotifications

/// What a session wants the user to know while Orbit isn't in front (D87).
enum AgentAttention {
    case finished(summary: String)
    case failed(String)
    case permission(String, request: UUID)
}

/// A permission answered from the notification's buttons (D130).
enum PermissionAnswer: String {
    case allow, allowAlways, deny
}

/// System notifications and the Dock badge for agents that finished or wait
/// for a permission while Orbit is in the background. In front, the chat
/// itself shows it, so nothing is posted.
@MainActor
final class AgentNotifier {
    var isEnabled = true
    /// A sound when one finishes in the background without a notification (D153).
    var playsSound = true
    /// A notification was clicked: show this session.
    var onOpen: (UUID) -> Void = { _ in }
    /// Allow / Deny on a permission's notification: session, request, answer.
    var onAnswer: (UUID, UUID, PermissionAnswer) -> Void = { _, _, _ in }
    /// Sessions that wanted the user since Orbit went to the background.
    private var waiting: Set<UUID> = []
    private var isAuthorized: Bool?
    // Only an app bundle can use the notification center (not the test runner).
    private let center: UNUserNotificationCenter? = Bundle.main.bundleURL.pathExtension == "app" ? .current() : nil

    private var activationObserver: NSObjectProtocol?

    init() {
        if let center { NotificationRouter.shared.add(self, center: center) }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.clear() }
        }
    }

    isolated deinit {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        NotificationRouter.shared.updateBadge()
    }

    fileprivate var waitingCount: Int { waiting.count }

    func post(_ attention: AgentAttention, session: UUID, agent: String, chat: String) {
        guard !NSApp.isActive else { return }
        if isEnabled {
            waiting.insert(session)
            NotificationRouter.shared.updateBadge()
        }
        guard isEnabled, isAuthorized != false, center != nil else {
            // Notifications off or not allowed: the Mac's own sound still says it.
            if playsSound, case .finished = attention { NSSound(named: "Glass")?.play() }
            if playsSound, case .failed = attention { NSSound(named: "Basso")?.play() }
            if case .permission = attention { NSApp.requestUserAttention(.informationalRequest) }
            return
        }
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
        case .permission(let action, let request):
            content.title = "\(agent) needs your permission"
            content.body = action
            content.categoryIdentifier = NotificationRouter.permissionCategory
            content.userInfo["request"] = request.uuidString
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
        NotificationRouter.shared.updateBadge()
    }

    fileprivate func open(_ id: UUID) { onOpen(id) }

    fileprivate func answer(session: UUID, request: UUID, _ answer: PermissionAnswer) {
        guard waiting.remove(session) != nil else { return }
        NotificationRouter.shared.updateBadge()
        onAnswer(session, request, answer)
    }
}

/// The notification center has one delegate for the app, and each window has
/// its own notifier (D101): a click goes to every window's (only the one with
/// that chat acts), and the Dock badge counts all of them.
@MainActor
private final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    private struct Weak { weak var notifier: AgentNotifier? }
    private var notifiers: [Weak] = []

    static let permissionCategory = "permission"

    func add(_ notifier: AgentNotifier, center: UNUserNotificationCenter) {
        if center.delegate !== self {
            center.delegate = self
            // Answered right from the notification, without bringing Orbit forward.
            center.setNotificationCategories([UNNotificationCategory(
                identifier: Self.permissionCategory,
                actions: [
                    UNNotificationAction(identifier: PermissionAnswer.allow.rawValue, title: "Allow"),
                    UNNotificationAction(identifier: PermissionAnswer.allowAlways.rawValue, title: "Always Allow"),
                    UNNotificationAction(identifier: PermissionAnswer.deny.rawValue, title: "Deny", options: .destructive),
                ],
                intentIdentifiers: []
            )])
        }
        notifiers.removeAll { $0.notifier == nil }
        notifiers.append(Weak(notifier: notifier))
    }

    func updateBadge() {
        let count = notifiers.reduce(0) { $0 + ($1.notifier?.waitingCount ?? 0) }
        NSApp.dockTile.badgeLabel = count == 0 ? nil : "\(count)"
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let id = (info["session"] as? String).flatMap(UUID.init) else { return }
        let request = (info["request"] as? String).flatMap(UUID.init)
        let answer = PermissionAnswer(rawValue: response.actionIdentifier)
        await MainActor.run {
            for entry in notifiers {
                if let answer, let request {
                    entry.notifier?.answer(session: id, request: request, answer)
                } else {
                    entry.notifier?.open(id)
                }
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        []
    }
}
