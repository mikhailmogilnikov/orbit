import Foundation
import Observation
import OrbitAPI
import SwiftTreeSitter
import Synchronization

/// What the editor parses a file with: an installed language from Zed's
/// catalog (D71), with its grammar and queries.
struct Grammar: Hashable, Sendable {
    let installed: InstalledGrammar

    /// The file's language when it's installed and current; installing is `GrammarRegistry`'s.
    static func matching(_ url: URL, firstLine: @autoclosure () -> String? = nil) -> Grammar? {
        GrammarCatalog.shared.language(for: url, firstLine: firstLine()).flatMap(installed)
    }

    /// The grammar for a language another one embeds, as the injection query
    /// or a code fence names it (`TypeScript`, `js`, `markdown-inline`).
    static func named(_ name: String) -> Grammar? {
        GrammarCatalog.shared.language(named: injectionKey(name)).flatMap(installed)
    }

    /// The language to install for an embedded one, when it's missing or out of date.
    static func languageToInstall(named name: String) -> SyntaxLanguage? {
        guard let language = GrammarCatalog.shared.language(named: injectionKey(name)) else { return nil }
        return installed(language) == nil ? language : nil
    }

    private static func installed(_ language: SyntaxLanguage) -> Grammar? {
        guard let grammar = GrammarCatalog.shared.grammar(of: language),
              let installed = InstalledGrammars.current.withLock({ $0.first { $0.name == language.name } }),
              installed.isCurrent(language, grammar) else { return nil }
        return Grammar(installed: installed)
    }

    /// Info strings may carry more: ```js title="a.js"`, `{.python}`.
    static func injectionKey(_ name: String) -> String {
        let word = name.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "{" || $0 == "}" }).first.map(String.init) ?? ""
        return word.hasPrefix(".") ? String(word.dropFirst()) : word
    }

    var key: String { "\(installed.name)@\(installed.commit)#\(installed.queries)" }

    /// Loads the library on first use.
    var language: SwiftTreeSitter.Language? {
        GrammarLibraries.language(installed).map { SwiftTreeSitter.Language(language: $0) }
    }

    var highlightsQuery: String? {
        try? String(contentsOfFile: installed.highlights, encoding: .utf8)
    }

    /// Where the language embeds others (D69).
    var injectionsQuery: String? {
        installed.injections.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
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

    func ensureInstalled(for url: URL, firstLine: @autoclosure () -> String? = nil) {
        guard let language = GrammarCatalog.shared.language(for: url, firstLine: firstLine()) else { return }
        install(language)
    }

    /// For a language a file embeds (D69); `name` is `SyntaxLanguage.name`.
    func ensureInstalled(named name: String) {
        guard let language = GrammarCatalog.shared.languages.first(where: { $0.name == name }) else { return }
        install(language)
    }

    /// Languages of a project's files, ahead of opening them; one at a time, in the background.
    func prefetch(_ paths: [String]) {
        var seen = Set<String>()
        let languages = paths.lazy.compactMap { GrammarCatalog.shared.language(for: URL(fileURLWithPath: $0)) }.filter { seen.insert($0.name).inserted }
        prefetching = Array(languages).filter { !installing.contains($0.name) && !failed.contains($0.name) && Grammar.languageToInstall(named: $0.name) != nil }
        prefetchNext()
    }

    @ObservationIgnored private var prefetching: [SyntaxLanguage] = []

    private func prefetchNext() {
        guard installing.isEmpty, !prefetching.isEmpty else { return }
        install(prefetching.removeFirst())
    }

    private func install(_ language: SyntaxLanguage) {
        guard !installing.contains(language.name), !failed.contains(language.name),
              let grammar = GrammarCatalog.shared.grammar(of: language) else { return }
        let current = InstalledGrammars.current.withLock { $0.first { $0.name == language.name } }
        if let current, current.isCurrent(language, grammar) { return }
        installing.insert(language.name)
        Task {
            let result = await Task.detached(priority: .utility) {
                Result { try GrammarStore.shared.install(language, grammar: grammar) }
            }.value
            installing.remove(language.name)
            defer { prefetchNext() }
            switch result {
            case .success(let grammar):
                InstalledGrammars.current.withLock { grammars in
                    grammars.removeAll { $0.name == grammar.name }
                    grammars.append(grammar)
                }
                revision += 1
                NotificationCenter.default.post(name: GrammarStore.didChange, object: grammar.name)
            case .failure:
                failed.insert(language.name)
            }
        }
    }
}
