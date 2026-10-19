import Foundation
import OrbitACP
@testable import OrbitAgents
import Testing

@Suite struct SessionUsageTests {
    @Test func contextCostAndClaudeLimits() {
        var usage = SessionUsage()
        #expect(usage.isEmpty)
        usage.apply(update: ["sessionUpdate": "usage_update", "used": 50_000, "size": 200_000, "cost": ["amount": 1.25, "currency": "USD"]])
        #expect(usage.contextFraction == 0.25)
        #expect(usage.cost == 1.25)

        usage.apply(update: ["used": 50_000, "size": 200_000, "_meta": ["_claude/rateLimit": [
            "status": "allowed", "rateLimitType": "seven_day", "utilization": 0.4, "resetsAt": 1_800_000_000,
        ]]])
        usage.apply(update: ["used": 60_000, "size": 200_000, "_meta": ["_claude/rateLimit": [
            "status": "rejected", "rateLimitType": "five_hour", "utilization": 1.0,
        ]]])
        usage.apply(update: ["used": 60_000, "size": 200_000, "_meta": ["_claude/rateLimit": [
            "status": "allowed", "rateLimitType": "seven_day", "utilization": 0.45,
        ]]])
        #expect(usage.limits.map(\.id) == ["five_hour", "seven_day"])
        #expect(usage.limits[0].isExhausted)
        #expect(usage.limits[1].used == 0.45)
        #expect(usage.cost == 1.25)
    }

    @Test func turnsAddUp() {
        var usage = SessionUsage()
        usage.apply(turn: ["inputTokens": 10, "outputTokens": 5, "totalTokens": 15])
        usage.apply(turn: ["inputTokens": 20, "outputTokens": 5, "cachedReadTokens": 100, "totalTokens": 125])
        usage.apply(turn: nil)
        #expect(usage.tokens?.input == 30)
        #expect(usage.tokens?.cacheRead == 100)
        #expect(usage.turns == 2)
    }
}

@Suite struct PlanLimitsTests {
    private let line = #"{"timestamp":"2026-10-18T16:45:20.123Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":42.0,"window_minutes":300,"resets_at":1792946804},"secondary":{"used_percent":100.0,"window_minutes":10080,"resets_at":1793000000},"credits":{"has_credits":false,"unlimited":false,"balance":"0"},"individual_limit":null,"spend_control_reached":null,"plan_type":"prolite","rate_limit_reached_type":"secondary"}}}"#

    @Test func readsCodexLimitsFromItsLog() throws {
        let limits = try #require(CodexLimits.parse(line: line))
        #expect(limits.plan == "Pro Lite")
        #expect(limits.credits == nil)
        #expect(limits.windows.map(\.name) == ["5-hour limit", "Weekly limit"])
        #expect(limits.windows[0].used == 0.42 && !limits.windows[0].isExhausted)
        #expect(limits.windows[1].isExhausted)
        #expect(limits.windows[0].resetsAt == Date(timeIntervalSince1970: 1792946804))
        #expect(abs(limits.updatedAt.timeIntervalSince1970 - 1_792_341_920.123) < 0.01)
    }

    @Test func findsTheLastLimitsInTheNewestLog() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let day = home.appendingPathComponent("sessions/2026/10/18")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let older = line.replacingOccurrences(of: "42.0", with: "10.0")
        try (older + "\n" + #"{"type":"response_item"}"# + "\n" + line + "\n" + #"{"type":"turn_context"}"# + "\n")
            .write(to: day.appendingPathComponent("rollout-a.jsonl"), atomically: true, encoding: .utf8)
        #expect(CodexLimits.read(home: home)?.windows.first?.used == 0.42)
    }

    @Test func newerLimitsWin() {
        var usage = SessionUsage()
        let window = SessionUsage.Limit(id: "w", name: "Weekly", used: 0.5, resetsAt: nil, isExhausted: false)
        usage.apply(limits: .init(windows: [window], plan: "Pro", updatedAt: Date(timeIntervalSince1970: 200)))
        usage.apply(limits: .init(windows: [], plan: nil, updatedAt: Date(timeIntervalSince1970: 100)))
        #expect(usage.limits == [window] && usage.plan == "Pro")
        #expect(!usage.isEmpty)
    }

    @Test func remembersLimitsPerAgent() throws {
        let defaults = try #require(UserDefaults(suiteName: "orbit.tests.\(UUID().uuidString)"))
        let limits = SessionUsage.Limits(windows: [.init(id: "five_hour", name: "5-hour limit", used: 0.3, resetsAt: nil, isExhausted: false)],
                                         plan: nil, updatedAt: Date(timeIntervalSince1970: 1000))
        LimitsMemory.save(limits, for: "claude-acp", defaults: defaults)
        #expect(LimitsMemory.load("claude-acp", defaults: defaults) == limits)
        #expect(LimitsMemory.load("codex-acp", defaults: defaults) == nil)
    }

    @Test func resetsReadShort() {
        let now = Date(timeIntervalSince1970: 0)
        #expect(UsageFormat.reset(now.addingTimeInterval(42 * 60 - 5), now: now) == "Resets in 42m")
        #expect(UsageFormat.reset(now.addingTimeInterval((2 * 60 + 14) * 60), now: now).hasPrefix("Resets in 2h 14m · "))
        #expect(UsageFormat.reset(now.addingTimeInterval(-1), now: now) == "Reset")
    }

    @Test func onlyPressingLimitsGetADot() {
        let now = Date(timeIntervalSince1970: 0)
        let calm = SessionUsage.Limit(id: "a", name: "A", used: 0.5, resetsAt: nil, isExhausted: false)
        let close = SessionUsage.Limit(id: "b", name: "B", used: 0.95, resetsAt: now.addingTimeInterval(60), isExhausted: false)
        let over = SessionUsage.Limit(id: "c", name: "C", used: 1, resetsAt: now.addingTimeInterval(-60), isExhausted: true)
        #expect(UsageFormat.pressingLimit([calm, close, over], now: now)?.id == "b")
        #expect(UsageFormat.pressingLimit([calm], now: now) == nil)
    }
}
