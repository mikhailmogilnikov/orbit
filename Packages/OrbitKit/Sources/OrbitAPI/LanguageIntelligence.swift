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
    /// The editor asks on every keystroke: the text is scanned in buffered
    /// chunks, not with one `range(of:)` call per line.
    public static func lineStarts(of text: NSString) -> [Int] {
        var starts = [0]
        let length = text.length
        let chunk = 16 * 1024
        var buffer = [unichar](repeating: 0, count: min(chunk, length))
        var location = 0
        while location < length {
            let count = min(chunk, length - location)
            buffer.withUnsafeMutableBufferPointer { pointer in
                text.getCharacters(pointer.baseAddress!, range: NSRange(location: location, length: count))
                for index in 0..<count where pointer[index] == 0x0A { starts.append(location + index + 1) }
            }
            location += count
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
    public var tags: Set<Tag>

    /// LSP's `DiagnosticTag`: drawn faded / struck through (D78).
    public enum Tag: Int, Sendable {
        case unnecessary = 1, deprecated
    }

    public init(range: SourceRange, severity: Severity, message: String, source: String? = nil, tags: Set<Tag> = []) {
        self.range = range
        self.severity = severity
        self.message = message
        self.source = source
        self.tags = tags
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
    /// What a rename would change, without changing it: for a preview (D199).
    func renameEdit(at position: SourcePosition, in url: URL, to newName: String) async -> Result<WorkspaceEdit, RenameFailure>
    /// Applies a server's edit (open files through the editor, file operations
    /// through the workspace); false when some part failed.
    @discardableResult
    func apply(_ edit: WorkspaceEdit) -> Bool
    /// The server's edits after `character` was typed at `position` (D203); empty when there are none.
    func formatOnType(_ character: String, at position: SourcePosition, in url: URL) async -> [SourceEdit]
    func canFormat(_ url: URL) -> Bool
    /// Formats the file with the repo's formatter or the server; with `lines`
    /// (0-based), only the changes there are kept (D140).
    func format(_ url: URL, lines: ClosedRange<Int>?) async -> FormatOutcome
    /// The code actions set to run on save (`codeActionsOnSave`, D81): ESLint's fixes by default.
    func runSaveActions(_ url: URL) async
    /// Runs the first action of each kind (`source.organizeImports`…) the file's servers offer; how many ran.
    func runCodeActions(_ kinds: [String], in url: URL) async -> Int
    /// Problems in every open file, worst first.
    var problems: [FileProblems] { get }

    // Navigation (D62).
    /// Every use of the symbol at a spot, its declaration included.
    func references(at position: SourcePosition, in url: URL) async -> [SourceLocation]
    /// Other uses of the symbol under the caret in the same file.
    func highlights(at position: SourcePosition, in url: URL) async -> [SymbolHighlight]
    /// The file's outline, parents before their children; nil when its server can't tell.
    func symbols(in url: URL) async -> [LanguageSymbol]?
    /// Symbols matching a query across the project, from every running server.
    func projectSymbols(matching query: String) async -> [LanguageSymbol]
    /// The symbol at a spot as the root of a call or type hierarchy (D200);
    /// empty when there's none or the server can't.
    func prepareHierarchy(_ kind: HierarchyKind, at position: SourcePosition, in url: URL) async -> [HierarchyItem]
    /// An item's callers or callees, supertypes or subtypes.
    func hierarchy(_ direction: HierarchyDirection, of item: HierarchyItem) async -> [HierarchyItem]

    /// Inlay hints for part of the file; empty when its server has none.
    func inlayHints(in range: SourceRange, url: URL) async -> [InlayHint]
    /// Bumped when the file's server says its hints went stale (a dependency changed).
    func inlayHintsRevision(for url: URL) -> Int

    /// Regions that can be folded; nil when the file's server can't tell (the editor folds by indentation then).
    func foldingRanges(in url: URL) async -> [FoldingRange]?

    /// The ranges edited together with the one at a spot (an HTML tag's name
    /// and its closing tag's, D202); nil when there are none.
    func linkedEditingRanges(at position: SourcePosition, in url: URL) async -> [SourceRange]?
    /// For each spot, the syntax around it from the narrowest outwards (Expand
    /// Selection, D202); nil when the server can't tell.
    func selectionRanges(at positions: [SourcePosition], in url: URL) async -> [[SourceRange]]?

    /// What the server knows each name in the file to be (D201); nil when it can't say.
    func semanticTokens(in url: URL) async -> [SemanticToken]?
    /// Bumped when the file's server says its semantic tokens or code lenses went stale.
    func semanticTokensRevision(for url: URL) -> Int
    /// The file's code lenses Orbit can show (D201): resolved, and only those
    /// whose command it can run or that only say something.
    func codeLenses(in url: URL) async -> [CodeLens]
    /// Runs a lens's command; nil when it ran, else why not.
    func run(_ lens: CodeLens, in url: URL) async -> String?
}

extension LanguageIntelligence {
    public func format(_ url: URL) async -> FormatOutcome { await format(url, lines: nil) }
}

/// A name the language server classified (D201): a parameter, a property,
/// a type… with modifiers like `readonly` or `defaultLibrary`. One line long.
public struct SemanticToken: Sendable, Hashable {
    public var line: Int
    /// UTF-16, like every LSP position here.
    public var character: Int
    public var length: Int
    public var type: String
    public var modifiers: Set<String>

    public init(line: Int, character: Int, length: Int, type: String, modifiers: Set<String> = []) {
        self.line = line
        self.character = character
        self.length = length
        self.type = type
        self.modifiers = modifiers
    }
}

/// A server's note on a line (D201): "3 references", "▶ Run test".
public struct CodeLens: Sendable, Hashable, Identifiable {
    /// The server's own lens, to run it.
    public var token: Int
    public var line: Int
    public var title: String
    /// False for a lens that only says something.
    public var isActionable: Bool
    /// The server that gave it when a file has several.
    public var server: String?

    public var id: Int { token }

    public init(token: Int, line: Int, title: String, isActionable: Bool, server: String? = nil) {
        self.token = token
        self.line = line
        self.title = title
        self.isActionable = isActionable
        self.server = server
    }
}

public enum HierarchyKind: Sendable, Hashable {
    case calls, types
}

/// Callers or supertypes (`incoming`), callees or subtypes (`outgoing`).
public enum HierarchyDirection: Sendable, Hashable {
    case incoming, outgoing
}

/// A function or type in a hierarchy (D200); the server's own item stays
/// with it (`token`), as it wants that back to go a level deeper.
public struct HierarchyItem: Sendable, Hashable, Identifiable {
    public var token: Int
    public var kind: HierarchyKind
    public var name: String
    public var detail: String?
    public var symbolKind: SymbolKind
    /// Its name, where to put the caret.
    public var location: SourceLocation
    /// For calls: where the call is, in the caller (incoming) or in this
    /// item's parent (outgoing).
    public var callSites: [SourceLocation]

    public var id: Int { token }

    public init(token: Int, kind: HierarchyKind, name: String, detail: String? = nil, symbolKind: SymbolKind, location: SourceLocation, callSites: [SourceLocation] = []) {
        self.token = token
        self.kind = kind
        self.name = name
        self.detail = detail
        self.symbolKind = symbolKind
        self.location = location
        self.callSites = callSites
    }
}

/// Lines that can be folded away: `startLine` stays visible, the lines after it through `endLine` hide.
public struct FoldingRange: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case comment, imports, region
    }

    public var startLine: Int
    public var endLine: Int
    public var kind: Kind?

    public init(startLine: Int, endLine: Int, kind: Kind? = nil) {
        self.startLine = startLine
        self.endLine = endLine
        self.kind = kind
    }
}

/// A label a language server puts into the text without it being there: a
/// type after a name, a parameter's name before an argument.
public struct InlayHint: Sendable, Hashable {
    public enum Kind: Int, Sendable, Hashable {
        case type = 1, parameter
    }

    /// The label sits before the character at this position.
    public var position: SourcePosition
    public var label: String
    public var kind: Kind?
    public var tooltip: String?
    /// A space's worth of room on that side.
    public var paddingLeft: Bool
    public var paddingRight: Bool

    public init(position: SourcePosition, label: String, kind: Kind? = nil, tooltip: String? = nil, paddingLeft: Bool = false, paddingRight: Bool = false) {
        self.position = position
        self.label = label
        self.kind = kind
        self.tooltip = tooltip
        self.paddingLeft = paddingLeft
        self.paddingRight = paddingRight
    }
}

/// A declaration in a file's outline or the project's symbol search.
public struct LanguageSymbol: Sendable, Hashable {
    public var name: String
    /// A signature or type, when the server gives one.
    public var detail: String?
    public var kind: SymbolKind
    /// The name's own range (where to put the caret).
    public var location: SourceLocation
    /// The enclosing type or namespace, e.g. "Greeter".
    public var container: String?
    /// Nesting in the file's outline: 0 for top level.
    public var depth: Int
    /// The whole declaration, body included (the breadcrumb bar finds the caret in it).
    public var extent: SourceRange?

    public init(name: String, detail: String? = nil, kind: SymbolKind, location: SourceLocation, container: String? = nil, depth: Int = 0, extent: SourceRange? = nil) {
        self.name = name
        self.detail = detail
        self.kind = kind
        self.location = location
        self.container = container
        self.depth = depth
        self.extent = extent
    }
}

/// LSP's `SymbolKind` numbering.
public enum SymbolKind: Int, Sendable, Hashable {
    case file = 1, module, namespace, package, `class`, method, property, field, constructor, `enum`,
         interface, function, variable, constant, string, number, boolean, array, object, key, null,
         enumMember, `struct`, event, `operator`, typeParameter

    /// An SF Symbol for pickers.
    public var systemImage: String {
        switch self {
        case .file: "doc"
        case .module, .package, .namespace: "shippingbox"
        case .class: "c.square"
        case .struct: "s.square"
        case .enum: "e.square"
        case .interface: "p.square"
        case .method, .function, .constructor, .operator: "f.square"
        case .property, .field, .key: "square.dashed.inset.filled"
        case .variable, .constant, .string, .number, .boolean, .array, .object, .null: "v.square"
        case .enumMember: "list.bullet.rectangle"
        case .event: "bolt.square"
        case .typeParameter: "t.square"
        }
    }

    /// Types and namespaces: what other symbols sit inside.
    public var isContainer: Bool {
        [.module, .namespace, .package, .class, .enum, .interface, .struct, .object].contains(self)
    }
}

/// A use of the symbol under the caret; writes are drawn a little stronger.
public struct SymbolHighlight: Sendable, Hashable {
    public var range: SourceRange
    public var isWrite: Bool

    public init(range: SourceRange, isWrite: Bool) {
        self.range = range
        self.isWrite = isWrite
    }
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
    /// What it brings, when it isn't the file's language server (ESLint in a project that uses it).
    public var purpose: String?

    public init(name: String, needs: String?, isInstalling: Bool, failure: String?, purpose: String? = nil) {
        self.name = name
        self.needs = needs
        self.isInstalling = isInstalling
        self.failure = failure
        self.purpose = purpose
    }
}

/// What formatting a file did, for the editor to say so.
public struct FormatOutcome: Sendable, Equatable {
    /// "Prettier", "TypeScript language server"…; nil when nothing could run.
    public var formatter: String?
    public var changed: Bool
    /// Why it couldn't format.
    public var failure: String?

    public init(formatter: String?, changed: Bool = false, failure: String? = nil) {
        self.formatter = formatter
        self.changed = changed
        self.failure = failure
    }

    public static func failed(_ message: String, formatter: String? = nil) -> FormatOutcome {
        FormatOutcome(formatter: formatter, failure: message)
    }
}
