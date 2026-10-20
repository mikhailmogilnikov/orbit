import Foundation

/// Which semantic tokens recolor code, and as what (D201). Tree-sitter
/// colors everything first; a token only overrides where it knows more than
/// the syntax tree can: what a name refers to (a type, a parameter, a
/// property, an enum case, a macro). Variables, keywords, strings and
/// comments are left to tree-sitter, which already gets them right.
public enum SemanticColors {
    /// LSP's standard token types and modifiers, as the client announces them.
    public static let tokenTypes = [
        "namespace", "type", "class", "enum", "interface", "struct", "typeParameter", "parameter", "variable",
        "property", "enumMember", "event", "function", "method", "macro", "keyword", "modifier", "comment",
        "string", "number", "regexp", "operator", "decorator",
    ]
    public static let tokenModifiers = [
        "declaration", "definition", "readonly", "static", "deprecated", "abstract", "async", "modification",
        "documentation", "defaultLibrary",
    ]

    /// The theme captures to try for a token, most specific first; empty to keep tree-sitter's color.
    public static func captures(for type: String, modifiers: Set<String>) -> [String] {
        let builtin = modifiers.contains("defaultLibrary")
        switch type {
        case "type", "class", "enum", "interface", "struct", "typeParameter":
            return builtin ? ["type.builtin", "type"] : ["type"]
        case "parameter":
            return ["variable.parameter"]
        case "property":
            return ["property"]
        case "enumMember":
            return ["variant", "constant"]
        case "function", "method":
            return builtin ? ["function.builtin", "function"] : ["function"]
        case "macro":
            return ["function.special", "function"]
        case "decorator":
            return ["attribute"]
        case "variable":
            return builtin ? ["variable.special"] : []
        default:
            return []
        }
    }
}
