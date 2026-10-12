import Foundation
import OrbitACP

/// What a session costs: context fill, spending, plan limits and tokens.
/// Agents report it piecemeal (`usage_update`, each prompt's `usage`), so
/// every part is optional until the agent says something about it.
struct SessionUsage: Equatable {
    struct Limit: Equatable, Identifiable {
        var id: String
        var name: String
        /// 0...1 of the window used.
        var used: Double?
        var resetsAt: Date?
        var isExhausted: Bool
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

    /// A `usage_update` session update.
    mutating func apply(update json: JSONValue) {
        if let used = json["used"]?.int { contextUsed = used }
        if let size = json["size"]?.int, size > 0 { contextSize = size }
        if let amount = json["cost"]?["amount"]?.double {
            cost = amount
            currency = json["cost"]?["currency"]?.string ?? currency
        }
        if let info = json["_meta"]?["_claude/rateLimit"] { applyClaudeLimit(info) }
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
        let limit = Limit(
            id: type,
            name: Self.claudeLimitNames[type] ?? type.replacingOccurrences(of: "_", with: " ").capitalized,
            used: info["utilization"]?.double.map { min(1, max(0, $0)) },
            resetsAt: info["resetsAt"]?.double.map { Date(timeIntervalSince1970: $0) },
            isExhausted: info["status"]?.string == "rejected"
        )
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
