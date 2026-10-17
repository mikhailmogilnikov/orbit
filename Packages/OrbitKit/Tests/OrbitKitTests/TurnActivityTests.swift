import Foundation
import OrbitACP
@testable import OrbitAgents
import Testing

@Suite struct SlashCommandTests {
    @Test func parsesTheAgentsList() {
        let json: JSONValue = ["name": "review", "description": "Review the diff", "input": ["hint": "branch"]]
        let command = SlashCommand(json)
        #expect(command == SlashCommand(name: "review", description: "Review the diff", hint: "branch"))
        #expect(SlashCommand(["description": "nameless"]) == nil)
    }

    @Test func prefixMatchesComeFirst() {
        let commands = ["init", "review", "pr-review", "compact"].map { SlashCommand(name: $0) }
        #expect(SlashCommand.matches("rev", in: commands).map(\.name) == ["review", "pr-review"])
        #expect(SlashCommand.matches("REV", in: commands).map(\.name) == ["review", "pr-review"])
        #expect(SlashCommand.matches("", in: commands).count == 4)
        #expect(SlashCommand.matches("zzz", in: commands).isEmpty)
    }
}

@MainActor
@Suite struct TurnActivityTests {
    @Test func namesTheRunningTool() {
        let user = TranscriptEntry(kind: .user, text: "fix it")
        let done = TranscriptEntry(kind: .tool)
        done.title = "Read Foo.swift"
        done.status = "completed"
        let running = TranscriptEntry(kind: .tool)
        running.title = "Edit `Bar.swift`"
        running.status = "in_progress"
        #expect(TurnActivity.describe([user, done, running]) == "Edit Bar.swift")
        #expect(TurnActivity.describe([user, done]) == "Working")
    }

    @Test func fallsBackToWhatTheAgentStreams() {
        let user = TranscriptEntry(kind: .user, text: "hi")
        #expect(TurnActivity.describe([user, TranscriptEntry(kind: .thought, text: "hm")]) == "Thinking")
        #expect(TurnActivity.describe([user, TranscriptEntry(kind: .agent, text: "Sure")]) == "Writing")
        // A tool still running from an earlier turn doesn't count.
        let stale = TranscriptEntry(kind: .tool)
        stale.title = "Old"
        stale.status = "pending"
        #expect(TurnActivity.describe([stale, user]) == "Working")
    }

    @Test func turnFilesAreNewOrChangedOnes() {
        let a = URL(fileURLWithPath: "/p/a.swift"), b = URL(fileURLWithPath: "/p/b.swift"), c = URL(fileURLWithPath: "/p/c.swift")
        let before = [a: DiffStats(added: 1, removed: 0), b: DiffStats(added: 2, removed: 2)]
        let after = [(a, DiffStats(added: 1, removed: 0)), (b, DiffStats(added: 5, removed: 2)), (c, DiffStats(added: 3, removed: 0))]
        #expect(TurnActivity.changedFiles(before: before, after: after) == [b, c])
    }

    @Test func durationsReadShort() {
        #expect(TurnSummaryView.format(125) == "2m 5s")
        #expect(TurnSummaryView.format(0.2) == "1s")
    }
}
