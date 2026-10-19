@testable import OrbitUI
import Testing

@Suite struct MarkdownTextTests {
    @Test func detailsFoldAroundAnImage() {
        let text = """
        Build passed.

        <details>
        <summary>Screenshot</summary>

        ![Checked on the API fixture](/tmp/shot.png)

        </details>
        Done.
        """
        #expect(MarkdownText.segments(text) == [
            .prose("Build passed."),
            .details(summary: "Screenshot", body: "![Checked on the API fixture](/tmp/shot.png)"),
            .prose("Done."),
        ])
        #expect(MarkdownText.segments("![shot](</tmp/a b.png>)") == [.image(alt: "shot", source: "/tmp/a b.png")])
    }

    @Test func codeInsideFencesStaysCode() {
        #expect(MarkdownText.segments("```html\n<details>\n```") == [.code(language: "html", code: "<details>")])
    }
}
