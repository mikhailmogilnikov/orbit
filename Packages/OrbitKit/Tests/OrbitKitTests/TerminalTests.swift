import Foundation
@testable import OrbitTerminal
import Testing

@MainActor
@Suite struct TerminalTests {
    @Test(.timeLimit(.minutes(1))) func shellRunsInProjectFolderAndExits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-term-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let session = TerminalSession(directory: directory)
        let exited = AsyncStream<Void> { continuation in
            session.onExit = { _ in continuation.finish() }
        }
        session.view.send(txt: "printf 'ORBIT_%s\\n' \"$(basename \"$PWD\")\"; exit\n")
        for await _ in exited {}

        let terminal = session.view.getTerminal()
        let text = (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }.joined(separator: "\n")
        #expect(text.contains("ORBIT_\(directory.lastPathComponent)"))
    }
}
