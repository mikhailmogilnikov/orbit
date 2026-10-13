import Foundation

/// A replacement in a file, as a language server sends it.
public struct SourceEdit: Sendable, Hashable {
    public var range: SourceRange
    public var newText: String

    public init(range: SourceRange, newText: String) {
        self.range = range
        self.newText = newText
    }
}

/// One suggestion while typing (D56).
public struct CompletionItem: Sendable, Hashable {
    /// LSP's `CompletionItemKind`.
    public enum Kind: Int, Sendable {
        case text = 1, method, function, constructor, field, variable, `class`, interface, module, property,
             unit, value, `enum`, keyword, snippet, color, file, reference, folder, enumMember, constant,
             `struct`, event, `operator`, typeParameter
    }

    /// Identifies the server's original item, for resolving details later.
    public var token: Int
    public var label: String
    public var kind: Kind?
    /// Signature or type, shown right of the label.
    public var detail: String?
    /// Markdown, often only after `resolve`.
    public var documentation: String?
    public var sortText: String
    public var filterText: String
    /// What's inserted: plain text, or a snippet with tab stops.
    public var insertText: String
    public var isSnippet: Bool
    /// Replaces this range instead of the word before the caret (as of the request).
    public var range: SourceRange?
    /// Auto-imports and the like, elsewhere in the file.
    public var additionalEdits: [SourceEdit]
    public var isPreselected: Bool
    public var isDeprecated: Bool
    /// Whether `resolve` may add details or edits.
    public var needsResolve: Bool
    /// The server that offered it when a file has several (D64); set by the Languages plugin.
    public var server: String?

    public init(
        token: Int, label: String, kind: Kind? = nil, detail: String? = nil, documentation: String? = nil,
        sortText: String? = nil, filterText: String? = nil, insertText: String? = nil, isSnippet: Bool = false,
        range: SourceRange? = nil, additionalEdits: [SourceEdit] = [], isPreselected: Bool = false,
        isDeprecated: Bool = false, needsResolve: Bool = false
    ) {
        self.token = token
        self.label = label
        self.kind = kind
        self.detail = detail
        self.documentation = documentation
        self.sortText = sortText ?? label
        self.filterText = filterText ?? label
        self.insertText = insertText ?? label
        self.isSnippet = isSnippet
        self.range = range
        self.additionalEdits = additionalEdits
        self.isPreselected = isPreselected
        self.isDeprecated = isDeprecated
        self.needsResolve = needsResolve
    }
}

public struct CompletionList: Sendable, Hashable {
    public var items: [CompletionItem]
    /// The server cut the list short: typing more needs a new request.
    public var isIncomplete: Bool

    public init(items: [CompletionItem], isIncomplete: Bool) {
        self.items = items
        self.isIncomplete = isIncomplete
    }
}

public enum CompletionTrigger: Sendable, Hashable {
    /// Typing a word, or ⌃Space.
    case invoked
    /// One of the server's trigger characters, like `.`.
    case character(String)
    /// More typing into a list the server marked incomplete.
    case incomplete
}

/// The call being typed and where in its parameters the caret is.
public struct SignatureHelp: Sendable, Hashable {
    public struct Signature: Sendable, Hashable {
        public var label: String
        public var documentation: String?
        /// Each parameter's span in `label` (UTF-16).
        public var parameters: [NSRange]
        public var activeParameter: Int?

        public init(label: String, documentation: String?, parameters: [NSRange], activeParameter: Int?) {
            self.label = label
            self.documentation = documentation
            self.parameters = parameters
            self.activeParameter = activeParameter
        }
    }

    public var signatures: [Signature]
    public var activeSignature: Int
    public var activeParameter: Int

    public init(signatures: [Signature], activeSignature: Int, activeParameter: Int) {
        self.signatures = signatures
        self.activeSignature = activeSignature
        self.activeParameter = activeParameter
    }
}

/// Characters that open completion or signature help, from the server.
public struct LanguageTriggers: Sendable, Hashable {
    public var completion: Set<String>
    public var signatureHelp: Set<String>
    public var signatureHelpRetrigger: Set<String>

    public init(completion: Set<String> = [], signatureHelp: Set<String> = [], signatureHelpRetrigger: Set<String> = []) {
        self.completion = completion
        self.signatureHelp = signatureHelp
        self.signatureHelpRetrigger = signatureHelpRetrigger
    }
}

// MARK: Matching

/// Fuzzy matching for completion lists (D56): the typed characters in order,
/// the first one at a word start ("gS" finds `getString`), scored so prefix
/// and word-start matches rank first. Works on UTF-16 like the editor.
public struct FuzzyPattern: Sendable {
    public let text: String
    private let lower: [UInt16]
    private let original: [UInt16]

    public init(_ text: String) {
        self.text = text
        original = Array(text.utf16)
        lower = Array(text.lowercased().utf16)
    }

    public var isEmpty: Bool { original.isEmpty }

    /// nil when `candidate` doesn't match.
    public func score(_ candidate: String) -> Int? {
        score(Array(candidate.utf16))
    }

    public func score(_ candidate: [UInt16]) -> Int? {
        match(candidate)?.score
    }

    /// The score and the matched UTF-16 offsets in `candidate`.
    public func match(_ candidate: [UInt16]) -> (score: Int, positions: [Int])? {
        guard !lower.isEmpty else { return (0, []) }
        guard candidate.count >= lower.count else { return nil }
        var positions: [Int] = []
        positions.reserveCapacity(lower.count)
        var score = 0
        var index = 0
        for (patternIndex, wanted) in lower.enumerated() {
            guard let found = Self.next(wanted, in: candidate, from: index, preferContiguous: patternIndex > 0) else { return nil }
            let boundary = Self.isBoundary(candidate, found)
            if patternIndex == 0 {
                guard boundary else { return nil }
                score += found == 0 ? 12 : 6
            } else if found == index {
                score += 5
            } else {
                score += boundary ? 4 : 0
                score -= min(found - index, 4)
            }
            if candidate[found] == original[patternIndex] { score += 1 }
            score += 1
            positions.append(found)
            index = found + 1
        }
        if positions.last == lower.count - 1 { score += 20 }
        if candidate.count == lower.count { score += 4 }
        return (score, positions)
    }

    /// The next spot for `wanted`: right here if it matches, else a word start, else anywhere.
    private static func next(_ wanted: UInt16, in candidate: [UInt16], from start: Int, preferContiguous: Bool) -> Int? {
        var first: Int?
        var index = start
        while index < candidate.count {
            if lowercase(candidate[index]) == wanted {
                if (preferContiguous && index == start) || isBoundary(candidate, index) { return index }
                if first == nil { first = index }
            }
            index += 1
        }
        return first
    }

    static func isBoundary(_ text: [UInt16], _ index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = text[index - 1], current = text[index]
        if isUpper(current) && !isUpper(previous) { return true }
        return !isAlphanumeric(previous) && isAlphanumeric(current)
    }

    private static func lowercase(_ unit: UInt16) -> UInt16 {
        isUpper(unit) ? unit + 32 : unit
    }

    private static func isUpper(_ unit: UInt16) -> Bool { unit >= 65 && unit <= 90 }

    private static func isAlphanumeric(_ unit: UInt16) -> Bool {
        (unit >= 48 && unit <= 57) || (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit > 127
    }
}

// MARK: Snippets

/// LSP snippet syntax (`$1`, `${1:name}`, `${1|a,b|}`, `$0`) as plain text and
/// tab stops (D56). Variables become their default or nothing.
public struct Snippet: Sendable, Hashable {
    public struct TabStop: Sendable, Hashable {
        public var index: Int
        /// UTF-16 range in `text`.
        public var range: NSRange
    }

    public var text: String
    /// In visiting order: 1, 2, …, then 0 (the final caret) if present.
    public var tabStops: [TabStop]

    public init(_ snippet: String) {
        var parser = SnippetParser(Array(snippet.unicodeScalars))
        let (text, stops) = parser.parse(until: nil)
        self.text = text
        tabStops = stops.sorted { lhs, rhs in
            (lhs.index == 0 ? Int.max : lhs.index, lhs.range.location) < (rhs.index == 0 ? Int.max : rhs.index, rhs.range.location)
        }
    }
}

private struct SnippetParser {
    let scalars: [Unicode.Scalar]
    var index = 0

    init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }

    /// Text up to `terminator` (a `}` closing a placeholder), with tab stops relative to its start.
    mutating func parse(until terminator: Unicode.Scalar?) -> (String, [Snippet.TabStop]) {
        var text = ""
        var length = 0
        var stops: [Snippet.TabStop] = []
        func append(_ string: String) {
            text += string
            length += string.utf16.count
        }
        while index < scalars.count {
            let scalar = scalars[index]
            if let terminator, scalar == terminator {
                index += 1
                return (text, stops)
            }
            if scalar == "\\", index + 1 < scalars.count, "$}\\,|".unicodeScalars.contains(scalars[index + 1]) {
                append(String(scalars[index + 1]))
                index += 2
                continue
            }
            if scalar == "$", let (inner, innerStops, stopIndex) = parseDollar() {
                for var stop in innerStops {
                    stop.range.location += length
                    stops.append(stop)
                }
                if let stopIndex {
                    stops.append(Snippet.TabStop(index: stopIndex, range: NSRange(location: length, length: inner.utf16.count)))
                }
                append(inner)
                continue
            }
            append(String(scalar))
            index += 1
        }
        return (text, stops)
    }

    /// After `$`: a tab stop, placeholder, choice or variable; nil leaves the `$` as text.
    private mutating func parseDollar() -> (String, [Snippet.TabStop], Int?)? {
        let start = index
        index += 1
        if let number = readNumber() { return ("", [], number) }
        if let name = readName() {
            _ = name
            return ("", [], nil)
        }
        guard index < scalars.count, scalars[index] == "{" else {
            index = start
            return nil
        }
        index += 1
        if let number = readNumber() {
            if index < scalars.count, scalars[index] == "}" {
                index += 1
                return ("", [], number)
            }
            if index < scalars.count, scalars[index] == ":" {
                index += 1
                let (inner, stops) = parse(until: "}")
                return (inner, stops, number)
            }
            if index < scalars.count, scalars[index] == "|" {
                index += 1
                var choice = ""
                var first: String?
                while index < scalars.count, scalars[index] != "|" {
                    if scalars[index] == "\\", index + 1 < scalars.count {
                        choice.unicodeScalars.append(scalars[index + 1])
                        index += 2
                        continue
                    }
                    if scalars[index] == "," {
                        if first == nil { first = choice }
                    } else if first == nil {
                        choice.unicodeScalars.append(scalars[index])
                    }
                    index += 1
                }
                index = min(scalars.count, index + 2)
                return (first ?? choice, [], number)
            }
        } else if readName() != nil {
            if index < scalars.count, scalars[index] == ":" {
                index += 1
                let (inner, stops) = parse(until: "}")
                return (inner, stops, nil)
            }
            // Transforms and bare variables: nothing to insert.
            var depth = 1
            while index < scalars.count, depth > 0 {
                if scalars[index] == "{" { depth += 1 }
                if scalars[index] == "}" { depth -= 1 }
                index += 1
            }
            return ("", [], nil)
        }
        index = start
        return nil
    }

    private mutating func readNumber() -> Int? {
        var digits = ""
        while index < scalars.count, ("0"..."9").contains(scalars[index]) {
            digits.unicodeScalars.append(scalars[index])
            index += 1
        }
        return Int(digits)
    }

    private mutating func readName() -> String? {
        var name = ""
        while index < scalars.count, scalars[index] == "_" || scalars[index].properties.isAlphabetic || (!name.isEmpty && ("0"..."9").contains(scalars[index])) {
            name.unicodeScalars.append(scalars[index])
            index += 1
        }
        return name.isEmpty ? nil : name
    }
}
