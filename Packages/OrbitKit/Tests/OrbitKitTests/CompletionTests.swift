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

    @Test func linePatchesReplayServerEdits() {
        let old = "func  a( ) {\nreturn 1\n}\n\nlet keep = 2\nlet  x=1\n"
        let new = "func a() {\n    return 1\n}\n\nlet keep = 2\nlet x = 1\n"
        let patch = LinePatch(from: old, to: new)
        #expect(patch.replacements.count == 2)
        let result = NSMutableString(string: old)
        for replacement in patch.replacements { result.replaceCharacters(in: replacement.range, with: replacement.text) }
        #expect(result as String == new)
        // A caret on an untouched line stays put; one in a changed block keeps its line and column.
        let keep = (old as NSString).range(of: "keep").location
        #expect(patch.map(keep) == (new as NSString).range(of: "keep").location)
        let x = (old as NSString).range(of: "x=1").location
        #expect(patch.map(x) == (new as NSString).range(of: "let x").location + 5)
        #expect(patch.map((old as NSString).length) == (new as NSString).length)
    }

    @Test func linePatchesHandleInsertionsAndDeletions() {
        for (old, new) in [("a\nb\n", "a\nx\ny\nb\n"), ("a\nx\ny\nb", "a\nb"), ("", "z\n"), ("same", "same")] {
            let result = NSMutableString(string: old)
            for replacement in LinePatch(from: old, to: new).replacements { result.replaceCharacters(in: replacement.range, with: replacement.text) }
            #expect(result as String == new, "\(old.debugDescription) → \(new.debugDescription)")
        }
    }
}
