import Foundation
@testable import OrbitAgents
import OrbitAPI
@testable import OrbitReview
import Testing

@Suite struct AgentWorkflowTests {
    @Test func pullRequestStatusFromGh() {
        let failing = #"{"number": 12, "state": "OPEN", "statusCheckRollup": [{"status": "COMPLETED", "conclusion": "SUCCESS"}, {"status": "COMPLETED", "conclusion": "FAILURE"}]}"#
        #expect(IsolatedCopies.parseStatus(failing) == PullRequestStatus(number: 12, state: .open, checks: .failing))
        let pending = #"{"number": 3, "state": "OPEN", "statusCheckRollup": [{"status": "IN_PROGRESS", "conclusion": ""}, {"state": "SUCCESS"}]}"#
        #expect(IsolatedCopies.parseStatus(pending)?.checks == .pending)
        let passing = #"{"number": 3, "state": "OPEN", "statusCheckRollup": [{"state": "SUCCESS"}, {"status": "COMPLETED", "conclusion": "SKIPPED"}]}"#
        #expect(IsolatedCopies.parseStatus(passing)?.checks == .passing)
        #expect(IsolatedCopies.parseStatus(#"{"number": 4, "state": "MERGED", "statusCheckRollup": []}"#) == PullRequestStatus(number: 4, state: .merged, checks: .none))
        #expect(IsolatedCopies.parseStatus("not json") == nil)
    }

    @Test func queuedMessagesAndNotesSurviveEncoding() throws {
        let saved = SavedSession(providerID: "codex", sessionID: "s1", title: "t", cwd: "/p", updatedAt: Date(timeIntervalSince1970: 0),
                                 queued: [SavedQueuedMessage(text: "then run tests", files: ["/p/a.swift"])])
        let decoded = try JSONDecoder().decode(SavedSession.self, from: JSONEncoder().encode(saved))
        #expect(decoded.queued == saved.queued)
        // Tabs saved before D131 have no queue.
        let old = #"{"providerID": "codex", "sessionID": "s1", "title": "t", "cwd": "/p", "updatedAt": 0}"#
        #expect(try JSONDecoder().decode(SavedSession.self, from: Data(old.utf8)).queued == nil)

        let note = ReviewComment(url: URL(fileURLWithPath: "/p/a.swift"), lines: 2...4, code: "x", removed: "y", text: "why?")
        #expect(try JSONDecoder().decode(ReviewComment.self, from: JSONEncoder().encode(note)) == note)
        // Copies saved before D133 have no pull request.
        let copy = #"{"project": "file:///p", "directory": "file:///c", "checkpoint": "abc"}"#
        #expect(try JSONDecoder().decode(IsolatedCopy.self, from: Data(copy.utf8)).pullRequest == nil)
    }
}
