import Foundation
import OrbitAPI

/// Reads a task's terminal output for errors and warnings (D137): `tsc`,
/// clang / Swift / Go (`file:line:col: error: …`), Rust (`error[E…]` then
/// `--> file:line:col`) and ESLint's per-file blocks; Python tracebacks,
/// pytest, Jest, Vitest, esbuild and Vite (D220). Only lines naming a
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
    private var pythonFrames: [(url: URL, line: Substring)] = []
    private var pytestMessage: String?
    private var pytestLocation: (url: URL, line: Substring)?
    /// A failed test (Jest's `●`, Vitest's `FAIL`) waiting for its first line in the project.
    private var testFailure: (name: String, message: String?, source: String)?
    private var esbuildMessage: (severity: Diagnostic.Severity, message: String)?
    private var viteMessage: String?
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
        if parseRunners(text) { return }
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

    /// Runners that say what failed on one line and where on another (D220);
    /// true when the line was one of theirs.
    private mutating func parseRunners(_ text: String) -> Bool {
        // Python: `File "…", line N` frames (or one, for a SyntaxError), then the exception, unindented.
        if let match = text.wholeMatch(of: Self.pythonFrame) {
            if let url = resolve(String(match.file)) {
                pythonFrames.append((url, match.line))
                if pythonFrames.count > 200 { pythonFrames.removeFirst() }
            }
            return true
        }
        if let last = pythonFrames.last, text.first?.isWhitespace == false {
            let frames = pythonFrames
            pythonFrames = []
            guard let match = text.wholeMatch(of: Self.pythonException) else { return false }
            let frame = frames.last { isProjectFile($0.url) } ?? last
            let type = match.type.split(separator: ".").last.map(String.init) ?? String(match.type)
            add(url: frame.url, line: frame.line, column: "1", severity: type.hasSuffix("Warning") ? .warning : .error,
                message: match.message.map { "\(type): \($0)" } ?? type, source: "python")
            return true
        }
        if let match = text.wholeMatch(of: Self.pythonWarning) {
            add(file: String(match.file), line: match.line, column: "1", severity: .warning, message: "\(match.type): \(match.message)", source: "python")
            return true
        }

        // pytest: `E   …` lines and `file.py:12: in test_x` frames, ended by the next section;
        // or, in its long format, `file.py:12: AssertionError` after the `E` lines.
        if let match = text.wholeMatch(of: Self.pytestFrame), let url = resolve(String(match.file)) {
            if let type = match.type {
                add(url: url, line: match.line, column: "1", severity: .error, message: pytestMessage ?? String(type), source: "pytest")
                pytestMessage = nil
                pytestLocation = nil
            } else if isProjectFile(url) || pytestLocation == nil {
                pytestLocation = (url, match.line)
            }
            return true
        }
        if let match = text.wholeMatch(of: Self.pytestError) {
            if pytestMessage == nil { pytestMessage = String(match.message) }
            return true
        }
        if text.wholeMatch(of: Self.pytestSection) != nil {
            if let location = pytestLocation, let message = pytestMessage {
                add(url: location.url, line: location.line, column: "1", severity: .error, message: message, source: "pytest")
            }
            pytestMessage = nil
            pytestLocation = nil
            return true
        }

        // Jest (`● name`) and Vitest (`FAIL  file > name`): the message, then the first stack line in the project.
        if let match = text.wholeMatch(of: Self.jestHeader) {
            testFailure = (String(match.name), nil, "jest")
            return true
        }
        if let match = text.wholeMatch(of: Self.vitestHeader) {
            testFailure = (String(match.name), nil, "vitest")
            return true
        }
        if let failure = testFailure {
            if text.hasPrefix("Test Suites:") || text.hasPrefix(" Test Files") {
                testFailure = nil
                return false
            }
            if let match = text.wholeMatch(of: Self.jestStack) ?? text.wholeMatch(of: Self.vitestLocation) {
                if let url = resolve(String(match.file)), isProjectFile(url) {
                    testFailure = nil
                    add(url: url, line: match.line, column: match.column, severity: .error,
                        message: "\(failure.name): \(failure.message ?? "failed")", source: failure.source)
                }
                return true
            }
            if failure.message == nil, text.wholeMatch(of: Self.codeFrame) == nil {
                testFailure?.message = text.trimmingCharacters(in: .whitespaces)
                return true
            }
        }

        // esbuild (and Vite's dependency scan): `✘ [ERROR] message`, then `    src/a.ts:1:8:`.
        if let match = text.wholeMatch(of: Self.esbuildHeader) {
            esbuildMessage = (severity(match.severity), String(match.message))
            return true
        }
        if let pending = esbuildMessage, let match = text.wholeMatch(of: Self.esbuildLocation) {
            esbuildMessage = nil
            add(file: String(match.file), line: match.line, column: match.column, severity: pending.severity, message: pending.message, source: "esbuild")
            return true
        }

        // Vite: `[vite] Internal server error: …` or `[plugin:vite:vue] …`, then `File: /abs/App.vue:3:1`.
        if let match = text.firstMatch(of: Self.viteError) {
            var message = String(match.message)
            // `/abs/App.vue: Element is missing end tag.`
            if message.hasPrefix("/"), let separator = message.range(of: ": ") { message = String(message[separator.upperBound...]) }
            viteMessage = message
            return false
        }
        if let message = viteMessage, let match = text.wholeMatch(of: Self.viteFile), let url = resolve(String(match.file)) {
            viteMessage = nil
            let line = max(0, (Int(match.line) ?? 1) - 1), column = max(0, (Int(match.column ?? "1") ?? 1) - 1)
            // esbuild's own line for the same error came first, with the better message.
            if problems[url]?.contains(where: { $0.range.start == SourcePosition(line: line, character: column) }) != true {
                add(url: url, line: match.line, column: match.column ?? "1", severity: .error, message: message, source: "vite")
            }
            return true
        }
        return false
    }

    /// In the project, not a dependency's or the standard library's: where a traceback is worth pointing.
    private func isProjectFile(_ url: URL) -> Bool {
        let path = url.path
        guard !["/site-packages/", "/dist-packages/", "/node_modules/"].contains(where: path.contains) else { return false }
        return directories.contains { path.hasPrefix($0.standardizedFileURL.path + "/") }
    }

    private func severity(_ word: Substring?) -> Diagnostic.Severity {
        word?.lowercased().hasPrefix("warning") == true ? .warning : .error
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
        // Watch modes and reruns in one tab print the same error again; Vite prints esbuild's twice, in two forms.
        guard problems[url]?.contains(where: { $0.range == diagnostic.range && $0.message == diagnostic.message }) != true else { return }
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
    // esbuild says `ERROR:` / `WARNING:`.
    nonisolated(unsafe) static let compiler = /(?<file>[^\s:"'][^:"']*?\.\w+):(?<line>\d+):(?<column>\d+):?\s*(?:-\s*)?(?:(?<severity>fatal error|error|warning|ERROR|WARNING)(?:\[[^\]]*\])?:?\s*(?:TS\d+:\s*)?)?(?<message>\S.*)/
    nonisolated(unsafe) static let rustHeader = /(?<severity>error|warning)(?:\[(?<code>[A-Z]+\d+)\])?: (?<message>.+)/
    nonisolated(unsafe) static let rustLocation = /\s*--> (?<file>.+?):(?<line>\d+):(?<column>\d+)/
    // `  12:5  error  'x' is defined but never used  no-unused-vars`
    nonisolated(unsafe) static let eslintRow = /\s+(?<line>\d+):(?<column>\d+)\s+(?<severity>error|warning)\s+(?<message>.+?)(?:\s{2,}(?<rule>[\w@\/-]+))?/
    static let notes = ["note:", "remark:", "help:", "info:"]

    // `  File "/abs/main.py", line 3, in <module>`, `  File "x.py", line 1` (a SyntaxError)
    nonisolated(unsafe) static let pythonFrame = /\s*File "(?<file>[^"]+)", line (?<line>\d+)(?:, in .+)?/
    // `json.decoder.JSONDecodeError: Expecting …`, `SyntaxError: invalid syntax`, `KeyboardInterrupt`
    nonisolated(unsafe) static let pythonException = /(?<type>[A-Za-z_][\w.]*(?:Error|Exception|Warning|Exit|Interrupt|Iteration|Failure|Fault))(?::\s*(?<message>.+))?/
    // `/abs/a.py:3: DeprecationWarning: …`
    nonisolated(unsafe) static let pythonWarning = /(?<file>\S+\.py):(?<line>\d+): (?<type>\w*Warning): (?<message>.+)/
    // `test_a.py:2: in test_eq` (short tracebacks), `test_a.py:2: AssertionError` (long ones)
    nonisolated(unsafe) static let pytestFrame = /(?<file>[^\s:]+\.py):(?<line>\d+): (?:in \S+|(?<type>[A-Za-z_]\w*))/
    nonisolated(unsafe) static let pytestError = /E\s+(?<message>\S.*)/
    // `_____ test_eq _____`, `===== short test summary info =====`
    nonisolated(unsafe) static let pytestSection = /(?:_{3,} .+ _{3,}|={3,}.*)/
    nonisolated(unsafe) static let jestHeader = /\s*● (?<name>.+)/
    // ` FAIL  tests/sum.test.ts > math > adds`
    nonisolated(unsafe) static let vitestHeader = /\s*FAIL\s+\S+\s+>\s+(?<name>.+)/
    // `      at Object.toBe (tests/sum.test.js:4:21)`, `    at /abs/a.js:3:9`
    nonisolated(unsafe) static let jestStack = /\s*at (?:.+? \()?(?<file>[^\s()]+):(?<line>\d+):(?<column>\d+)\)?/
    // ` ❯ tests/sum.test.ts:5:21`
    nonisolated(unsafe) static let vitestLocation = /\s*❯ (?<file>\S+):(?<line>\d+):(?<column>\d+)/
    // The source lines Jest and Vitest show: `> 4 |   expect(…)`, `   |   ^`, `      5| })`
    nonisolated(unsafe) static let codeFrame = /\s*>?\s*\d*\s*\|.*/
    // `✘ [ERROR] Expected ";" but found "y"`, `▲ [WARNING] …`
    nonisolated(unsafe) static let esbuildHeader = /\s*(?:[✘▲X]\s*)?\[(?<severity>ERROR|WARNING)\]\s+(?<message>.+)/
    // `    src/bad.ts:1:8:`
    nonisolated(unsafe) static let esbuildLocation = /\s+(?<file>[^\s:][^:]*):(?<line>\d+):(?<column>\d+):/
    // `[vite] Internal server error: …`, `[plugin:vite:vue] …`, `[vite:esbuild] …` (a build)
    nonisolated(unsafe) static let viteError = /\[(?:vite\] (?:Internal server error|Pre-transform error):|(?:plugin:|vite:)[^\]]+\]) (?<message>\S.*)/
    // `  File: /abs/src/App.vue:3:1`, `file: /abs/src/bad.ts:1:8` (a build)
    nonisolated(unsafe) static let viteFile = /\s*[Ff]ile: (?<file>[^:]+):(?<line>\d+)(?::(?<column>\d+))?/
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

/// A path the terminal found under a ⌘-click (D148): `src/a.ts:12:5`,
/// `a.ts(12,5)`, `./main.go:8`, `file:///…`; nil for web links and paths that don't exist.
enum TerminalLink {
    nonisolated(unsafe) static let position = /(?<path>.+?)(?::(?<line>\d+)(?::(?<column>\d+))?|\((?<pline>\d+),(?<pcolumn>\d+)\))?:?/

    static func file(_ link: String, in directories: [URL]) -> (url: URL, line: Int?, column: Int?)? {
        var text = link.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("file://") {
            guard let url = URL(string: text), url.isFileURL else { return nil }
            text = url.path
        } else if text.contains("://") || text.hasPrefix("mailto:") {
            return nil
        }
        guard let match = text.wholeMatch(of: position) else { return nil }
        var path = String(match.path)
        if path.hasPrefix("~/") { path = NSHomeDirectory() + path.dropFirst() }
        if path.hasPrefix("./") { path.removeFirst(2) }
        let candidates = path.hasPrefix("/") ? [URL(fileURLWithPath: path)] : directories.map { $0.appendingPathComponent(path) }
        var isDirectory: ObjCBool = false
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory) && !isDirectory.boolValue }) else {
            return nil
        }
        let line = (match.line ?? match.pline).flatMap { Int($0) }.map { max(0, $0 - 1) }
        let column = (match.column ?? match.pcolumn).flatMap { Int($0) }.map { max(0, $0 - 1) }
        return (url.standardizedFileURL, line, column)
    }
}
