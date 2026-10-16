import Foundation
import Testing
@testable import OrbitAPI

@Suite struct ProjectSettingsTests {
    @Test func sectionsAndDottedKeysReadTheSame() throws {
        let data = Data(#"{ "editor": { "wordWrap": true, "tabSize": 2 }, "agents.default": "codex", "formatters": { "ts": ["prettier"] } }"#.utf8)
        let values = try #require(ProjectSettings.parse(data))
        #expect(values["editor.wordWrap"] == .bool(true))
        #expect(values["editor.tabSize"] == .number(2))
        #expect(values["agents.default"] == .string("codex"))
        // Lists and deeper objects belong to the plugins that read them.
        #expect(values["formatters.ts"] == nil)
    }

    @Test func invalidJSONIsNotSettings() {
        #expect(ProjectSettings.parse(Data("{ editor: ".utf8)) == nil)
        #expect(ProjectSettings.parse(Data("[]".utf8)) == nil)
    }
}
