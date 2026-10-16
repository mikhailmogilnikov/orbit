@testable import OrbitPreview
import Testing

struct MarkdownHTMLTests {
    @Test func rendersBlocks() {
        let html = MarkdownHTML.render("""
        # Title
        ## Title

        Some *em* and **bold**, `code`, ~~gone~~ and [link](docs/a.md).

        - one
        - [x] done
        - [ ] todo

        1. first
        2. second

        > quoted

        ```swift
        let a = 1 < 2
        ```

        | A | B |
        |:-:|--:|
        | 1 | 2 |

        ---

        ![logo](img/logo.png)
        """, options: .init(resolveImage: { "orbit-file:///p/\($0)" }))
        #expect(html.contains("<h1 id=\"title\">Title</h1>"))
        #expect(html.contains("<h2 id=\"title-1\">Title</h2>"))
        #expect(html.contains("<em>em</em>"))
        #expect(html.contains("<strong>bold</strong>"))
        #expect(html.contains("<code>code</code>"))
        #expect(html.contains("<del>gone</del>"))
        #expect(html.contains("<a href=\"docs/a.md\">link</a>"))
        #expect(html.contains("<input type=\"checkbox\" disabled checked> done"))
        #expect(html.contains("<input type=\"checkbox\" disabled> todo"))
        #expect(html.contains("<ol>"))
        #expect(html.contains("<blockquote>"))
        #expect(html.contains("<pre><code class=\"language-swift\">let a = 1 &lt; 2</code></pre>"))
        #expect(html.contains("<th style=\"text-align:center\">A</th>"))
        #expect(html.contains("<td style=\"text-align:right\">2</td>"))
        #expect(html.contains("<hr>\n<p>"))
        #expect(!html.contains("value="))
        #expect(html.contains("<img src=\"orbit-file:///p/img/logo.png\" alt=\"logo\">"))
    }

    @Test func rendersFrontMatterAsTable() {
        let html = MarkdownHTML.render("""
        ---
        name: blade-markup
        description: "Builds Blade markup: a long line
          that goes on"
        tags:
          - ui
          - blade
        ---

        # Blade
        """)
        #expect(html.hasPrefix("<table class=\"front-matter\">"))
        #expect(html.contains("<tr><th>name</th><td>blade-markup</td></tr>"))
        #expect(html.contains("<th>description</th><td>Builds Blade markup: a long line that goes on</td>"))
        #expect(html.contains("<tr><th>tags</th><td>ui, blade</td></tr>"))
        #expect(html.contains("<h1 id=\"blade\">Blade</h1>"))
        #expect(!html.contains("<hr>"))
    }

    @Test func leavesARuleThatIsNotFrontMatter() {
        #expect(MarkdownHTML.frontMatter("Text\n---\nmore") == nil)
        #expect(MarkdownHTML.frontMatter("---\nno end") == nil)
    }
}
