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

@MainActor
@Suite struct TranscriptRowTests {
    private func tool(_ kind: String, _ status: String = "completed") -> TranscriptEntry {
        let entry = TranscriptEntry(kind: .tool)
        entry.toolKind = kind
        entry.title = kind
        entry.status = status
        return entry
    }

    @Test func groupsRunsOfQuietCalls() {
        let user = TranscriptEntry(kind: .user, text: "go")
        let r1 = tool("read"), r2 = tool("read"), s1 = tool("search", "in_progress"), edit = tool("edit"), r3 = tool("read")
        let rows = TranscriptRow.rows([user, r1, r2, s1, edit, r3])
        #expect(rows.map(\.id) == [user.id, r1.id, edit.id, r3.id])
        guard case .group(let group) = rows[1] else { Issue.record("no group"); return }
        #expect(group.map(\.id) == [r1.id, r2.id, s1.id])
        #expect(TranscriptRow.summary(group) == "Read 2 files · 1 search")
        guard case .entry = rows[3] else { Issue.record("a lone read is grouped"); return }
    }

    @Test func failedCallsStayVisible() {
        let rows = TranscriptRow.rows([tool("read"), tool("read", "failed"), tool("read")])
        #expect(rows.count == 3)
    }
}
