import Foundation
@testable import OrbitEditor
import Testing

/// Find in File's matching and replacing (D227).
@Suite struct FindInFileTests {
    private func ranges(_ query: String, in text: String, _ options: FindOptions = FindOptions()) -> [NSRange] {
        guard let regex = FindMatching.regex(query, options: options) else { return [] }
        return FindMatching.ranges(of: regex, in: text as NSString).ranges
    }

    @Test func matchesPlainTextWithOptions() {
        let text = "Layout layout LayoutMain"
        #expect(ranges("layout", in: text).count == 3)
        #expect(ranges("layout", in: text, FindOptions(caseSensitive: true)) == [NSRange(location: 7, length: 6)])
        #expect(ranges("layout", in: text, FindOptions(wholeWord: true)).count == 2)
        // Not a pattern unless asked: a dot is a dot.
        #expect(ranges("a.b", in: "a.b axb").count == 1)
        #expect(ranges("a.b", in: "a.b axb", FindOptions(regex: true)).count == 2)
    }

    @Test func invalidPatternsAndEmptyMatchesFindNothing() {
        #expect(FindMatching.regex("(", options: FindOptions(regex: true)) == nil)
        #expect(FindMatching.regex("", options: FindOptions()) == nil)
        #expect(ranges("x*", in: "abc", FindOptions(regex: true)).isEmpty)
    }

    @Test func stopsAtTheLimit() {
        let regex = FindMatching.regex("a", options: FindOptions())!
        let found = FindMatching.ranges(of: regex, in: "aaaa" as NSString, limit: 3)
        #expect(found.ranges.count == 3)
        #expect(found.isTruncated)
    }

    @Test func nextAndPreviousWrapAround() {
        let matches = [NSRange(location: 2, length: 3), NSRange(location: 10, length: 3)]
        #expect(FindMatching.next(after: NSRange(location: 0, length: 0), in: matches) == 0)
        // From a selected match, the one after it; from the last, the first.
        #expect(FindMatching.next(after: matches[0], in: matches) == 1)
        #expect(FindMatching.next(after: matches[1], in: matches) == 0)
        #expect(FindMatching.previous(before: matches[1], in: matches) == 0)
        #expect(FindMatching.previous(before: matches[0], in: matches) == 1)
        #expect(FindMatching.next(after: NSRange(location: 0, length: 0), in: []) == nil)
    }

    @Test func replacesOneMatchWithCaptureGroups() {
        let text = "let a = 1; let b = 2" as NSString
        let options = FindOptions(regex: true)
        let regex = FindMatching.regex("let (\\w)", options: options)!
        let range = FindMatching.ranges(of: regex, in: text).ranges[1]
        let template = FindMatching.template(for: "var $1", options: options)
        #expect(FindMatching.replacement(for: range, regex: regex, template: template, in: text) == "var b")
        // Plain mode keeps `$1` literal.
        #expect(FindMatching.template(for: "$1", options: FindOptions()) == "\\$1")
    }

    @Test func wholeWordLooksAroundTheMatch() {
        // Searched from the match's own start, `\b` still sees the letter before it.
        let text = "xfoo foo" as NSString
        let regex = FindMatching.regex("foo", options: FindOptions(wholeWord: true))!
        #expect(FindMatching.replacement(for: NSRange(location: 1, length: 3), regex: regex, template: "bar", in: text) == nil)
        #expect(FindMatching.replacement(for: NSRange(location: 5, length: 3), regex: regex, template: "bar", in: text) == "bar")
    }

    @Test func replaceAllIsOneEditFromFirstToLastMatch() {
        let text = "a foo b foo c" as NSString
        let regex = FindMatching.regex("foo", options: FindOptions())!
        let result = FindMatching.replaceAll(in: text, regex: regex, template: "x")
        #expect(result?.span == NSRange(location: 2, length: 9))
        #expect(result?.text == "x b x")
        #expect(result?.count == 2)
        #expect(FindMatching.replaceAll(in: "abc", regex: regex, template: "x") == nil)
    }
}
