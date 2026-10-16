import Foundation
@testable import OrbitLanguages
import Testing

@Suite struct ToolSettingsTests {
    @Test func readsCompanionsAndActionsOnSave() throws {
        let json = """
        {
          "companions": { "eslint": "off", "tailwind": { "settings": { "tailwindCSS": { "validate": false } } }, "vue": { "enabled": true } },
          "codeActionsOnSave": { "ts, .tsx": ["source.organizeImports", "source.fixAll.eslint"], "js": "off" }
        }
        """
        let settings = try ToolSettings.parse(Data(json.utf8), displayPath: "test")
        #expect(settings.companions["eslint"] == .off)
        guard case .configured(let overrides)? = settings.companions["tailwindcss"] else {
            Issue.record("\(settings.companions)")
            return
        }
        #expect(overrides.settings?["tailwindCSS"]?["validate"]?.bool == false)
        #expect(settings.companions["vue-language-server"] == .on(.init()))
        let layers = [settings]
        #expect(ToolSettings.actionsOnSave(for: URL(fileURLWithPath: "/p/a.tsx"), in: layers) == ["source.organizeImports", "source.fixAll.eslint"])
        #expect(ToolSettings.actionsOnSave(for: URL(fileURLWithPath: "/p/a.js"), in: layers) == [])
        #expect(ToolSettings.actionsOnSave(for: URL(fileURLWithPath: "/p/a.jsx"), in: layers) == ToolSettings.defaultActionsOnSave)
    }

    @Test func theProjectWinsOverTheUser() throws {
        let project = try ToolSettings.parse(Data(#"{ "companions": { "eslint": "on" } }"#.utf8), displayPath: "p")
        let user = try ToolSettings.parse(Data(#"{ "companions": { "eslint": "off", "tailwindcss": "off" } }"#.utf8), displayPath: "u")
        #expect(ToolSettings.companion("eslint", in: [project, user]) == .on(.init()))
        #expect(ToolSettings.companion("tailwindcss", in: [project, user]) == .off)
        #expect(throws: (any Error).self) { try ToolSettings.parse(Data(#"{ "companions": { "eslint": 3 } }"#.utf8), displayPath: "p") }
    }
}
