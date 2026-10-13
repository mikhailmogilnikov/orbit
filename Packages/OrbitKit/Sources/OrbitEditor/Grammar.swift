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
        case .installed(let grammar): "\(grammar.name)@\(grammar.commit)"
        }
    }

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
        guard let source = GrammarSource.source(for: url),
              !installing.contains(source.name), !failed.contains(source.name) else { return }
        let current = InstalledGrammars.current.withLock { $0.first { $0.name == source.name } }
        guard current?.commit != source.commit else { return }
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
