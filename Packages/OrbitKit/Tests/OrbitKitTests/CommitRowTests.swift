import Foundation
@testable import OrbitGit
import Testing

@Suite struct CommitRowTests {
    @Test func refBadgesMergeABranchWithItsRemote() {
        let badges = RefBadges.badges(["HEAD -> main", "origin/main", "origin/HEAD", "tag: v1.2", "origin/feature"])
        #expect(badges == [
            RefBadges.Badge(name: "main", kind: .synced, isHead: true),
            RefBadges.Badge(name: "origin/feature", kind: .remote),
            RefBadges.Badge(name: "v1.2", kind: .tag),
        ])
        #expect(RefBadges.badges(["SOF-1", "origin/SOF-1"]) == [RefBadges.Badge(name: "SOF-1", kind: .synced)])
        #expect(RefBadges.isHead(["HEAD -> main"]) && !RefBadges.isHead(["main"]))
    }
}
