import Foundation
@testable import OrbitAPI
@testable import OrbitLanguages
@testable import OrbitTerminal
import Testing

/// Packages bring snippets, agents, language servers and tasks (D195).
@MainActor
@Suite struct ExtensionPackageTests {
    @Test func snippetsReadVSCodesFormatWithCommentsAndScopes() throws {
        let json = """
        {
          // VS Code's files have comments and trailing commas.
          "For Loop": { "prefix": ["for", "fori"], "body": ["for ${1:item} in ${2:items} {", "\\t$0", "}"], "description": "A loop", },
          "Log": { "prefix": "log", "body": "console.log($1)", "scope": "javascript,typescriptreact" },
          "Broken": { "body": "no prefix" },
        }
        """
        let snippets = try CodeSnippet.parse(Data(json.utf8), language: "swift", source: "Test")
        #expect(snippets.map(\.name) == ["For Loop", "Log"])
        let loop = try #require(snippets.first)
        #expect(loop.prefixes == ["for", "fori"])
        #expect(loop.body == "for ${1:item} in ${2:items} {\n\t$0\n}")
        #expect(loop.languages == ["swift"])
        #expect(snippets[1].languages == ["javascript", "typescriptreact"])
    }

    @Test func aSnippetAppliesToItsLanguageByNameIdOrFileType() {
        let swift = CodeSnippet(name: "x", prefixes: ["x"], body: "x", languages: ["swift"], source: "")
        let everywhere = CodeSnippet(name: "y", prefixes: ["y"], body: "y", source: "")
        let swiftID = GrammarCatalog.shared.language(for: URL(fileURLWithPath: "/a.swift"))?.id
        #expect(swift.applies(toLanguage: swiftID, fileExtension: "swift"))
        #expect(!swift.applies(toLanguage: GrammarCatalog.shared.language(for: URL(fileURLWithPath: "/a.py"))?.id, fileExtension: "py"))
        #expect(everywhere.applies(toLanguage: nil, fileExtension: "txt"))
        // By file type alone, for a language without a grammar.
        #expect(CodeSnippet(name: "z", prefixes: ["z"], body: "", languages: ["zzz"], source: "").applies(toLanguage: nil, fileExtension: "zzz"))
    }

    @Test func aPackageCountsEverythingItBrings() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-package-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let manager = FileManager.default
        try manager.createDirectory(at: folder.appendingPathComponent("snippets"), withIntermediateDirectories: true)
        try manager.createDirectory(at: folder.appendingPathComponent("agents"), withIntermediateDirectories: true)
        try #"{"id": "kotlin", "name": "Kotlin Tools", "version": "1.0.0"}"#.write(to: folder.appendingPathComponent("extension.json"), atomically: true, encoding: .utf8)
        try #"{"Main": {"prefix": "main", "body": "fun main() {\n\t$0\n}"}}"#.write(to: folder.appendingPathComponent("snippets/kotlin.json"), atomically: true, encoding: .utf8)
        try #"{"id": "k-agent", "name": "K Agent", "command": {"executable": "k-agent"}}"#.write(to: folder.appendingPathComponent("agents/k-agent.json"), atomically: true, encoding: .utf8)
        try #"{"servers": [{"id": "kotlin-lsp", "name": "Kotlin", "fileTypes": {"kt": "kotlin"}, "command": "kotlin-lsp", "install": {"mason": "kotlin-lsp"}}]}"#
            .write(to: folder.appendingPathComponent("language_servers.json"), atomically: true, encoding: .utf8)
        try #"{"tasks": [{"name": "build", "command": "gradle build", "when": ["build.gradle.kts", "build.gradle"]}]}"#
            .write(to: folder.appendingPathComponent("tasks.json"), atomically: true, encoding: .utf8)

        let loaded = try #require(try Extensions.load(folder, isBuiltin: false))
        #expect(loaded.problems.isEmpty)
        #expect(loaded.entry.snippetCount == 1)
        #expect(loaded.entry.agentCount == 1)
        #expect(loaded.entry.languageServerCount == 1)
        #expect(loaded.entry.taskCount == 1)
        #expect(loaded.entry.runsPrograms)
        #expect(loaded.snippets.first?.languages == ["kotlin"])
        #expect(loaded.snippets.first?.source == "Kotlin Tools")

        let servers = try ExtensionServers.parse(Data(contentsOf: folder.appendingPathComponent("language_servers.json")), folder: folder, extensionName: "Kotlin Tools")
        let server = try #require(servers.first)
        #expect(server.serves(URL(fileURLWithPath: "/p/Main.kt")))
        #expect(server.install?.package == "kotlin-lsp")
        #expect(server.launch == [.installed, .path(binary: "kotlin-lsp")])

        // An extension's server comes first for its file types.
        ExtensionServers.set(servers)
        defer { ExtensionServers.set([]) }
        #expect(LanguageServerConfig.candidates(for: URL(fileURLWithPath: "/p/Main.kt")).first?.id == "kotlin-lsp")
        #expect(LanguageServerConfig.config(id: "kotlin-lsp") != nil)
    }

    @Test func extensionTasksShowWhereTheirFileIs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-tasks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let templates = try TaskTemplate.parse(Data(#"""
        {"tasks": [
          {"name": "deploy", "command": "fly deploy", "when": "fly.toml"},
          {"name": "hello", "command": "echo hi"}
        ]}
        """#.utf8), source: "Fly")
        #expect(ProjectTasks.find(in: root, templates: templates).map(\.name) == ["hello"])
        try "".write(to: root.appendingPathComponent("fly.toml"), atomically: true, encoding: .utf8)
        let found = ProjectTasks.find(in: root, templates: templates)
        #expect(found.map(\.name) == ["deploy", "hello"])
        #expect(found.first?.source == "Fly")
    }
}
