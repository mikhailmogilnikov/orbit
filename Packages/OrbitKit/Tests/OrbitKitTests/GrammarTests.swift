import Foundation
@testable import OrbitAPI
import SwiftTreeSitter
import Testing

/// Which of Zed's languages a file gets (D71), as Zed picks them.
@Suite struct GrammarCatalogTests {
    let catalog = GrammarCatalog.shared

    func name(_ path: String, firstLine: String? = nil) -> String? {
        catalog.language(for: URL(fileURLWithPath: path), firstLine: firstLine)?.name
    }

    @Test func picksLanguagesByFile() {
        #expect(name("/p/a.ts") == "TypeScript")
        #expect(name("/p/App.tsx") == "TSX")
        #expect(name("/p/a.js") == "JavaScript")
        #expect(name("/p/a.json") == "JSON")
        // The longest match wins: a whole file name over its extension.
        #expect(name("/p/tsconfig.json") == "JSONC")
        #expect(name("/p/.zshrc") == "Shell Script")
        #expect(name("/p/Gemfile") == "Ruby")
        #expect(name("/p/main.swift") == "Swift")
        #expect(name("/p/Page.astro") == "Astro")
        #expect(name("/p/main.tf") == "Terraform")
        #expect(name("/p/Dockerfile") == "Dockerfile")
        #expect(name("/p/README") == nil)
        #expect(name("/p/run", firstLine: "#!/usr/bin/env python3") == "Python")
    }

    @Test func picksEmbeddedLanguagesByName() {
        #expect(catalog.language(named: "typescript")?.name == "TypeScript")
        #expect(catalog.language(named: "js")?.name == "JavaScript")
        #expect(catalog.language(named: "markdown-inline")?.name == "Markdown-Inline")
        #expect(catalog.language(named: "sh")?.name == "Shell Script")
        #expect(catalog.language(named: "css")?.name == "CSS")
    }

    @Test func everyLanguageHasItsGrammar() {
        #expect(catalog.languages.count > 400)
        #expect(catalog.languages.allSatisfy { catalog.grammar(of: $0) != nil })
        #expect(Set(catalog.languages.map(\.id)).count == catalog.languages.count)
    }
}

/// Every language in the catalog, fetched at its commit, compiled, loaded and
/// its Zed queries compiled against it, as the editor does. Network and a
/// compiler: runs with `ORBIT_INSTALL_TESTS=1`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ORBIT_INSTALL_TESTS"] == "1"), .timeLimit(.minutes(60)))
struct GrammarInstallTests {
    static let store = GrammarStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("orbit-grammar-installs"))

    /// A few languages are also parsed, to check their captures are what themes style.
    static let samples: [String: (text: String, captures: Set<String>)] = [
        "TypeScript": ("// hi\nconst a: number = 1;\n", ["comment", "keyword", "type", "number"]),
        "TSX": ("// hi\nconst App = () => <div className=\"a\">{1}</div>;\n", ["comment", "keyword", "tag", "string"]),
        "Swift": ("// hi\nfunc greet(_ name: String) -> String { \"hello \\(name)\" }\n", ["comment", "keyword", "string", "type"]),
        "Astro": ("---\nconst a = 1;\n---\n<!-- hi -->\n<div class=\"a\">{a}</div>\n", ["comment", "tag", "attribute"]),
        "Lua": ("-- hi\nlocal function greet(name)\n  return \"hello \" .. name\nend\n", ["comment", "keyword", "string", "function"]),
        "Markdown-Inline": ("Some *emphasis*, `code` and [a link](https://example.com).", ["emphasis", "link_text", "link_uri"]),
    ]

    @Test(arguments: GrammarCatalog.shared.languages.map(\.name))
    func installsAndCompiles(_ name: String) throws {
        let catalog = GrammarCatalog.shared
        let source = try #require(catalog.languages.first { $0.name == name })
        let repository = try #require(catalog.grammar(of: source))
        let grammar = try Self.store.installed(source.id).flatMap { $0.isCurrent(source, repository) ? $0 : nil }
            ?? Self.store.install(source, grammar: repository)
        let pointer = try #require(GrammarLibraries.language(grammar), "\(name): no \(grammar.symbol) in \(grammar.library)")
        let language = Language(language: pointer)
        let query = try Query(language: language, data: Data(contentsOf: URL(fileURLWithPath: grammar.highlights)))
        if let injections = grammar.injections {
            _ = try Query(language: language, data: Data(contentsOf: URL(fileURLWithPath: injections)))
        }
        guard let sample = Self.samples[name] else { return }
        let parser = Parser()
        try parser.setLanguage(language)
        let tree = try #require(parser.parse(sample.text))
        #expect(tree.rootNode?.hasError == false, "\(name) couldn't parse its sample")
        let captures = Set(query.execute(in: tree).resolve(with: .init(string: sample.text)).highlights().map {
            String($0.name.split(separator: ".").first ?? "")
        })
        #expect(sample.captures.isSubset(of: captures), "\(name): \(captures.sorted())")
    }
}
