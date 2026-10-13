import Foundation

/// A place in a text as language servers count it: 0-based line and UTF-16
/// offset in that line (the same units as `NSString`, so converting is cheap).
public struct SourcePosition: Sendable, Hashable, Comparable {
    public var line: Int
    public var character: Int

    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.line, lhs.character) < (rhs.line, rhs.character)
    }

    /// The UTF-16 offset in a text with these line starts (see `SourcePosition.lineStarts`).
    public func offset(in lineStarts: [Int], length: Int) -> Int {
        guard line < lineStarts.count else { return length }
        let start = lineStarts[max(0, line)]
        let end = line + 1 < lineStarts.count ? lineStarts[line + 1] : length
        return min(start + max(0, character), end, length)
    }

    public init(offset: Int, in lineStarts: [Int]) {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        self.init(line: low, character: offset - lineStarts[low])
    }

    /// UTF-16 offsets where each line starts (after `\n`).
    public static func lineStarts(of text: NSString) -> [Int] {
        var starts = [0]
        let length = text.length
        var index = 0
        while index < length {
            let range = text.range(of: "\n", options: .literal, range: NSRange(location: index, length: length - index))
            guard range.location != NSNotFound else { break }
            starts.append(range.location + 1)
            index = range.location + 1
        }
        return starts
    }
}

public struct SourceRange: Sendable, Hashable {
    public var start: SourcePosition
    public var end: SourcePosition

    public init(start: SourcePosition, end: SourcePosition) {
        self.start = start
        self.end = end
    }

    public func contains(_ position: SourcePosition) -> Bool {
        start <= position && position <= end
    }

    /// As an `NSRange` of a text with these line starts.
    public func nsRange(in lineStarts: [Int], length: Int) -> NSRange {
        let lower = start.offset(in: lineStarts, length: length)
        let upper = max(lower, end.offset(in: lineStarts, length: length))
        return NSRange(location: lower, length: upper - lower)
    }
}

public struct SourceLocation: Sendable, Hashable {
    public var url: URL
    public var range: SourceRange

    public init(url: URL, range: SourceRange) {
        self.url = url
        self.range = range
    }
}

/// An error or warning a language server reports for a file.
public struct Diagnostic: Sendable, Hashable {
    public enum Severity: Int, Sendable, Comparable {
        // LSP's numbering: lower is more severe.
        case error = 1, warning, information, hint

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue > rhs.rawValue }
    }

    public var range: SourceRange
    public var severity: Severity
    public var message: String
    /// The tool that reported it, e.g. "ts" or "SourceKit".
    public var source: String?

    public init(range: SourceRange, severity: Severity, message: String, source: String? = nil) {
        self.range = range
        self.severity = severity
        self.message = message
        self.source = source
    }
}

/// What a language server says about the symbol under the pointer.
public struct HoverInfo: Sendable, Hashable {
    /// Markdown (code blocks fenced with their language).
    public var markdown: String
    /// The word or symbol it is about.
    public var range: SourceRange?

    public init(markdown: String, range: SourceRange?) {
        self.markdown = markdown
        self.range = range
    }
}

/// How the language server for a file is doing, for the status bar.
public enum LanguageServerState: Sendable, Hashable {
    case starting
    case running
    /// The server couldn't start or quit; the message says why.
    case failed(String)
    /// No server is set up for this language, or it isn't installed.
    case unavailable(String)
}

/// Errors, hover and go-to-definition from language servers. Implemented by
/// the Languages plugin; observable, so views reading diagnostics redraw.
@MainActor
public protocol LanguageIntelligence: AnyObject {
    /// Errors and warnings in the file, as of the last text the server saw.
    func diagnostics(for url: URL) -> [Diagnostic]
    /// Name and state of the file's server; nil when its language has none.
    func server(for url: URL) -> (name: String, state: LanguageServerState)?
    func hover(at position: SourcePosition, in url: URL) async -> HoverInfo?
    func definition(at position: SourcePosition, in url: URL) async -> [SourceLocation]
    /// What opens completion and signature help in this file; empty without a running server.
    func triggers(for url: URL) -> LanguageTriggers
    /// Suggestions at the caret; nil when there's no server or the request was superseded.
    func completions(at position: SourcePosition, in url: URL, trigger: CompletionTrigger) async -> CompletionList?
    /// The item with its documentation and auto-import edits filled in.
    func resolve(_ item: CompletionItem, in url: URL) async -> CompletionItem
    func signatureHelp(at position: SourcePosition, in url: URL, trigger: String?, isRetrigger: Bool) async -> SignatureHelp?
    /// A server Orbit could install for this file, offered above the editor (D57); nil when there's nothing to offer.
    func installOffer(for url: URL) -> LanguageInstallOffer?
    func installServer(for url: URL)
    /// "Not now": no more offers for this language (Settings still installs it).
    func declineInstall(for url: URL)

    // Fixes, rename, formatting (D59); edits land through `SourceEditing` when the file is open.
    func codeActions(for range: SourceRange, in url: URL) async -> [CodeAction]
    /// nil when it worked, else why not.
    func perform(_ action: CodeAction, in url: URL) async -> String?
    func prepareRename(at position: SourcePosition, in url: URL) async -> RenameTarget?
    /// The number of files changed, or why it failed.
    func rename(at position: SourcePosition, in url: URL, to newName: String) async -> Result<Int, RenameFailure>
    func canFormat(_ url: URL) -> Bool
    /// Formats the whole file with the repo's formatter or the server; nil when it worked, else why not.
    func format(_ url: URL) async -> String?
    /// Problems in every open file, worst first.
    var problems: [FileProblems] { get }
}

public struct RenameFailure: Error, Sendable, Hashable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

public struct LanguageInstallOffer: Sendable, Hashable {
    /// The language, e.g. "Python".
    public var name: String
    /// What it needs to install, e.g. "Node.js".
    public var needs: String?
    public var isInstalling: Bool
    public var failure: String?

    public init(name: String, needs: String?, isInstalling: Bool, failure: String?) {
        self.name = name
        self.needs = needs
        self.isInstalling = isInstalling
        self.failure = failure
    }
}
