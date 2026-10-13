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

    public var id: Int { token }

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
