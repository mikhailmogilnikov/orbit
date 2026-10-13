import Foundation
@testable import OrbitAPI
import SwiftTreeSitter
import Testing

/// Every installable grammar (D58), fetched at its commit, compiled, loaded
/// and run with its Zed highlight query on a sample, as the editor does.
/// Network and a compiler: runs with `ORBIT_INSTALL_TESTS=1`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ORBIT_INSTALL_TESTS"] == "1"), .timeLimit(.minutes(10)))
struct GrammarInstallTests {
    static let store = GrammarStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("orbit-grammar-installs"))

    static let samples: [String: (text: String, captures: Set<String>)] = [
        "lua": ("-- hi\nlocal function greet(name)\n  return \"hello \" .. name\nend\n", ["comment", "keyword", "string", "function"]),
        "zig": ("// hi\nconst std = @import(\"std\");\npub fn main() void {}\n", ["comment", "keyword", "string"]),
        "hcl": ("# hi\nresource \"aws_instance\" \"web\" {\n  count = 2\n}\n", ["comment", "string", "number"]),
        "dockerfile": ("# hi\nFROM ubuntu:24.04\nRUN echo \"hi\"\n", ["comment", "keyword"]),
        "kotlin": ("// hi\nfun greet(name: String): String = \"hello $name\"\n", ["comment", "keyword", "string", "type"]),
        "svelte": ("<script>\n  let count = 0;\n</script>\n<!-- hi -->\n<button on:click={() => count++}>{count}</button>\n", ["comment", "tag"]),
        "scss": ("// hi\n$color: red;\n.a { .b { color: $color; } }\n", ["comment", "property"]),
        "tsx": ("// hi\nconst App = () => <div className=\"a\">{1}</div>;\n", ["comment", "keyword", "tag", "string"]),
    ]

    @Test(arguments: GrammarSource.all.map(\.name))
    func installsAndHighlights(_ name: String) throws {
        let source = try #require(GrammarSource.all.first { $0.name == name })
        let grammar = try Self.store.installed(name).flatMap { $0.commit == source.commit ? $0 : nil } ?? Self.store.install(source)
        let pointer = try #require(GrammarLibraries.language(grammar), "\(name): no tree_sitter_\(name) in \(grammar.library)")
        let language = Language(language: pointer)
        let query = try Query(language: language, data: Data(contentsOf: URL(fileURLWithPath: grammar.highlights)))
        let sample = try #require(Self.samples[name])
        let parser = Parser()
        try parser.setLanguage(language)
        let tree = try #require(parser.parse(sample.text))
        #expect(tree.rootNode?.hasError == false, "\(name) couldn't parse its sample")
        let captures = Set(query.execute(in: tree).resolve(with: .init(string: sample.text)).highlights().map {
            String($0.name.split(separator: ".").first ?? "")
        })
        #expect(sample.captures.isSubset(of: captures), "\(name): \(captures.sorted())")
    }

    @Test func picksGrammarsByFile() {
        #expect(GrammarSource.source(for: URL(fileURLWithPath: "/p/main.tf"))?.name == "hcl")
        #expect(GrammarSource.source(for: URL(fileURLWithPath: "/p/Dockerfile"))?.name == "dockerfile")
        #expect(GrammarSource.source(for: URL(fileURLWithPath: "/p/App.tsx"))?.name == "tsx")
        #expect(GrammarSource.source(for: URL(fileURLWithPath: "/p/main.swift")) == nil)
    }
}
