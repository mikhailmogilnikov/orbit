import Foundation
import OrbitAPI

/// Reads a task's terminal output for errors and warnings (D137): `tsc`,
/// clang / Swift / Go (`file:line:col: error: …`), Rust (`error[E…]` then
/// `--> file:line:col`) and ESLint's per-file blocks. Only lines naming a
/// file that exists count, so a log line that looks like one is ignored.
struct TaskOutputParser {
    /// Where relative paths start: the task's folder, then the project's.
    let directories: [URL]
    private(set) var problems: [URL: [Diagnostic]] = [:]
    /// Bumped on every change, so the store republishes only then.
    private(set) var revision = 0
    /// The first local address it printed (a dev server's), for the browser (D143).
    private(set) var localURL: URL?

    private var line: [UInt8] = []
    private var afterCarriageReturn = false
    private var rustMessage: (severity: Diagnostic.Severity, message: String, code: String?)?
    private var eslintFile: URL?
    private var exists: [String: URL?] = [:]

    static let limit = 1000

    init(directories: [URL]) {
        self.directories = directories
    }

    mutating func reset() {
        localURL = nil
        guard !problems.isEmpty else { return }
        problems = [:]
        revision += 1
    }

    mutating func feed(_ bytes: some Sequence<UInt8>) {
        for byte in bytes {
            switch byte {
            case 0x0A:
                afterCarriageReturn = false
                finishLine()
            case 0x0D:
                afterCarriageReturn = true
            default:
                // A lone \r redraws the line (progress bars): what follows replaces it.
                if afterCarriageReturn {
                    afterCarriageReturn = false
                    line.removeAll(keepingCapacity: true)
                }
                if line.count < 4096 { line.append(byte) }
            }
        }
    }

    private mutating func finishLine() {
        defer { line.removeAll(keepingCapacity: true) }
        let raw = String(decoding: line, as: UTF8.self)
        // Watch modes (`tsc -w`, Jest) clear the screen before each new run.
        if raw.contains("\u{1B}[2J") || raw.contains("\u{1B}[3J") || raw.contains("\u{1B}c") { reset() }
        let text = Self.plain(raw)
        if localURL == nil, let match = text.firstMatch(of: Self.localAddress),
           var components = URLComponents(string: String(match.output)) {
            if components.host == "0.0.0.0" { components.host = "localhost" }
            localURL = components.url
            revision += 1
        }
        parse(text)
    }

    // `➜  Local:   http://localhost:5173/`, `- Local: http://127.0.0.1:3000`
    nonisolated(unsafe) static let localAddress = /https?:\/\/(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]|[\w-]+\.localhost)(?::\d+)?(?:\/[^\s'"]*)?/

    /// Without colors, cursor moves and window titles.
    static func plain(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        var result = ""
        var iterator = text.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            guard scalar == "\u{1B}" else {
                result.unicodeScalars.append(scalar)
                continue
            }
            switch iterator.next() {
            case "[":
                while let next = iterator.next(), !(0x40...0x7E).contains(next.value) {}
            case "]":
                // OSC, up to BEL or ESC \.
                while let next = iterator.next(), next != "\u{07}", next != "\u{1B}" {}
            default:
                break
            }
        }
        return result
    }

    mutating func parse(_ text: String) {
        let text = text.trimmingCharacters(in: .newlines)
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            eslintFile = nil
            return
        }
        if let match = text.wholeMatch(of: Self.tsc) {
            add(file: String(match.file), line: match.line, column: match.column, severity: severity(match.severity), message: String(match.message), source: String(match.code))
        } else if let match = text.wholeMatch(of: Self.compiler) {
            let message = String(match.message).trimmingCharacters(in: .whitespaces)
            guard match.severity != nil || !Self.notes.contains(where: message.hasPrefix) else { return }
            add(file: String(match.file), line: match.line, column: match.column, severity: severity(match.severity), message: message, source: nil)
        } else if let match = text.wholeMatch(of: Self.rustHeader) {
            rustMessage = (severity(match.severity), String(match.message), match.code.map(String.init))
        } else if let match = text.wholeMatch(of: Self.rustLocation), let pending = rustMessage {
            rustMessage = nil
            add(file: String(match.file), line: match.line, column: match.column, severity: pending.severity, message: pending.message, source: pending.code ?? "rustc")
        } else if let file = eslintFile, let match = text.wholeMatch(of: Self.eslintRow) {
            add(url: file, line: match.line, column: match.column, severity: severity(match.severity), message: String(match.message), source: match.rule.map(String.init) ?? "eslint")
        } else if text.hasPrefix("/"), !text.contains(":"), let url = resolve(text.trimmingCharacters(in: .whitespaces)) {
            eslintFile = url
        }
    }

    private func severity(_ word: Substring?) -> Diagnostic.Severity {
        word?.hasPrefix("warning") == true ? .warning : .error
    }

    private mutating func add(file: String, line: Substring, column: Substring, severity: Diagnostic.Severity, message: String, source: String?) {
        guard let url = resolve(file) else { return }
        add(url: url, line: line, column: column, severity: severity, message: message, source: source)
    }

    private mutating func add(url: URL, line: Substring, column: Substring, severity: Diagnostic.Severity, message: String, source: String?) {
        guard problems.values.reduce(0, { $0 + $1.count }) < Self.limit else { return }
        let position = SourcePosition(line: max(0, (Int(line) ?? 1) - 1), character: max(0, (Int(column) ?? 1) - 1))
        let diagnostic = Diagnostic(
            range: SourceRange(start: position, end: position), severity: severity,
            message: message.trimmingCharacters(in: .whitespaces), source: source
        )
        // Watch modes and reruns in one tab print the same error again.
        guard problems[url]?.contains(diagnostic) != true else { return }
        problems[url, default: []].append(diagnostic)
        revision += 1
    }

    private mutating func resolve(_ path: String) -> URL? {
        if let known = exists[path] { return known }
        var cleaned = path.trimmingCharacters(in: .whitespaces)
        if cleaned.hasPrefix("./") { cleaned.removeFirst(2) }
        let candidates = cleaned.hasPrefix("/") ? [URL(fileURLWithPath: cleaned)] : directories.map { $0.appendingPathComponent(cleaned) }
        var isDirectory: ObjCBool = false
        let found = candidates.first {
            FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }?.standardizedFileURL
        if exists.count < 2000 { exists[path] = found }
        return found
    }

    // `src/a.ts(12,5): error TS2322: Type …`
    nonisolated(unsafe) static let tsc = /(?<file>[^\s(][^(]*?)\((?<line>\d+),(?<column>\d+)\): (?<severity>error|warning) (?<code>TS\d+): (?<message>.+)/
    // `a.swift:3:7: error: …`, `src/a.ts:3:7 - error TS2322: …`, `./main.go:3:2: undefined: x`
    nonisolated(unsafe) static let compiler = /(?<file>[^\s:"'][^:"']*?\.\w+):(?<line>\d+):(?<column>\d+):?\s*(?:-\s*)?(?:(?<severity>fatal error|error|warning)(?:\[[^\]]*\])?:?\s*(?:TS\d+:\s*)?)?(?<message>\S.*)/
    nonisolated(unsafe) static let rustHeader = /(?<severity>error|warning)(?:\[(?<code>[A-Z]+\d+)\])?: (?<message>.+)/
    nonisolated(unsafe) static let rustLocation = /\s*--> (?<file>.+?):(?<line>\d+):(?<column>\d+)/
    // `  12:5  error  'x' is defined but never used  no-unused-vars`
    nonisolated(unsafe) static let eslintRow = /\s+(?<line>\d+):(?<column>\d+)\s+(?<severity>error|warning)\s+(?<message>.+?)(?:\s{2,}(?<rule>[\w@\/-]+))?/
    static let notes = ["note:", "remark:", "help:", "info:"]
}

/// Problems from every task tab of the window, for the Problems panel.
@MainActor
@Observable
final class TaskProblemStore: TaskProblems {
    private var byTab: [UUID: [URL: [Diagnostic]]] = [:]
    private(set) var problems: [FileProblems] = []

    func update(_ tab: UUID, _ problems: [URL: [Diagnostic]]) {
        guard byTab[tab] != problems else { return }
        byTab[tab] = problems.isEmpty ? nil : problems
        publish()
    }

    func remove(_ tab: UUID) {
        guard byTab.removeValue(forKey: tab) != nil else { return }
        publish()
    }

    private func publish() {
        var merged: [URL: [Diagnostic]] = [:]
        for tab in byTab.values {
            for (url, diagnostics) in tab { merged[url, default: []] += diagnostics }
        }
        problems = merged.map { FileProblems(url: $0.key, diagnostics: $0.value.sorted { $0.range.start < $1.range.start }) }
            .sorted { $0.url.path < $1.url.path }
    }
}
