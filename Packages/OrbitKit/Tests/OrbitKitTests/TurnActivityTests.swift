import Foundation
import OrbitACP
@testable import OrbitAgents
import OrbitUI
import SwiftUI
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
    @Test func leavesTheRunningToolToItsRow() {
        let user = TranscriptEntry(kind: .user, text: "fix it")
        let done = TranscriptEntry(kind: .tool)
        done.title = "Read Foo.swift"
        done.status = "completed"
        let running = TranscriptEntry(kind: .tool)
        running.title = "Edit `Bar.swift`"
        running.status = "in_progress"
        #expect(TurnActivity.describe([user, done, running]) == "Working")
        #expect(TurnActivity.describe([user, done]) == "Working")
    }

    @Test func fallsBackToWhatTheAgentStreams() {
        let user = TranscriptEntry(kind: .user, text: "hi")
        #expect(TurnActivity.describe([user, TranscriptEntry(kind: .thought, text: "hm")]) == "Thinking")
        #expect(TurnActivity.describe([user, TranscriptEntry(kind: .agent, text: "Sure")]) == "Writing")
        let streaming = TranscriptEntry(kind: .thought, text: "hm")
        streaming.startedAt = Date()
        #expect(TurnActivity.describe([user, streaming]) == "Working")
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

    @Test func foldsRunsOfToolCallsAndThoughts() {
        let user = TranscriptEntry(kind: .user, text: "go")
        let r1 = tool("read"), think = TranscriptEntry(kind: .thought), x1 = tool("execute", "failed"), x2 = tool("execute", "in_progress")
        let answer = TranscriptEntry(kind: .agent, text: "done"), r2 = tool("read")
        let rows = TranscriptRow.rows([user, r1, think, x1, x2, answer, r2])
        #expect(rows.map(\.id) == [user.id, r1.id, answer.id, r2.id])
        guard case .group(let group) = rows[1] else { Issue.record("no group"); return }
        #expect(group.map(\.id) == [r1.id, think.id, x1.id, x2.id])
        #expect(TranscriptRow.summary(group) == "Read a file, ran 2 commands")
        guard case .entry = rows[3] else { Issue.record("a lone call is grouped"); return }
    }

    @Test func callsAskingForPermissionStayOut() async throws {
        let asking = tool("edit", "pending")
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
            asking.permission = PermissionRequest(options: [], continuation: continuation)
            #expect(TranscriptRow.rows([tool("read"), tool("read"), asking, tool("read")]).count == 3)
            asking.permission?.cancel()
        }
    }

    @Test func emptyCallsHaveNothingToOpen() {
        let quiet = tool("execute")
        quiet.title = "`make build`"
        quiet.command = "make build"
        quiet.contents = [.text("```console\n\n```")]
        #expect(!quiet.hasDetails)
        quiet.contents = [.text("```console\nok\n```")]
        #expect(quiet.shownTexts == [FencedText("```console\nok\n```")])
        #expect(quiet.shownTexts.first?.language == "console" && quiet.shownTexts.first?.code == "ok")
        #expect(quiet.hasDetails)
    }

    @Test func titlesSetCodeApart() {
        let title = ToolCallRow.styledTitle("Run `make build` now")
        #expect(String(title.characters) == "Run make build now")
        #expect(title.runs.count == 3)
    }

    @Test func summaryNamesEveryKind() {
        let entries = [tool("search"), tool("search"), tool("edit"), tool("fetch"), tool("think")]
        #expect(TranscriptRow.summary(entries) == "Searched 2 times, edited a file, fetched a page, used a tool")
    }
}

@MainActor
@Suite struct ToolCardTests {
    @Test func diffStatsCountChangedLinesOnly() {
        let stats = CompactDiffView.stats(old: "a\nb\nc\nd", new: "a\nB\nc\nd\ne")
        #expect(stats.added == 2 && stats.removed == 1)
    }

    @Test func permissionKeysAvoidTheReviewKeys() {
        #expect(PermissionBar.shortcut(for: "allow_once") == KeyboardShortcut(.return, modifiers: .command))
        #expect(PermissionBar.shortcut(for: "reject_once") == KeyboardShortcut(.delete, modifiers: [.control, .command]))
        #expect(PermissionBar.shortcut(for: "reject_always") == nil)
    }
}

@Suite struct ChatLabelTests {
    @Test func thoughtsSayHowLongTheyTook() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(ThoughtLabel.text(startedAt: nil, endedAt: nil) == "Thought")
        #expect(ThoughtLabel.text(startedAt: start, endedAt: nil) == "Thinking…")
        #expect(ThoughtLabel.text(startedAt: start, endedAt: start.addingTimeInterval(8.2)) == "Thought for 8s")
    }

    @Test func planProgressCountsDoneSteps() {
        let items = [PlanItem(content: "a", status: "completed"), PlanItem(content: "b", status: "in_progress"), PlanItem(content: "c", status: "pending")]
        #expect(PlanItem.progress(items) == "1 of 3 done")
    }
}
