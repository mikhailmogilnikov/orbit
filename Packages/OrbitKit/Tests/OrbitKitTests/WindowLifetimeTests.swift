import Foundation
@testable import OrbitAPI
import OrbitKit
import Testing

/// A closed window (D101) must free its whole project: every plugin, buffer and model.
@MainActor
@Suite(.serialized) struct WindowLifetimeTests {
    @Test func closedWindowFreesItsHost() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-window-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("a.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        weak var weakHost: PluginHost?
        weak var weakWorkspace: Workspace?
        do {
            let host = PluginHost(plugins: BuiltinPlugins.all, root: root)
            weakHost = host
            weakWorkspace = host.workspace
            host.workspace.openFile(file)
            _ = host.workspace.documents.document(for: file)
            try await Task.sleep(for: .milliseconds(300))
            host.shutdown()
            #expect(host.commands.all.isEmpty)
            #expect(host.workspace.documents.open.isEmpty)
        }
        // Observers fire once more and stop; tasks in flight finish.
        for _ in 0..<150 where weakWorkspace != nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(weakHost == nil)
        #expect(weakWorkspace == nil)

        // The window's tabs are still saved for the folder's next window.
        let again = Workspace()
        again.openFolder(root)
        #expect(again.tabs.map(\.url) == [file])
    }
}
