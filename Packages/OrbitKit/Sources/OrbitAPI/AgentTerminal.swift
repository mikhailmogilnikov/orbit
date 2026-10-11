import Foundation
import Observation

/// Shows agent commands in terminals the user can watch. Implemented by the
/// Terminal plugin.
@MainActor
public protocol AgentTerminalHosting: AnyObject {
    /// Runs the command for the agent (ACP `terminal/*`); the user can type into it.
    func run(_ request: AgentTerminalRequest) -> AgentTerminal
    /// Only shows the output of a command the agent runs itself and streams to
    /// us (the `_meta.terminal_output` extension of Claude Code and Codex).
    func display(_ request: AgentTerminalRequest) -> AgentTerminal
}

public struct AgentTerminalRequest: Sendable {
    public var command: String
    public var arguments: [String]
    /// The complete environment for the command.
    public var environment: [String: String]
    public var directory: URL
    public var outputByteLimit: Int?

    public init(command: String, arguments: [String] = [], environment: [String: String], directory: URL, outputByteLimit: Int? = nil) {
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.directory = directory
        self.outputByteLimit = outputByteLimit
    }

    public var displayCommand: String { ([command] + arguments).joined(separator: " ") }
}

public struct TerminalExitStatus: Sendable, Equatable {
    public var exitCode: Int?
    public var signal: String?

    public init(exitCode: Int? = nil, signal: String? = nil) {
        self.exitCode = exitCode
        self.signal = signal
    }

    /// Decodes a raw `waitpid` status.
    public init(waitStatus status: Int32) {
        let signal = status & 0x7F
        if signal == 0 {
            self.init(exitCode: Int((status >> 8) & 0xFF))
        } else {
            self.init(signal: Self.name(ofSignal: signal))
        }
    }

    static func name(ofSignal signal: Int32) -> String {
        switch signal {
        case SIGHUP: "SIGHUP"
        case SIGINT: "SIGINT"
        case SIGQUIT: "SIGQUIT"
        case SIGKILL: "SIGKILL"
        case SIGTERM: "SIGTERM"
        default: "SIG\(signal)"
        }
    }

    public var succeeded: Bool { exitCode == 0 }
}

/// One agent command: its plain-text output and exit status, shared by the
/// terminal that runs it and the agent session that asked for it.
@MainActor
@Observable
public final class AgentTerminal: Identifiable {
    public static let defaultByteLimit = 1 << 20

    public nonisolated let id: String
    public let request: AgentTerminalRequest
    /// False for display-only terminals: the agent owns the process, so it can't be stopped from here.
    public let ownsProcess: Bool
    public private(set) var output = ""
    public private(set) var isTruncated = false
    public private(set) var exitStatus: TerminalExitStatus?
    /// False once the host closed its terminal tab.
    public private(set) var canReveal = true

    @ObservationIgnored public var onKill: () -> Void = {}
    @ObservationIgnored public var onReveal: () -> Void = {}
    @ObservationIgnored public var onRelease: () -> Void = {}
    @ObservationIgnored public var onFinish: () -> Void = {}
    /// Display-only terminals: output to draw, as it arrives.
    @ObservationIgnored public var onDisplay: (ArraySlice<UInt8>) -> Void = { _ in }

    @ObservationIgnored private var capture: TerminalTextCapture
    @ObservationIgnored private var waiters: [CheckedContinuation<TerminalExitStatus, Never>] = []
    @ObservationIgnored private var flushScheduled = false

    public init(id: String = UUID().uuidString, request: AgentTerminalRequest, ownsProcess: Bool = true) {
        self.id = id
        self.request = request
        self.ownsProcess = ownsProcess
        capture = TerminalTextCapture(byteLimit: request.outputByteLimit ?? Self.defaultByteLimit)
    }

    public var isRunning: Bool { exitStatus == nil }

    // MARK: Host side

    public func receive(_ bytes: ArraySlice<UInt8>) {
        capture.feed(bytes)
        guard !flushScheduled else { return }
        // Output arrives in many small chunks; publish it once per run-loop turn.
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in self?.flush() }
    }

    public func finish(_ status: TerminalExitStatus) {
        guard exitStatus == nil else { return }
        flush()
        exitStatus = status
        for waiter in waiters { waiter.resume(returning: status) }
        waiters.removeAll()
        onFinish()
    }

    public func hostDidCloseTerminal() {
        canReveal = false
    }

    // MARK: Client side

    /// Output the agent streamed for a display-only terminal.
    public func append(_ text: String) {
        let bytes = Array(text.utf8)[...]
        receive(bytes)
        onDisplay(bytes)
    }

    /// Everything captured so far, including bytes not yet published to views.
    public func currentOutput() -> (output: String, isTruncated: Bool) {
        flush()
        return (output, isTruncated)
    }

    public func waitForExit() async -> TerminalExitStatus {
        if let exitStatus { return exitStatus }
        return await withCheckedContinuation { waiters.append($0) }
    }

    public func kill() {
        if isRunning, ownsProcess { onKill() }
    }

    public func reveal() {
        if canReveal { onReveal() }
    }

    /// Kills the command if it still runs; the host may then drop its terminal.
    public func release() {
        kill()
        onRelease()
    }

    private func flush() {
        flushScheduled = false
        let text = capture.text
        if text != output { output = text }
        if capture.isTruncated != isTruncated { isTruncated = capture.isTruncated }
    }
}

/// Plain text from a terminal byte stream, for agents and compact previews:
/// escape sequences are dropped, carriage-return redraws (progress bars) keep
/// only their last state, and only the newest `byteLimit` bytes are kept.
public struct TerminalTextCapture: Sendable {
    public let byteLimit: Int
    private var bytes: [UInt8] = []
    private var droppedBytes = false
    private var state = State.text
    private var pendingCarriageReturn = false

    private enum State: Sendable {
        case text, escape, csi, string, stringEscape, charset
    }

    public init(byteLimit: Int) {
        self.byteLimit = max(16, byteLimit)
    }

    public var isTruncated: Bool { droppedBytes || bytes.count > byteLimit }

    public var text: String {
        var start = max(0, bytes.count - byteLimit)
        while start < bytes.count, bytes[start] & 0xC0 == 0x80 { start += 1 }
        return String(decoding: bytes[start..<max(start, completeEnd)], as: UTF8.self)
    }

    public mutating func feed(_ input: some Sequence<UInt8>) {
        for byte in input { consume(byte) }
        // Trim lazily so a long stream doesn't shift the buffer on every chunk.
        if bytes.count > byteLimit * 2 {
            bytes.removeFirst(bytes.count - byteLimit)
            droppedBytes = true
        }
    }

    /// End of the bytes that form whole UTF-8 characters; a character split
    /// across chunks waits for the rest.
    private var completeEnd: Int {
        var index = bytes.count - 1
        while index >= 0, index >= bytes.count - 4, bytes[index] & 0xC0 == 0x80 { index -= 1 }
        guard index >= 0 else { return bytes.count }
        let lead = bytes[index]
        let length = lead < 0x80 ? 1 : lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
        return bytes.count - index < length ? index : bytes.count
    }

    private mutating func consume(_ byte: UInt8) {
        switch state {
        case .text:
            if pendingCarriageReturn, byte != 0x0A, byte != 0x0D {
                // A bare carriage return redraws the line: keep only what follows.
                let lineStart = bytes.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
                bytes.removeSubrange(lineStart...)
            }
            pendingCarriageReturn = byte == 0x0D
            switch byte {
            case 0x1B:
                state = .escape
            case 0x08:
                while let last = bytes.last, last & 0xC0 == 0x80 { bytes.removeLast() }
                if let last = bytes.last, last != 0x0A { bytes.removeLast() }
            case 0x0A, 0x09:
                bytes.append(byte)
            case 0x00..<0x20, 0x7F:
                break
            default:
                bytes.append(byte)
            }
        case .escape:
            switch byte {
            case UInt8(ascii: "["): state = .csi
            // OSC, DCS, APC, PM: strings ended by BEL or ESC \.
            case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "_"), UInt8(ascii: "^"): state = .string
            case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "*"), UInt8(ascii: "+"), UInt8(ascii: "#"), UInt8(ascii: "%"): state = .charset
            default: state = .text
            }
        case .csi:
            if (0x40...0x7E).contains(byte) { state = .text }
        case .string:
            if byte == 0x07 { state = .text } else if byte == 0x1B { state = .stringEscape }
        case .stringEscape:
            state = byte == UInt8(ascii: "\\") ? .text : .string
        case .charset:
            state = .text
        }
    }
}
