@testable import OrbitExplorer
import Testing

@Suite struct FolderWatcherTests {
    @Test func ignoresGitInternalsAndChurningFolders() {
        let root = "/Users/me/project"
        #expect(FolderWatcher.matters("/Users/me/project/src/new.ts", under: root))
        #expect(FolderWatcher.matters("/Users/me/project/node_modules", under: root))
        #expect(!FolderWatcher.matters("/Users/me/project/.git/index", under: root))
        #expect(!FolderWatcher.matters("/Users/me/project/node_modules/react/index.js", under: root))
        #expect(!FolderWatcher.matters("/Users/me/project/.build/debug/App.o", under: root))
        #expect(!FolderWatcher.matters("/Users/me/project/src/.DS_Store", under: root))
        // Only the part inside the project counts.
        #expect(FolderWatcher.matters("/Users/me/node_modules/project/a.ts", under: "/Users/me/node_modules/project"))
    }
}
