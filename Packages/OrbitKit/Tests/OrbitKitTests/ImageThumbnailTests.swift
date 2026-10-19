import AppKit
@testable import OrbitEditor
@testable import OrbitPreview
import Testing

@Suite struct ImageThumbnailTests {
    @Test func linesNamingImagesThatExistGetThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("images-\(UUID().uuidString)").standardizedFileURL
        defer { try? FileManager.default.removeItem(at: root) }
        for file in ["src/components/logo.png", "public/hero.webp", "src/assets/icon.svg", "src/components/Card.tsx"] {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        let file = root.appendingPathComponent("src/components/Card.tsx")
        let code = """
        import logo from './logo.png'
        import icon from '@/assets/icon.svg'
        const hero = <img src="/hero.webp" alt="" />
        const remote = "https://cdn.example.com/hero.webp"
        const missing = './nope.png'
        background: url(../assets/icon.svg);
        """
        let images = ImageReferences.find(in: code, file: file, root: root)
        #expect(images[0] == root.appendingPathComponent("src/components/logo.png"))
        #expect(images[1] == root.appendingPathComponent("src/assets/icon.svg"))
        #expect(images[2] == root.appendingPathComponent("public/hero.webp"))
        #expect(images[3] == nil)
        #expect(images[4] == nil)
        #expect(images[5] == root.appendingPathComponent("src/assets/icon.svg"))
    }

    @Test @MainActor func svgTextBecomesAnImageOnlyWhenValid() {
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="24" height="16"><rect width="24" height="16" fill="red"/></svg>"#
        #expect(SVGPreview.image(svg)?.size == NSSize(width: 24, height: 16))
        #expect(SVGPreview.image("<svg xmlns=\"http://www.w3.org/2000/svg\"><rect") == nil)
        #expect(SVGPreview.image("not svg") == nil)
    }
}
