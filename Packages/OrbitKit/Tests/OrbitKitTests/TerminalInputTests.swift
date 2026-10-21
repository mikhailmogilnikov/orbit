import AppKit
@testable import OrbitTerminal
import Testing

/// Terminal.app's and iTerm's mouse and drop conveniences (D219).
@MainActor
@Suite struct TerminalInputTests {
    @Test func droppedPathsBecomeShellWords() {
        #expect(TerminalKeys.shellQuoted("/Users/me/src/main.swift") == "/Users/me/src/main.swift")
        #expect(TerminalKeys.shellQuoted("/Users/me/Мои файлы") == "'/Users/me/Мои файлы'")
        #expect(TerminalKeys.shellQuoted("/tmp/it's") == "'/tmp/it'\\''s'")
    }

    @Test func optionClickSendsArrowsAcrossWrappedRows() {
        #expect(TerminalKeys.arrows(from: (5, 0), to: (2, 0), cols: 80, application: false) == Array([[UInt8]](repeating: [0x1B, 0x5B, 0x44], count: 3).joined()))
        #expect(TerminalKeys.arrows(from: (78, 0), to: (1, 1), cols: 80, application: true) == Array([[UInt8]](repeating: [0x1B, 0x4F, 0x43], count: 3).joined()))
        #expect(TerminalKeys.arrows(from: (4, 2), to: (4, 2), cols: 80, application: false).isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func optionClickMovesTheShellsCursor() async throws {
        let session = TerminalSession(directory: FileManager.default.temporaryDirectory)
        defer { session.terminate() }
        let view = session.view
        let terminal = view.getTerminal()
        func waitFor(_ done: () -> Bool) async throws {
            for _ in 0..<100 {
                if done() { return }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        func line() -> String {
            terminal.getLine(row: terminal.getCursorLocation().y)?.translateToString(trimRight: true) ?? ""
        }
        // Typed before the shell edits its line, keys only echo: wait for it to run a command.
        view.send(txt: "printf 'READ%s\\n' Y\r")
        try await waitFor {
            (0..<terminal.rows).contains { terminal.getLine(row: $0)?.translateToString(trimRight: true) == "READY" } && !line().contains("READ")
        }
        try await Task.sleep(for: .milliseconds(300))
        view.send(txt: "echo abcdef")
        try await waitFor { line().hasSuffix("echo abcdef") && terminal.getCursorLocation().x == line().count }
        let end = terminal.getCursorLocation()
        #expect(line().hasSuffix("echo abcdef"))

        let scale = view.window?.backingScaleFactor ?? 2
        let width = (view.font.advancement(forGlyph: view.font.glyph(withName: "W")).width * scale).rounded() / scale
        let height = view.caretFrame.height
        let target = end.x - 4
        let point = NSPoint(x: (CGFloat(target) + 0.5) * width, y: view.frame.height - (CGFloat(end.y) + 0.5) * height)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: .option, timestamp: 0,
                                                       windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            type == .leftMouseDown ? view.mouseDown(with: event) : view.mouseUp(with: event)
        }
        try await waitFor { terminal.getCursorLocation().x == target }
        #expect(terminal.getCursorLocation().x == target)
    }

    @Test func rightClickOffersCopyPasteAndClear() throws {
        let session = TerminalSession(directory: FileManager.default.temporaryDirectory)
        defer { session.terminate() }
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try #require(session.view.menu(for: event))
        #expect(menu.items.map(\.title) == ["Copy", "Paste", "Select All", "", "Clear"])
        #expect(menu.items.first?.isEnabled == false)
    }
}
