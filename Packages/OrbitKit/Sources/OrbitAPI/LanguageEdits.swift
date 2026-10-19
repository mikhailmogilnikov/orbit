import Foundation

/// Edits across files from a language server: a rename, a quick fix (D59).
public struct WorkspaceEdit: Sendable, Hashable {
    public var files: [URL: [SourceEdit]]
    /// It also wanted to create, rename or delete files, which Orbit doesn't do.
    public var hasFileOperations: Bool

    public init(files: [URL: [SourceEdit]], hasFileOperations: Bool = false) {
        self.files = files
        self.hasFileOperations = hasFileOperations
    }

    public var isEmpty: Bool { files.values.allSatisfy(\.isEmpty) }
}

extension SourceEdit {
    /// Applies edits made against `text` (LSP positions all refer to the
    /// original), last first so earlier ranges stay valid.
    public static func apply(_ edits: [SourceEdit], to text: String) -> String {
        let string = NSMutableString(string: text)
        let starts = SourcePosition.lineStarts(of: string)
        let length = string.length
        let ranges = edits.map { ($0.range.nsRange(in: starts, length: length), $0.newText) }
            .sorted { $0.0.location > $1.0.location }
        for (range, newText) in ranges {
            string.replaceCharacters(in: range, with: newText)
        }
        return string as String
    }
}

/// One text turned into another as a few line-block replacements: what a
/// view applies instead of a server's hundreds of one-space formatting edits.
public struct LinePatch: Sendable {
    public struct Replacement: Sendable, Hashable {
        /// In the text as it is when this replacement applies (earlier ones done).
        public var range: NSRange
        public var text: String
    }

    public let replacements: [Replacement]
    private let oldStarts: [Int]
    private let newStarts: [Int]
    private let newLineLengths: [Int]
    private let blocks: [(old: Range<Int>, new: Range<Int>)]

    public init(from old: String, to new: String) {
        let oldLines = LineDiff.lines(old), newLines = LineDiff.lines(new)
        blocks = LineDiff.changeBlocks(oldLines: oldLines, newLines: newLines)
        oldStarts = Self.offsets(oldLines)
        newStarts = Self.offsets(newLines)
        newLineLengths = newLines.map(\.utf16.count)
        let newText = new as NSString
        var delta = 0
        var replacements: [Replacement] = []
        for block in blocks {
            let start = oldStarts[block.old.lowerBound], end = oldStarts[block.old.upperBound]
            let text = newText.substring(with: NSRange(location: newStarts[block.new.lowerBound], length: newStarts[block.new.upperBound] - newStarts[block.new.lowerBound]))
            replacements.append(Replacement(range: NSRange(location: start + delta, length: end - start), text: text))
            delta += text.utf16.count - (end - start)
        }
        self.replacements = replacements
    }

    /// Where an offset in the old text lands: same line (moved by blocks above) and column.
    public func map(_ offset: Int) -> Int {
        let line = min(oldStarts.lastIndex { $0 <= offset } ?? 0, oldStarts.count - 2)
        let column = offset - oldStarts[line]
        var newLine = line
        for block in blocks {
            if line >= block.old.upperBound {
                newLine += block.new.count - block.old.count
            } else {
                if block.old.contains(line) {
                    newLine = block.new.lowerBound + min(line - block.old.lowerBound, max(0, block.new.count - 1))
                }
                break
            }
        }
        newLine = min(max(0, newLine), newLineLengths.count - 1)
        return newStarts[newLine] + min(column, newLineLengths[newLine])
    }

    /// Where each line starts (UTF-16), then the end; lines split on `\n`.
    private static func offsets(_ lines: [String]) -> [Int] {
        var offsets = [0]
        offsets.reserveCapacity(lines.count + 1)
        for line in lines { offsets.append(offsets[offsets.count - 1] + line.utf16.count + 1) }
        offsets[offsets.count - 1] -= 1
        return offsets
    }
}

/// A fix or refactoring offered at a spot (⌘.).
public struct CodeAction: Sendable, Hashable, Identifiable {
    /// Identifies the server's original action, for resolving and running it.
    public var token: Int
    public var title: String
    /// `quickfix`, `refactor.extract`, `source.organizeImports`…
    public var kind: String?
    public var isPreferred: Bool
    /// Why it's offered but can't apply here.
    public var disabledReason: String?
    /// The server that offered it when a file has several (D64).
    public var server: String?

    public var id: String { "\(server ?? ""):\(token)" }

    public init(token: Int, title: String, kind: String?, isPreferred: Bool, disabledReason: String?) {
        self.token = token
        self.title = title
        self.kind = kind
        self.isPreferred = isPreferred
        self.disabledReason = disabledReason
    }
}

/// What a rename at a spot would change.
public struct RenameTarget: Sendable, Hashable {
    public var range: SourceRange
    public var placeholder: String

    public init(range: SourceRange, placeholder: String) {
        self.range = range
        self.placeholder = placeholder
    }
}

/// Applies text edits to a file open in an editor, as one undoable step;
/// false when it isn't open (the edits then go to the file). Implemented by
/// the editor plugin.
@MainActor
public protocol SourceEditing: AnyObject {
    func apply(_ edits: [SourceEdit], to url: URL) -> Bool
}

/// Problems across open files, for a Problems list.
public struct FileProblems: Sendable, Hashable, Identifiable {
    public var url: URL
    public var diagnostics: [Diagnostic]
    public var id: URL { url }

    public init(url: URL, diagnostics: [Diagnostic]) {
        self.url = url
        self.diagnostics = diagnostics
    }
}

/// Errors and warnings a task printed (a build, `tsc`, a linter), read from
/// its terminal (D137). Implemented by the Terminal plugin; the Problems
/// panel and the editor's squiggles show them beside the language servers'.
@MainActor
public protocol TaskProblems: AnyObject {
    /// From each task's last run, by file.
    var problems: [FileProblems] { get }
}
