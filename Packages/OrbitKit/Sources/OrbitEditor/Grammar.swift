import Foundation
import Observation
import OrbitAPI
import SwiftTreeSitter
import Synchronization
import TreeSitterResource

/// What the editor parses a file with: a grammar built in, or one installed
/// for its language (D58). Installed ones win, replacing stand-ins
/// (TypeScript's grammar for `.tsx`, Java's for `.kt`).
// TreeSitterResource's enum isn't marked Sendable; both cases are plain values.
enum Grammar: Hashable, @unchecked Sendable {
    case builtin(TreeSitterLanguage)
    case installed(InstalledGrammar)

    static func matching(_ url: URL) -> Grammar? {
        if let grammar = InstalledGrammars.current.withLock({ GrammarStore.shared.grammar(for: url, in: $0) }) {
            return .installed(grammar)
        }
        return Language.treeSitter(for: url).map(Grammar.builtin)
    }

    var key: String {
        switch self {
        case .builtin(let language): "builtin:\(language)"
        // The layout too: a reinstall that adds `injections.scm` keeps the commit.
        case .installed(let grammar): "\(grammar.name)@\(grammar.commit)#\(grammar.layout ?? 0)"
        }
    }

    /// The grammar for a language another one embeds, as the injection query
    /// names it: a fence's info string (`js`, `TypeScript`), `#set!`'s value
    /// (`markdown_inline`), Vue's `lang` attribute.
    static func named(_ name: String) -> Grammar? {
        let key = injectionKey(name)
        guard !key.isEmpty else { return nil }
        if let grammar = InstalledGrammars.current.withLock({ grammars in
            grammars.first { $0.name == key } ?? grammars.first { $0.fileTypes.contains(key) }
        }) {
            return .installed(grammar)
        }
        if GrammarSource.source(named: key)?.fileTypes.isEmpty == true { return nil }
        return Language.treeSitter(for: URL(fileURLWithPath: "embedded.\(key)")).map(Grammar.builtin)
    }

    /// The grammar to install for an embedded language, when it's missing or out of date.
    static func sourceToInstall(named name: String) -> GrammarSource? {
        guard let source = GrammarSource.source(named: injectionKey(name)) else { return nil }
        let installed = InstalledGrammars.current.withLock { $0.first { $0.name == source.name } }
        if let installed, installed.isCurrent(source) { return nil }
        return source
    }

    /// A language name as a grammar name or file extension.
    static func injectionKey(_ name: String) -> String {
        // Info strings may carry more: ```js title="a.js"`, `{.python}`.
        let word = name.lowercased().split(whereSeparator: { $0 == " " || $0 == "," || $0 == "{" || $0 == "}" }).first.map(String.init) ?? ""
        let key = word.hasPrefix(".") ? String(word.dropFirst()) : word
        return aliases[key] ?? key
    }

    private static let aliases: [String: String] = [
        "javascript": "js", "typescript": "ts", "python": "py", "python3": "py", "ruby": "rb", "rust": "rs",
        "shell": "sh", "bash": "sh", "zsh": "sh", "console": "sh", "yml": "yaml", "markdown": "md",
        "csharp": "cs", "c#": "cs", "c++": "cpp", "objc": "m", "objective-c": "m", "kotlin": "kt",
        "golang": "go", "terraform": "tf", "docker": "dockerfile", "jsonc": "json", "json5": "json",
        "htm": "html", "xhtml": "html", "postcss": "css", "less": "css",
    ]

    /// Loads an installed grammar's library on first use.
    var language: SwiftTreeSitter.Language? {
        switch self {
        case .builtin(let language): SwiftTreeSitter.Language(language: language.parser)
        case .installed(let grammar): GrammarLibraries.language(grammar).map { SwiftTreeSitter.Language(language: $0) }
        }
    }

    /// Highlight queries to try in order.
    func querySources() -> [String] {
        func read(_ url: URL?) -> String? { url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } }
        switch self {
        case .installed(let grammar):
            return read(URL(fileURLWithPath: grammar.highlights)).map { [$0] } ?? []
        case .builtin(let language):
            // TypeScript's query only adds what JavaScript lacks (types, `private`…);
            // like Neovim and Helix, it's read after JavaScript's, which colors
            // keywords, strings and comments. Later patterns win.
            guard let own = read(language.highlightQueryURL) else { return [] }
            guard language == .typescript, let base = read(TreeSitterLanguage.javascript.highlightQueryURL) else { return [own] }
            return [base + "\n" + own, own]
        }
    }
}

extension Grammar {
    /// Where the language embeds others (D69): query patterns, compiled
    /// together, or one by one when some don't fit the grammar.
    func injectionPatterns() -> [String] {
        switch self {
        case .installed(let grammar):
            return grammar.injections.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }.map { [$0] } ?? []
        case .builtin(let language):
            // The bundled grammars' own `injections.scm` aren't reachable from
            // here, and nvim's need predicates we don't run; these are ours.
            return BuiltinInjections.patterns(for: language) ?? []
        }
    }
}

private enum BuiltinInjections {
    static func patterns(for language: TreeSitterLanguage) -> [String]? {
        switch language {
        case .html: html
        case .markdown: markdown
        case .javascript, .typescript: script
        case .php: ["((text) @injection.content (#set! injection.language \"html\"))"]
        default: nil
        }
    }

    static let html = [
        "((script_element (raw_text) @injection.content) (#set! injection.language \"javascript\"))",
        "((style_element (raw_text) @injection.content) (#set! injection.language \"css\"))",
    ]

    static let markdown = [
        "(fenced_code_block (info_string (language) @injection.language) (code_fence_content) @injection.content)",
        "((html_block) @injection.content (#set! injection.language \"html\"))",
        "((minus_metadata) @injection.content (#set! injection.language \"yaml\"))",
        "((plus_metadata) @injection.content (#set! injection.language \"toml\"))",
        "((inline) @injection.content (#set! injection.language \"markdown_inline\"))",
    ]

    /// Tagged templates: css`…`, html`…`, sql`…`, styled.div`…`.
    static let script = [
        """
        (call_expression function: (identifier) @injection.language
          arguments: (template_string) @injection.content (#offset! @injection.content 0 1 0 -1))
        """,
        """
        (call_expression function: (member_expression object: (identifier) @_styled)
          arguments: (template_string) @injection.content
          (#eq? @_styled "styled") (#set! injection.language "css") (#offset! @injection.content 0 1 0 -1))
        """,
    ]
}

/// The installed grammars, readable from any thread (highlighting runs off the main one).
enum InstalledGrammars {
    static let current = Mutex<[InstalledGrammar]>(GrammarStore.shared.all())
}

/// Builds a grammar the first time a file of its language opens, then tells
/// open editors to switch to it.
@MainActor
@Observable
final class GrammarRegistry {
    static let shared = GrammarRegistry()

    /// Bumped when a grammar arrives; editors re-pick theirs.
    private(set) var revision = 0
    @ObservationIgnored private var installing: Set<String> = []
    /// Failures aren't retried until Orbit restarts (no network, no Xcode tools).
    @ObservationIgnored private var failed: Set<String> = []

    func ensureInstalled(for url: URL) {
        guard let source = GrammarSource.source(for: url) else { return }
        install(source)
    }

    /// For a language a file embeds (D69); `name` is `GrammarSource.name`.
    func ensureInstalled(named name: String) {
        guard let source = GrammarSource.all.first(where: { $0.name == name }) else { return }
        install(source)
    }

    private func install(_ source: GrammarSource) {
        guard !installing.contains(source.name), !failed.contains(source.name) else { return }
        let current = InstalledGrammars.current.withLock { $0.first { $0.name == source.name } }
        if let current, current.isCurrent(source) { return }
        installing.insert(source.name)
        Task {
            let result = await Task.detached(priority: .utility) { Result { try GrammarStore.shared.install(source) } }.value
            installing.remove(source.name)
            switch result {
            case .success(let grammar):
                InstalledGrammars.current.withLock { grammars in
                    grammars.removeAll { $0.name == grammar.name }
                    grammars.append(grammar)
                }
                revision += 1
                NotificationCenter.default.post(name: GrammarStore.didChange, object: nil)
            case .failure:
                failed.insert(source.name)
            }
        }
    }
}
