import Foundation
@testable import OrbitAPI
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

    @Test(.timeLimit(.minutes(1))) func agentCommandReportsOutputAndExitCode() async throws {
        let terminal = AgentTerminal(request: AgentTerminalRequest(
            command: "printf '\\033[31mred\\033[0m\\nline two\\n'; exit 3",
            environment: ProcessInfo.processInfo.environment,
            directory: FileManager.default.temporaryDirectory
        ))
        let session = TerminalSession(agentTerminal: terminal)
        let status = await terminal.waitForExit()
        #expect(status == TerminalExitStatus(exitCode: 3))
        #expect(terminal.currentOutput().output == "red\nline two\n")
        #expect(!session.isRunning)
    }

    @Test(.timeLimit(.minutes(1))) func killingAnAgentCommandEndsItWithASignal() async throws {
        let terminal = AgentTerminal(request: AgentTerminalRequest(
            command: "sleep",
            arguments: ["30"],
            environment: ProcessInfo.processInfo.environment,
            directory: FileManager.default.temporaryDirectory
        ))
        let session = TerminalSession(agentTerminal: terminal)
        terminal.onKill = { session.kill() }
        try await Task.sleep(for: .milliseconds(200))
        terminal.kill()
        #expect(await terminal.waitForExit() == TerminalExitStatus(signal: "SIGTERM"))
    }
}

@MainActor
@Suite struct DisplayTerminalTests {
    @Test func showsStreamedOutputAndEndsWithTheAgentsExit() {
        let terminal = AgentTerminal(
            request: AgentTerminalRequest(command: "git status", environment: [:], directory: FileManager.default.temporaryDirectory),
            ownsProcess: false
        )
        let session = TerminalSession(displaying: terminal)
        var stopped = false
        terminal.onKill = { stopped = true }
        terminal.append("On branch master\n")
        terminal.append("\u{1B}[32mclean\u{1B}[0m\n")
        #expect(terminal.currentOutput().output == "On branch master\nclean\n")
        // The agent owns the process: nothing to stop from here.
        terminal.kill()
        #expect(!stopped)
        terminal.finish(TerminalExitStatus(exitCode: 0))
        #expect(!session.isRunning)

        // A tab opened again redraws everything, colors included.
        let reopened = TerminalSession(displaying: terminal)
        #expect(!reopened.isRunning)
        let screen = reopened.view.getTerminal()
        let text = (0..<screen.rows).compactMap { screen.getLine(row: $0)?.translateToString(trimRight: true) }.joined(separator: "\n")
        #expect(text.contains("$ git status\nOn branch master\nclean"))
    }
}

@Suite struct TerminalTextCaptureTests {
    private func capture(_ chunks: [String], limit: Int = 1 << 20) -> TerminalTextCapture {
        var capture = TerminalTextCapture(byteLimit: limit)
        for chunk in chunks { capture.feed(Array(chunk.utf8)) }
        return capture
    }

    @Test func stripsEscapeSequencesEvenAcrossChunks() {
        #expect(capture(["\u{1B}[1;3", "2mbold\u{1B}[0m plain"]).text == "bold plain")
        // Window title (OSC) ended by BEL, and by ESC \.
        #expect(capture(["\u{1B}]0;title\u{07}a", "\u{1B}]2;t\u{1B}\\b"]).text == "ab")
        #expect(capture(["\u{1B}(Bx"]).text == "x")
    }

    @Test func handlesLineEndingsAndRedraws() {
        #expect(capture(["one\r\ntwo\r", "\n"]).text == "one\ntwo\n")
        #expect(capture(["a\r\r\nb"]).text == "a\nb")
        // Progress bars redraw with a bare carriage return: only the last state stays.
        #expect(capture(["start\n10%\r50%", "\r100%\n"]).text == "start\n100%\n")
        #expect(capture(["abc\u{08}d"]).text == "abd")
    }

    @Test func keepsTheNewestBytesOnCharacterBoundaries() {
        let long = capture([String(repeating: "x", count: 100) + "end"], limit: 16)
        #expect(long.text == String(repeating: "x", count: 13) + "end")
        #expect(long.isTruncated)
        // A character split across chunks waits for its remaining bytes.
        var split = TerminalTextCapture(byteLimit: 64)
        let bytes = Array("é".utf8)
        split.feed(bytes[..<1])
        #expect(split.text == "")
        split.feed(bytes[1...])
        #expect(split.text == "é")
        #expect(!split.isTruncated)
        // Truncation never starts in the middle of a character.
        #expect(capture(["ééééééééééé"], limit: 16).text == "éééééééé")
    }

    @Test func decodesWaitStatus() {
        #expect(TerminalExitStatus(waitStatus: 3 << 8) == TerminalExitStatus(exitCode: 3))
        #expect(TerminalExitStatus(waitStatus: 0) == TerminalExitStatus(exitCode: 0))
        #expect(TerminalExitStatus(waitStatus: SIGKILL) == TerminalExitStatus(signal: "SIGKILL"))
    }
}
