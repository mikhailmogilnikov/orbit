import Foundation
import OrbitACP

/// What a session costs: context fill, spending, plan limits and tokens.
/// Agents report it piecemeal (`usage_update`, each prompt's `usage`), so
/// every part is optional until the agent says something about it.
struct SessionUsage: Equatable {
    struct Limit: Equatable, Identifiable, Codable {
        var id: String
        var name: String
        /// 0...1 of the window used.
        var used: Double?
        var resetsAt: Date?
        var isExhausted: Bool
        /// "Using extra usage", "Near the limit".
        var note: String?

        /// The window ended since the agent said so: it starts over empty.
        func hasReset(at now: Date = Date()) -> Bool { resetsAt.map { $0 <= now } ?? false }
    }

    /// The account's limits as one agent last reported them; outlives the chat (`LimitsMemory`).
    struct Limits: Equatable, Codable {
        var windows: [Limit]
        /// "Pro Lite", when the agent names the plan.
        var plan: String?
        var credits: String?
        var updatedAt: Date
    }

    struct Tokens: Equatable {
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheWrite = 0
        var thought = 0
        var total = 0

        static func += (lhs: inout Tokens, rhs: Tokens) {
            lhs.input += rhs.input
            lhs.output += rhs.output
            lhs.cacheRead += rhs.cacheRead
            lhs.cacheWrite += rhs.cacheWrite
            lhs.thought += rhs.thought
            lhs.total += rhs.total
        }
    }

    var contextUsed: Int?
    var contextSize: Int?
    var cost: Double?
    var currency = "USD"
    /// By window; Claude reports one window per event.
    private(set) var limits: [Limit] = []
    private(set) var plan: String?
    private(set) var credits: String?
    /// When the agent last said anything about the limits.
    private(set) var limitsUpdatedAt: Date?

    var limitsSnapshot: Limits? {
        limitsUpdatedAt.map { Limits(windows: limits, plan: plan, credits: credits, updatedAt: $0) }
    }

    /// Remembered or read from the agent's own files; newer news only.
    mutating func apply(limits snapshot: Limits) {
        guard snapshot.updatedAt >= (limitsUpdatedAt ?? .distantPast) else { return }
        limits = snapshot.windows
        plan = snapshot.plan ?? plan
        credits = snapshot.credits
        limitsUpdatedAt = snapshot.updatedAt
    }
    /// Summed over the turns sent since the session was opened in Orbit
    /// (agents report each turn's usage, not the conversation's).
    var tokens: Tokens?
    var turns = 0

    var hasContext: Bool { (contextSize ?? 0) > 0 && contextUsed != nil }

    var contextFraction: Double {
        guard let used = contextUsed, let size = contextSize, size > 0 else { return 0 }
        return min(1, Double(used) / Double(size))
    }

    var isEmpty: Bool { !hasContext && cost == nil && limits.isEmpty && tokens == nil }

    /// A `usage_update` session update; a replayed one's limits are old news.
    mutating func apply(update json: JSONValue, includesLimits: Bool = true) {
        if let used = json["used"]?.int { contextUsed = used }
        if let size = json["size"]?.int, size > 0 { contextSize = size }
        if let amount = json["cost"]?["amount"]?.double {
            cost = amount
            currency = json["cost"]?["currency"]?.string ?? currency
        }
        if includesLimits, let info = json["_meta"]?["_claude/rateLimit"] { applyClaudeLimit(info) }
    }

    /// The `usage` of a prompt response: one turn.
    mutating func apply(turn json: JSONValue?) {
        guard let json, json["totalTokens"]?.int != nil else { return }
        var turn = Tokens()
        turn.input = json["inputTokens"]?.int ?? 0
        turn.output = json["outputTokens"]?.int ?? 0
        turn.cacheRead = json["cachedReadTokens"]?.int ?? 0
        turn.cacheWrite = json["cachedWriteTokens"]?.int ?? 0
        turn.thought = json["thoughtTokens"]?.int ?? 0
        turn.total = json["totalTokens"]?.int ?? 0
        tokens = (tokens ?? Tokens())
        tokens! += turn
        turns += 1
    }

    /// Claude Code's `SDKRateLimitInfo`: utilization is a 0–1 fraction, resets in epoch seconds.
    private mutating func applyClaudeLimit(_ info: JSONValue) {
        let type = info["rateLimitType"]?.string ?? "limit"
        let status = info["status"]?.string
        let note: String? = if info["isUsingOverage"]?.bool == true {
            "Using extra usage"
        } else if status == "allowed_warning" {
            "Close to the limit"
        } else {
            nil
        }
        let limit = Limit(
            id: type,
            name: Self.claudeLimitNames[type] ?? type.replacingOccurrences(of: "_", with: " ").capitalized,
            used: info["utilization"]?.double.map { min(1, max(0, $0)) },
            resetsAt: info["resetsAt"]?.double.map { Date(timeIntervalSince1970: $0) },
            isExhausted: status == "rejected",
            note: note
        )
        limitsUpdatedAt = Date()
        if let index = limits.firstIndex(where: { $0.id == type }) {
            limits[index] = limit
        } else {
            limits.append(limit)
            limits.sort { (Self.limitOrder.firstIndex(of: $0.id) ?? .max) < (Self.limitOrder.firstIndex(of: $1.id) ?? .max) }
        }
    }

    private static let claudeLimitNames = [
        "five_hour": "5-hour limit",
        "seven_day": "Weekly limit",
        "seven_day_opus": "Weekly · Opus",
        "seven_day_sonnet": "Weekly · Sonnet",
        "seven_day_overage_included": "Weekly · with extra usage",
        "overage": "Extra usage",
    ]
    private static let limitOrder = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet", "seven_day_overage_included", "overage"]
}

/// The last limits each agent reported, so a new chat shows them before its
/// first reply (Claude reports them only as it runs).
enum LimitsMemory {
    private static func key(_ providerID: String) -> String { "orbit.agentLimits.\(providerID)" }

    static func load(_ providerID: String, defaults: UserDefaults = .standard) -> SessionUsage.Limits? {
        defaults.data(forKey: key(providerID)).flatMap { try? JSONDecoder().decode(SessionUsage.Limits.self, from: $0) }
    }

    static func save(_ limits: SessionUsage.Limits, for providerID: String, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(limits) { defaults.set(data, forKey: key(providerID)) }
    }
}

/// Codex's limits, from its own session logs (`~/.codex/sessions/…/rollout-*.jsonl`):
/// every turn writes a `token_count` event with the account's `rate_limits`.
/// The ACP adapter keeps them to itself (only `/status` prints them), and the
/// logs need neither network nor credentials.
enum CodexLimits {
    static func latest(home: URL = codexHome) async -> SessionUsage.Limits? {
        await Task.detached(priority: .utility) { read(home: home) }.value
    }

    static var codexHome: URL {
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"], !home.isEmpty { return URL(fileURLWithPath: home) }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")
    }

    nonisolated static func read(home: URL) -> SessionUsage.Limits? {
        for file in recentLogs(in: home.appendingPathComponent("sessions")).prefix(5) {
            if let limits = lastLimits(in: file) { return limits }
        }
        return nil
    }

    /// Newest first; logs sit in year/month/day folders, so only the newest days are listed.
    nonisolated private static func recentLogs(in sessions: URL) -> [URL] {
        let manager = FileManager.default
        func newest(_ url: URL, _ count: Int) -> [URL] {
            let names = (try? manager.contentsOfDirectory(atPath: url.path)) ?? []
            return names.filter { !$0.hasPrefix(".") }.sorted(by: >).prefix(count).map { url.appendingPathComponent($0) }
        }
        var files: [URL] = []
        for year in newest(sessions, 2) {
            for month in newest(year, 2) {
                for day in newest(month, 3) {
                    files += newest(day, 1000).filter { $0.pathExtension == "jsonl" }
                }
                if !files.isEmpty { break }
            }
            if !files.isEmpty { break }
        }
        let modified = { (url: URL) in (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        return files.sorted { modified($0) > modified($1) }
    }

    /// The last `rate_limits` in the log's tail: logs grow large, limits are near the end.
    nonisolated static func lastLimits(in file: URL) -> SessionUsage.Limits? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 1 << 20 ? size - (1 << 20) : 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\":{") {
            if let limits = parse(line: String(line)) { return limits }
        }
        return nil
    }

    nonisolated static func parse(line: String) -> SessionUsage.Limits? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              let limits = payload["rate_limits"] as? [String: Any] else { return nil }
        let reached = limits["rate_limit_reached_type"] as? String
        var windows: [SessionUsage.Limit] = []
        for key in ["primary", "secondary"] {
            guard let window = limits[key] as? [String: Any] else { continue }
            let minutes = (window["window_minutes"] as? NSNumber)?.intValue
            windows.append(SessionUsage.Limit(
                id: "codex.\(key)",
                name: windowName(minutes),
                used: (window["used_percent"] as? NSNumber).map { min(1, max(0, $0.doubleValue / 100)) },
                resetsAt: (window["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
                isExhausted: reached != nil && ((window["used_percent"] as? NSNumber)?.doubleValue ?? 0) >= 100
            ))
        }
        var credits: String?
        if let info = limits["credits"] as? [String: Any] {
            if info["unlimited"] as? Bool == true {
                credits = "Unlimited"
            } else if info["has_credits"] as? Bool == true, let balance = info["balance"] as? String {
                credits = balance
            }
        }
        guard !windows.isEmpty || credits != nil else { return nil }
        let date = (object["timestamp"] as? String).flatMap(timestamp) ?? Date()
        return SessionUsage.Limits(windows: windows, plan: (limits["plan_type"] as? String).map(planName), credits: credits, updatedAt: date)
    }

    nonisolated private static func timestamp(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    nonisolated static func windowName(_ minutes: Int?) -> String {
        switch minutes {
        case 300: "5-hour limit"
        case 10080: "Weekly limit"
        case let minutes? where minutes % 1440 == 0: "\(minutes / 1440)-day limit"
        case let minutes? where minutes % 60 == 0: "\(minutes / 60)-hour limit"
        case let minutes?: "\(minutes)-minute limit"
        case nil: "Limit"
        }
    }

    nonisolated static func planName(_ plan: String) -> String {
        switch plan.lowercased() {
        case "prolite": "Pro Lite"
        case "plus": "Plus"
        case "pro": "Pro"
        case "team": "Team"
        case "business": "Business"
        case "enterprise": "Enterprise"
        case "edu": "Edu"
        case "free": "Free"
        default: plan.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
