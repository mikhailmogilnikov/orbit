import Foundation
@testable import OrbitACP
@testable import OrbitAPI
@testable import OrbitEditor
@testable import OrbitLanguages
import Testing

/// D199: servers' edits that create, rename and delete files, and the rename preview.
@MainActor
@Suite(.serialized) struct WorkspaceEditTests {
    private func makeProject() throws -> (Workspace, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-edits-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "export const a = 1\n".write(to: root.appendingPathComponent("a.ts"), atomically: true, encoding: .utf8)
        try "import { a } from './a'\nconsole.log(a)\n".write(to: root.appendingPathComponent("b.ts"), atomically: true, encoding: .utf8)
        let workspace = Workspace()
        workspace.openFolder(root)
        return (workspace, root)
    }

    private static func edit(_ line: Int, _ start: Int, _ end: Int, _ text: String) -> JSONValue {
        ["range": ["start": ["line": .number(Double(line)), "character": .number(Double(start))],
                   "end": ["line": .number(Double(line)), "character": .number(Double(end))]],
         "newText": .string(text)]
    }

    @Test func documentChangesKeepTheirOrderWithFileOperations() throws {
        let (_, root) = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = LanguageServer(config: .swift, root: root)
        let a = root.appendingPathComponent("a.ts"), c = root.appendingPathComponent("c.ts")
        let edit = server.workspaceEdit(["documentChanges": [
            ["textDocument": ["uri": .string(a.absoluteString), "version": 1], "edits": [Self.edit(0, 13, 14, "x")]],
            ["kind": "rename", "oldUri": .string(a.absoluteString), "newUri": .string(c.absoluteString)],
            ["kind": "create", "uri": .string(root.appendingPathComponent("d/e.ts").absoluteString), "options": ["ignoreIfExists": true]],
            ["kind": "delete", "uri": .string(root.appendingPathComponent("b.ts").absoluteString)],
        ]])
        #expect(edit.steps.count == 4)
        #expect(edit.hasFileOperations)
        guard case .rename(let from, let to, false, false) = edit.steps[1] else {
            Issue.record("expected a rename, got \(edit.steps[1])")
            return
        }
        #expect(from == a && to == c)
        #expect(edit.touchedFiles.count == 4)
    }

    @Test func applyingRunsFileOperationsInOrder() throws {
        let (workspace, root) = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = LanguageManager(workspace: workspace)
        defer { manager.shutdown() }
        let a = root.appendingPathComponent("a.ts"), b = root.appendingPathComponent("b.ts")
        let renamed = root.appendingPathComponent("lib/alpha.ts"), created = root.appendingPathComponent("new.ts")
        let worked = manager.apply(WorkspaceEdit(steps: [
            .rename(a, to: renamed, overwrite: false, ignoreIfExists: false),
            // An edit after the rename goes to the new name.
            .edit(renamed, [SourceEdit(range: SourceRange(start: .init(line: 0, character: 13), end: .init(line: 0, character: 14)), newText: "alpha")]),
            .edit(b, [SourceEdit(range: SourceRange(start: .init(line: 0, character: 19), end: .init(line: 0, character: 22)), newText: "./lib/alpha")]),
            .create(created, overwrite: false, ignoreIfExists: false),
        ]))
        #expect(worked)
        #expect(!FileManager.default.fileExists(atPath: a.path))
        #expect(try String(contentsOf: renamed, encoding: .utf8) == "export const alpha = 1\n")
        #expect(try String(contentsOf: b, encoding: .utf8).hasPrefix("import { a } from './lib/alpha'"))
        #expect(FileManager.default.fileExists(atPath: created.path))
        // Creating what exists fails unless told to ignore it.
        #expect(!manager.apply(WorkspaceEdit(steps: [.create(created, overwrite: false, ignoreIfExists: false)])))
        #expect(manager.apply(WorkspaceEdit(steps: [.create(created, overwrite: false, ignoreIfExists: true)])))
    }

    @Test func previewRowsAndLeavingFilesOut() {
        let root = URL(fileURLWithPath: "/p")
        let a = root.appendingPathComponent("src/a.ts"), b = root.appendingPathComponent("b.ts"), c = root.appendingPathComponent("src/c.ts")
        let texts = [a: "let foo = 1\nfoo++\n", b: "use(foo)\n"]
        func change(_ line: Int, _ start: Int) -> SourceEdit {
            SourceEdit(range: SourceRange(start: .init(line: line, character: start), end: .init(line: line, character: start + 3)), newText: "bar")
        }
        let edit = WorkspaceEdit(steps: [
            .edit(a, [change(0, 4), change(1, 0)]),
            .edit(b, [change(0, 4)]),
            .rename(a, to: c, overwrite: false, ignoreIfExists: false),
        ])
        let preview = RenamePreview(edit: edit, oldName: "foo", newName: "bar", root: root) { texts[$0] }
        #expect(preview.rows.count == 3)
        let first = preview.rows.first { $0.url == a }
        #expect(first?.diff?.new == "let bar = 1\nbar++\n")
        #expect(first?.detail == "src")
        #expect(first?.badge == "2 lines")
        #expect(preview.rows.contains { $0.title == "a.ts → c.ts" })
        let withoutB = preview.edit(excluding: [preview.rows.first { $0.url == b }!.id])
        #expect(withoutB.steps.count == 2)
        #expect(withoutB.files[b] == nil)
    }

    /// D203: a list in "formatters" runs each on the one before's result, as one edit.
    @Test func formatterChainsRunInOrder() async throws {
        let (workspace, root) = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".orbit"), withIntermediateDirectories: true)
        try """
        { "formatters": { "txt": [
            { "command": "/usr/bin/tr", "arguments": ["a", "b"] },
            { "command": "/usr/bin/tr", "arguments": ["b", "c"] }
        ] } }
        """.write(to: root.appendingPathComponent(".orbit/settings.json"), atomically: true, encoding: .utf8)
        let file = root.appendingPathComponent("notes.txt")
        try "aaa\n".write(to: file, atomically: true, encoding: .utf8)

        let settings = try FormatterSettings.parse(Data(#"{ "formatters": { "ts, vue": ["server", "eslint"] } }"#.utf8), displayPath: "x")
        #expect(settings.rule(for: "vue") == .chain([.server, .preset("eslint")]))
        #expect(throws: FormatterSettings.Failure.self) {
            try FormatterSettings.parse(Data(#"{ "formatters": { "ts": ["eslint", "server"] } }"#.utf8), displayPath: "x")
        }

        let manager = LanguageManager(workspace: workspace)
        defer { manager.shutdown() }
        let document = workspace.documents.document(for: file)
        let outcome = await manager.format(file, lines: nil)
        #expect(outcome.formatter == "tr → tr", "\(outcome)")
        #expect(document.text == "ccc\n")
    }
}
