import AppKit
import STTextView
import XCTest
@testable import OrbitAPI
@testable import OrbitEditor

/// Editor highlighting cost on an offscreen window (D48). Skipped unless
/// `ORBIT_BENCH` is set; numbers only mean something in release:
/// `ORBIT_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter HighlightBenchmark`.
/// XCTest rather than Swift Testing: its tests run outside a main-queue block,
/// so spinning the run loop delivers the highlighter's main-queue callbacks.
@MainActor
final class HighlightBenchmark: XCTestCase {
    func testBenchmark() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["ORBIT_BENCH"] == nil)
        for lines in [2_000, 20_000] { run(lines: lines) }
    }

    private func run(lines: Int) {
        let (window, textView) = makeEditor(source(lines: lines))
        defer { window.close() }
        let (open, colored) = timeToStable(textView)
        report(lines, "open: \(colored) visible units colored after \(Int(open * 1000)) ms")

        // Jumps (go to line, ⌘↓): time until the new screen is laid out and colored.
        let scrollView = textView.enclosingScrollView!
        var layouts: [Double] = [], toColored: [Double] = []
        for i in 1...8 {
            let start = Date()
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: textView.frame.height * Double(i) / 9))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            textView.layoutSubtreeIfNeeded()
            layouts.append(Date().timeIntervalSince(start))
            let (settled, _) = timeToStable(textView)
            toColored.append(layouts.last! + settled)
        }
        report(lines, "jump: layout \(ms(layouts)), colored after \(ms(toColored))")

        // Trackpad-like steps: main-thread cost per step.
        var steps: [Double] = []
        let base = scrollView.contentView.bounds.origin.y
        for i in 1...60 {
            let start = Date()
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: base + Double(i) * 40))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            textView.layoutSubtreeIfNeeded()
            textView.displayIfNeeded()
            RunLoop.main.run(mode: .default, before: Date())
            steps.append(Date().timeIntervalSince(start))
        }
        report(lines, "40 pt scroll step: \(ms(steps)), max \(ms([steps.max()!]))")

        // Typing in the middle of the screen, quotes and comments included.
        let viewport = NSRange(textView.textLayoutManager.textViewportLayoutController.viewportRange!, in: textView.textContentManager)
        textView.textSelection = NSRange(location: viewport.location + viewport.length / 2, length: 0)
        var keys: [Double] = []
        for character in "let value = foo(bar: \"baz\") // done " {
            let start = Date()
            textView.insertText(String(character), replacementRange: textView.textSelection)
            textView.layoutSubtreeIfNeeded()
            keys.append(Date().timeIntervalSince(start))
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        report(lines, "keystroke: \(ms(keys)), max \(ms([keys.max()!]))")
    }

    private func source(lines target: Int) -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Sources")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
        var lines: [Substring] = []
        while lines.count < target {
            for file in files where lines.count < target {
                lines += (try! String(contentsOf: file, encoding: .utf8)).split(separator: "\n", omittingEmptySubsequences: false)
            }
        }
        return lines.prefix(target).joined(separator: "\n")
    }

    private func makeEditor(_ text: String) -> (NSWindow, STTextView) {
        let frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let scrollView = OrbitTextView.scrollableTextView(frame: frame)
        let textView = scrollView.documentView as! STTextView
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isHorizontallyResizable = true
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        textView.text = text
        let palette = SyntaxPalette(theme: Extensions.shared.colorTheme(dark: false))
        textView.addPlugin(SyntaxHighlightPlugin(palette: palette, grammar: try! TestGrammars.grammar("Swift")))
        textView.layoutSubtreeIfNeeded()
        return (window, textView)
    }

    /// Visible UTF-16 units that carry a highlight color.
    private func coloredCount(_ textView: STTextView) -> Int {
        let layoutManager = textView.textLayoutManager
        guard let viewport = layoutManager.textViewportLayoutController.viewportRange else { return 0 }
        let manager = textView.textContentManager
        let visible = NSRange(viewport, in: manager)
        var count = 0
        layoutManager.enumerateRenderingAttributes(from: viewport.location, reverse: false) { _, attributes, textRange in
            let range = NSRange(textRange, in: manager)
            guard range.location < NSMaxRange(visible) else { return false }
            if attributes[.foregroundColor] != nil { count += NSIntersectionRange(range, visible).length }
            return true
        }
        return count
    }

    /// Seconds until the visible colors stop changing for 250 ms.
    private func timeToStable(_ textView: STTextView, timeout: Double = 5) -> (Double, Int) {
        let start = Date()
        var last = coloredCount(textView), lastChange = start
        while Date().timeIntervalSince(start) < timeout, Date().timeIntervalSince(lastChange) < 0.25 {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.001))
            textView.layoutSubtreeIfNeeded()
            let count = coloredCount(textView)
            if count != last { (last, lastChange) = (count, Date()) }
        }
        return (lastChange.timeIntervalSince(start), last)
    }

    private func report(_ lines: Int, _ message: String) {
        print("[highlight bench, \(lines) lines] \(message)")
    }

    private func ms(_ values: [Double]) -> String {
        String(format: "%.1f ms", values.reduce(0, +) / Double(values.count) * 1000)
    }
}
