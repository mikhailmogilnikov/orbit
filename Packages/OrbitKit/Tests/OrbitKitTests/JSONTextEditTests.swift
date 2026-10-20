import Foundation
@testable import OrbitAPI
import Testing

@Suite struct JSONTextEditTests {
    private func set(_ key: String, _ literal: String?, _ text: String) throws -> String {
        try #require(JSONTextEdit.set(key, to: literal, in: text))
    }

    @Test func replacesInPlaceKeepingTheRest() throws {
        let text = """
        {
          "formatters": { "py": "ruff" },
          "editor": {
            "wordWrap": false,
            "blame": true
          }
        }

        """
        #expect(try set("editor.wordWrap", "true", text) == text.replacingOccurrences(of: "\"wordWrap\": false", with: "\"wordWrap\": true"))
    }

    @Test func addsToTheSectionInItsIndentation() throws {
        let text = "{\n    \"editor\": {\n        \"blame\": true\n    }\n}\n"
        #expect(try set("editor.wordWrap", "true", text) == "{\n    \"editor\": {\n        \"blame\": true,\n        \"wordWrap\": true\n    }\n}\n")
        #expect(try set("editor.wordWrap", "true", #"{ "editor": { "blame": true } }"#) == #"{ "editor": { "blame": true, "wordWrap": true } }"#)
    }

    @Test func addsTheSectionWhenMissing() throws {
        #expect(try set("editor.wordWrap", "true", "{\n}\n") == "{\n  \"editor\": {\n    \"wordWrap\": true\n  }\n}\n")
        #expect(try set("editor.wordWrap", "true", "") == "{\n  \"editor\": {\n    \"wordWrap\": true\n  }\n}\n")
        #expect(try set("agents.default", JSONTextEdit.quoted("codex"), "{\n  \"editor\": {}\n}") == "{\n  \"editor\": {},\n  \"agents\": {\n    \"wordWrap\": true\n  }\n}".replacingOccurrences(of: "\"wordWrap\": true", with: "\"default\": \"codex\""))
    }

    @Test func dottedKeysAtTheTopAreEditedThere() throws {
        #expect(try set("editor.wordWrap", "false", #"{"editor.wordWrap": true}"#) == #"{"editor.wordWrap": false}"#)
        #expect(try set("editor.wordWrap", nil, #"{"a": 1, "editor.wordWrap": true}"#) == #"{"a": 1}"#)
    }

    @Test func removesFirstMiddleLastAndOnly() throws {
        let text = "{\n  \"editor\": {\n    \"a\": 1,\n    \"b\": 2,\n    \"c\": 3\n  }\n}"
        #expect(try set("editor.a", nil, text) == "{\n  \"editor\": {\n    \"b\": 2,\n    \"c\": 3\n  }\n}")
        #expect(try set("editor.b", nil, text) == "{\n  \"editor\": {\n    \"a\": 1,\n    \"c\": 3\n  }\n}")
        #expect(try set("editor.c", nil, text) == "{\n  \"editor\": {\n    \"a\": 1,\n    \"b\": 2\n  }\n}")
        #expect(try set("editor.a", nil, #"{"editor": {"a": 1}}"#) == #"{"editor": {}}"#)
        #expect(try set("editor.z", nil, text) == text)
    }

    @Test func refusesWhatIsNotAnObject() {
        #expect(JSONTextEdit.set("a", to: "1", in: "[1, 2]") == nil)
        #expect(JSONTextEdit.set("a", to: "1", in: "{\"a\": }") == nil)
    }

    @Test func resultsStayValid() throws {
        let text = #"{"s": "a \"quoted\" } brace", "n": [1, {"x": null}], "editor": {"blame": false}}"#
        let edited = try set("editor.wordWrap", "true", text)
        let parsed = try #require(ProjectSettings.parse(Data(edited.utf8)))
        #expect(parsed["editor.wordWrap"] == .bool(true) && parsed["s"] == .string(#"a "quoted" } brace"#))
    }
}
