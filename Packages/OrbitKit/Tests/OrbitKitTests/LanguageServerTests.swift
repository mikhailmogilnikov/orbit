import Foundation
@testable import OrbitACP
@testable import OrbitAPI
@testable import OrbitLanguages
import Testing

@Suite struct LanguageServerTests {
    @Test func incrementalChangeCoversOnlyTheEdit() throws {
        let change = try #require(TextChange(from: "let a = 1\nlet b = 2\n", to: "let a = 1\nlet bc = 2\n"))
        #expect(change.range == SourceRange(start: SourcePosition(line: 1, character: 5), end: SourcePosition(line: 1, character: 5)))
        #expect(change.text == "c")

        let deletion = try #require(TextChange(from: "one\ntwo\nthree", to: "one\nthree"))
        // "one\nt|wo\nt|hree": the shared "t" and "hree" stay.
        #expect(deletion.range.start == SourcePosition(line: 1, character: 1))
        #expect(deletion.range.end == SourcePosition(line: 2, character: 1))
        #expect(deletion.text == "")

        #expect(TextChange(from: "same", to: "same") == nil)
    }

    @Test func changeNeverSplitsSurrogatePairs() throws {
        // 😀 and 😃 share their lead surrogate.
        let change = try #require(TextChange(from: "a😀b", to: "a😃b"))
        #expect(change.range.start.character == 1)
        #expect(change.range.end.character == 3)
        #expect(change.text == "😃")
    }

    @Test func positionsRoundTripThroughOffsets() {
        let text = "ab\ncd\n\nef" as NSString
        let starts = SourcePosition.lineStarts(of: text)
        #expect(starts == [0, 3, 6, 7])
        let position = SourcePosition(offset: 4, in: starts)
        #expect(position == SourcePosition(line: 1, character: 1))
        #expect(position.offset(in: starts, length: text.length) == 4)
        // Past the end of a line clamps to it.
        #expect(SourcePosition(line: 0, character: 99).offset(in: starts, length: text.length) == 3)
    }

    @Test func readsServerPayloads() throws {
        let diagnostic = try #require(LanguageServer.diagnostic([
            "range": ["start": ["line": 2, "character": 4], "end": ["line": 2, "character": 9]],
            "severity": 2, "message": "Unused variable", "source": "ts",
        ]))
        #expect(diagnostic.severity == .warning)
        #expect(diagnostic.range.end.character == 9)

        #expect(LanguageServer.markdown(["kind": "markdown", "value": "**x**"]) == "**x**")
        #expect(LanguageServer.markdown([["language": "swift", "value": "let x: Int"], "doc"]) == "```swift\nlet x: Int\n```\n\ndoc")
        #expect(LanguageServer.fileURL("file:///tmp/a%20b.ts")?.path == "/tmp/a b.ts")
        #expect(LanguageServer.fileURL("sourcekit-lsp://x") == nil)
    }

    @Test func serversArePickedByExtension() {
        #expect(LanguageServerConfig.config(for: URL(fileURLWithPath: "/p/App.swift"))?.id == "sourcekit-lsp")
        #expect(LanguageServerConfig.config(for: URL(fileURLWithPath: "/p/a.tsx"))?.languageID(for: URL(fileURLWithPath: "/p/a.tsx")) == "typescriptreact")
        #expect(LanguageServerConfig.config(for: URL(fileURLWithPath: "/p/README.md")) == nil)
    }
}
