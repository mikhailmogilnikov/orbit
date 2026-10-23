#if DEBUG
import AppKit
import OrbitAPI

/// The previews' part of a stress run (D244): an image, a PDF, an SVG and
/// Markdown that renders code, tables and links, opened, flipped to their
/// source and back; a page in the browser from the project.
@MainActor
enum PreviewStress {
    static func register(_ context: PluginContext) {
        let stress = context.stress
        stress.addFile("docs/image.png", png(width: 640, height: 400))
        stress.addFile("docs/sample.pdf", pdf(pages: 3))
        stress.addFile("docs/icon.svg", """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><circle cx="32" cy="32" r="28" fill="tomato"/>\
            <text x="32" y="38" text-anchor="middle" font-size="14">☃ ü</text></svg>
            """)
        stress.addFile("docs/readme.md", """
            # Ünïcödé readme

            Some *emphasis*, **bold**, `code`, a [link](https://example.invalid) and a [relative one](../src/short.tsx).

            ```swift
            func f(_ x: Int) -> Int { x * 2 }
            ```

            | Column | Another |
            | --- | ---: |
            | 👩‍👩‍👧 | שלום |

            ![missing image](missing.png) ![an image](image.png)

            - [ ] a task
            - [x] done
            > A quote
            """ + String(repeating: "\n\nA paragraph that goes on for a while to make the preview scroll.", count: 80))
        stress.addFile("docs/page.html", "<!doctype html><title>Stress</title><h1>Ünïcödé</h1><p>A local page.</p>")

        stress.add(StressStep("preview.markdown", weight: 2, covers: [StressCoverage.provider("preview.markdown")]) { run in
            await run.open(run.pick(["docs/readme.md", "docs/icon.svg"]) ?? "docs/readme.md")
            run.run("preview.markdown")
            await run.settle()
            if run.chance(0.5) { run.run("preview.markdown") }
        })
        stress.add(StressStep("preview.media", weight: 2, covers: [StressCoverage.provider("preview.media"), StressCoverage.provider("preview.svg")]) { run in
            await run.open(run.pick(["docs/image.png", "docs/sample.pdf", "docs/icon.svg"]) ?? "docs/image.png")
        })
        stress.exempt(StressCoverage.command("preview.browser"), because: "asks for an address; preview.page opens one from the project")
    }

    static func registerBrowser(_ context: PluginContext, store: BrowserStore) {
        context.stress.add(StressStep("preview.page", weight: 1, covers: [StressCoverage.provider("preview.browser")]) { run in
            store.openBrowser(run.file("docs/page.html"))
        })
    }

    private static func png(width: Int, height: Int) -> Data {
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in stride(from: 0, to: width, by: 4) {
            for y in stride(from: 0, to: height, by: 4) {
                image.setColor(NSColor(red: CGFloat(x) / CGFloat(width), green: CGFloat(y) / CGFloat(height), blue: 0.5, alpha: 1), atX: x, y: y)
            }
        }
        return image.representation(using: .png, properties: [:]) ?? Data()
    }

    private static func pdf(pages: Int) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data), let pdf = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        for page in 1...pages {
            pdf.beginPDFPage(nil)
            pdf.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
            pdf.fill(CGRect(x: 72, y: 72 * CGFloat(page), width: 200, height: 100))
            pdf.endPDFPage()
        }
        pdf.closePDF()
        return data as Data
    }
}
#endif
