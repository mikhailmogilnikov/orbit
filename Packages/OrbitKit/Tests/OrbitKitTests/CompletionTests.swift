import Foundation
@testable import OrbitAPI
import Testing

@Suite struct CompletionTests {
    @Test func matchesWordStartsInOrder() {
        let pattern = FuzzyPattern("gS")
        #expect(pattern.score("getString") != nil)
        #expect(pattern.score("toString") == nil)
        // The first letter has to start a word: "s" doesn't find "useState" by its middle.
        #expect(FuzzyPattern("tate").score("useState") == nil)
        #expect(FuzzyPattern("state").score("useState") != nil)
        #expect(FuzzyPattern("st").score("first_step") != nil)
    }

    @Test func prefixesRankFirst() throws {
        let pattern = FuzzyPattern("con")
        let ranked = ["reconnect", "constructor", "console", "isContent", "component"]
            .compactMap { candidate in pattern.score(candidate).map { (candidate, $0) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        #expect(ranked.prefix(2).sorted() == ["console", "constructor"])
        #expect(Set(ranked.dropFirst(2)) == ["isContent", "component"])
        #expect(!ranked.contains("reconnect"))
    }

    @Test func caseMatchesBreakTies() throws {
        let pattern = FuzzyPattern("Str")
        #expect(try #require(pattern.score("String")) > (try #require(pattern.score("strlen"))))
    }

    @Test func snippetsBecomeTextAndTabStops() {
        let call = Snippet("greet(name: ${1:String}, times: ${2:Int})$0")
        #expect(call.text == "greet(name: String, times: Int)")
        #expect(call.tabStops.map(\.index) == [1, 2, 0])
        #expect((call.text as NSString).substring(with: call.tabStops[0].range) == "String")
        #expect(call.tabStops[2].range == NSRange(location: 31, length: 0))

        let nested = Snippet("for (${1:let ${2:i} = 0}) {\n\t$0\n}")
        #expect(nested.text == "for (let i = 0) {\n\t\n}")
        #expect((nested.text as NSString).substring(with: nested.tabStops[1].range) == "i")

        #expect(Snippet("${1|public,private|} func").text == "public func")
        #expect(Snippet("price: \\$5 ${TM_SELECTED_TEXT}$1").text == "price: $5 ")
        #expect(Snippet("emoji 👋 ${1:x}").tabStops[0].range == NSRange(location: 9, length: 1))
    }
}
