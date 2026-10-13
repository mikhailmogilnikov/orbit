import Foundation
import os

public struct JSONRPCError: Error, Sendable, LocalizedError {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public var errorDescription: String? { message }

    public static func methodNotFound(_ method: String) -> JSONRPCError {
        JSONRPCError(code: -32601, message: "Method not found: \(method)")
    }

    public static let processExited = JSONRPCError(code: -32000, message: "The process exited")
}

/// JSON-RPC 2.0 over a child process' stdio: newline-delimited (ACP agents) or
/// with `Content-Length` headers (language servers).
///
/// All mutable state is confined to `queue`; that is what makes the
/// `@unchecked Sendable` sound.
public final class JSONRPCConnection: @unchecked Sendable {
    public typealias NotificationHandler = @Sendable (_ method: String, _ params: JSONValue) -> Void
    public typealias RequestHandler = @Sendable (_ method: String, _ params: JSONValue) async throws -> JSONValue
    public typealias ExitHandler = @Sendable (_ status: Int32, _ stderrTail: String) -> Void

    public enum Framing: Sendable {
        /// One message per line (ACP).
        case newlineDelimited
        /// `Content-Length: N\r\n\r\n` before each message (LSP).
        case contentLength
    }

    private let framing: Framing

    private let logger = Logger(subsystem: "dev.orbit", category: "jsonrpc")
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let queue = DispatchQueue(label: "dev.orbit.jsonrpc")

    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var readBuffer = Data()
    private var stderrTail = ""
    private var exited = false

    private let onNotification: NotificationHandler
    private let onRequest: RequestHandler
    private let onExit: ExitHandler

    public init(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL,
        framing: Framing = .newlineDelimited,
        onNotification: @escaping NotificationHandler,
        onRequest: @escaping RequestHandler,
        onExit: @escaping ExitHandler
    ) {
        self.onNotification = onNotification
        self.onRequest = onRequest
        self.onExit = onExit
        self.framing = framing
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectory
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    public func start() throws {
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.queue.async { self.consume(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.queue.async {
                self.stderrTail += String(decoding: data, as: UTF8.self)
                if self.stderrTail.count > 8_000 { self.stderrTail = String(self.stderrTail.suffix(8_000)) }
            }
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            // Give the readers a moment to drain stderr before reporting.
            self.queue.asyncAfter(deadline: .now() + 0.1) {
                self.exited = true
                let failed = self.pending
                self.pending.removeAll()
                for continuation in failed.values { continuation.resume(throwing: JSONRPCError.processExited) }
                self.onExit(process.terminationStatus, self.stderrTail)
            }
        }
        try process.run()
    }

    public func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }

    public var processIdentifier: Int32 { process.processIdentifier }

    // MARK: Outgoing

    public func request(_ method: String, _ params: JSONValue = .object([:])) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard !self.exited else {
                    continuation.resume(throwing: JSONRPCError.processExited)
                    return
                }
                let id = self.nextID
                self.nextID += 1
                self.pending[id] = continuation
                self.write(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params])
            }
        }
    }

    public func notify(_ method: String, _ params: JSONValue = .object([:])) {
        queue.async {
            self.write(["jsonrpc": "2.0", "method": .string(method), "params": params])
        }
    }

    /// Must be called on `queue`.
    private func write(_ message: JSONValue) {
        guard !exited, var data = try? JSONEncoder().encode(message) else { return }
        switch framing {
        case .newlineDelimited: data.append(0x0A)
        case .contentLength: data = Data("Content-Length: \(data.count)\r\n\r\n".utf8) + data
        }
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            logger.error("write failed: \(error.localizedDescription)")
        }
    }

    // MARK: Incoming

    /// Must be called on `queue`.
    private func consume(_ data: Data) {
        readBuffer.append(data)
        if framing == .contentLength {
            consumeFramed()
            return
        }
        while let newline = readBuffer.firstIndex(of: 0x0A) {
            let line = readBuffer[readBuffer.startIndex..<newline]
            readBuffer.removeSubrange(readBuffer.startIndex...newline)
            guard !line.isEmpty else { continue }
            guard let message = try? JSONDecoder().decode(JSONValue.self, from: line) else {
                logger.debug("non-JSON line from agent: \(String(decoding: line, as: UTF8.self))")
                continue
            }
            handle(message)
        }
    }

    private static let headerEnd = Data("\r\n\r\n".utf8)

    /// Must be called on `queue`.
    private func consumeFramed() {
        while let separator = readBuffer.range(of: Self.headerEnd) {
            let header = String(decoding: readBuffer[readBuffer.startIndex..<separator.lowerBound], as: UTF8.self)
            let length = header.split(separator: "\r\n").lazy.compactMap { line -> Int? in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else { return nil }
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }.first
            guard let length else {
                // Not a header we understand: drop it rather than stall the stream.
                readBuffer.removeSubrange(readBuffer.startIndex..<separator.upperBound)
                continue
            }
            guard readBuffer.distance(from: separator.upperBound, to: readBuffer.endIndex) >= length else { return }
            let end = readBuffer.index(separator.upperBound, offsetBy: length)
            let body = readBuffer[separator.upperBound..<end]
            if let message = try? JSONDecoder().decode(JSONValue.self, from: body) {
                handle(message)
            } else {
                logger.debug("non-JSON message from server")
            }
            readBuffer.removeSubrange(readBuffer.startIndex..<end)
        }
    }

    /// Must be called on `queue`.
    private func handle(_ message: JSONValue) {
        let id = message["id"]
        if let method = message["method"]?.string {
            let params = message["params"] ?? .null
            guard let id else {
                onNotification(method, params)
                return
            }
            let handler = onRequest
            Task {
                let response: JSONValue
                do {
                    let result = try await handler(method, params)
                    response = ["jsonrpc": "2.0", "id": id, "result": result]
                } catch let error as JSONRPCError {
                    response = ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(error.code)), "message": .string(error.message)]]
                } catch {
                    response = ["jsonrpc": "2.0", "id": id, "error": ["code": -32603, "message": .string(error.localizedDescription)]]
                }
                self.queue.async { self.write(response) }
            }
            return
        }

        guard let numericID = id?.int, let continuation = pending.removeValue(forKey: numericID) else { return }
        if let error = message["error"] {
            continuation.resume(throwing: JSONRPCError(
                code: error["code"]?.int ?? -32603,
                message: error["message"]?.string ?? "Unknown error",
                data: error["data"]
            ))
        } else {
            continuation.resume(returning: message["result"] ?? .null)
        }
    }
}
