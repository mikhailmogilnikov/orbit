import Testing
@testable import OrbitEditor

@MainActor
@Suite struct EditingRulesTests {
    @Test func lineCommentsToggleAtTheCommonIndent() {
        let code = "  let a = 1\n\n    let b = 2\n"
        let commented = EditingRules.toggleLineComments(code, prefix: "// ", all: ["// "])
        #expect(commented == "  // let a = 1\n\n  //   let b = 2\n")
        #expect(EditingRules.toggleLineComments(commented, prefix: "// ", all: ["// "]) == code)
    }

    @Test func longerMarkersComeOffWhole() {
        #expect(EditingRules.toggleLineComments("/// doc\n", prefix: "// ", all: ["// ", "/// "]) == "doc\n")
    }

    @Test func blockCommentsWrapAndUnwrap() {
        let wrapped = EditingRules.toggleBlockComment("  <div>\n", start: "<!--", end: "-->")
        #expect(wrapped == "  <!-- <div> -->\n")
        #expect(EditingRules.toggleBlockComment(wrapped, start: "<!--", end: "-->") == "  <div>\n")
    }
}
