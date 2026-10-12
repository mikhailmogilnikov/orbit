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
