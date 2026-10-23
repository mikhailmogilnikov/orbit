#if DEBUG
import AppKit
import OrbitAPI
import STTextView

/// The editor's part of a stress run (D244): files that are hard to show
/// and edit, editing as a person (and a bad day) would, and the text on
/// screen always being the document's.
@MainActor
enum EditorStress {
    static func register(_ context: OrbitAPI.PluginContext, options: EditorOptions) {
        let stress = context.stress
        addFiles(to: stress)

        func editor() -> CodeEditor.Coordinator? {
            ActiveEditor.shared.all.first { $0.document.url == context.workspace.activeTab?.url && $0.textView != nil }
        }
        let hasEditor: @MainActor (StressContext) -> Bool = { _ in editor() != nil }

        stress.add(StressStep("editor.type", weight: 8, when: hasEditor) { run in
            guard let textView = editor()?.textView else { return }
            for _ in 0..<run.int(1...4) {
                textView.insertText(run.pick(snippets) ?? "x", replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        })
        stress.add(StressStep("editor.keys", weight: 6, when: hasEditor) { run in
            guard let textView = editor()?.textView else { return }
            for _ in 0..<run.int(1...8) {
                if let key = run.pick(keys) { textView.doCommand(by: key) }
            }
        })
        stress.add(StressStep("editor.select", weight: 5, when: hasEditor) { run in
            guard let textView = editor()?.textView else { return }
            let length = textView.documentText.length
            textView.selectionRanges = (0..<run.int(1...3)).map { _ in
                let location = run.int(0...length)
                return NSRange(location: location, length: run.int(0...min(200, length - location)))
            }
            textView.scrollToPrimarySelection()
        })
        stress.add(StressStep("editor.manyCarets", weight: 2, when: hasEditor) { run in
            guard let textView = editor()?.textView else { return }
            let length = textView.documentText.length
            textView.selectionRanges = (0..<run.int(2...400)).map { _ in NSRange(location: run.int(0...length), length: 0) }
            textView.insertText(run.pick(snippets) ?? "x", replacementRange: NSRange(location: NSNotFound, length: 0))
        })
        stress.add(StressStep("editor.replaceAll", weight: 1, when: hasEditor) { run in
            guard let textView = editor()?.textView else { return }
            textView.selectAll(nil)
            textView.insertText(run.chance(0.3) ? "" : (run.pick(snippets) ?? ""), replacementRange: NSRange(location: NSNotFound, length: 0))
        })
        stress.add(StressStep("editor.undoRedo", weight: 4, when: hasEditor) { run in
            guard let undo = editor()?.textView?.undoManager else { return }
            for _ in 0..<run.int(1...10) {
                if run.chance(0.6) { if undo.canUndo { undo.undo() } } else if undo.canRedo { undo.redo() }
            }
        })
        stress.add(StressStep("editor.scroll", weight: 4, when: hasEditor) { run in
            guard let textView = editor()?.textView else { return }
            let length = textView.documentText.length
            textView.scrollRangeToVisible(NSRange(location: run.chance(0.3) ? length : run.int(0...length), length: 0))
        })
        stress.add(StressStep("editor.option", weight: 2) { run in
            guard let option = run.pick(EditorOptions.Option.allCases) else { return }
            options[option].toggle()
            run.note("\(option.rawValue): \(options[option])")
        })
        stress.add(StressStep("editor.typingUndoAll", weight: 1, when: hasEditor) { run in
            // Typing then undoing all of it gives the text back: undo and the buffer agree.
            guard let textView = editor()?.textView, let undo = textView.undoManager else { return }
            let before = textView.documentText as String
            textView.breakUndoCoalescing()
            for _ in 0..<run.int(1...5) {
                textView.insertText(run.pick(snippets) ?? "x", replacementRange: NSRange(location: NSNotFound, length: 0))
                textView.breakUndoCoalescing()
            }
            await run.settle()
            while undo.canUndo, textView.documentText as String != before { undo.undo() }
            if textView.documentText as String != before { run.note("undo didn't give the text back") }
        })
        // D243: Select All Occurrences in a long file, then Expand Selection, froze the editor.
        stress.add(StressStep("editor.selectAllThenExpand", weight: 1, regression: true) { run in
            await run.open("src/long.swift")
            guard let textView = editor()?.textView else { return }
            textView.selectionRanges = [NSRange(location: 0, length: 0)]
            run.run("editor.selectAllOccurrences")
            await run.settle()
            run.run("editor.expandSelection")
            await run.settle()
            // One caret again: the next steps would type into thousands.
            editor()?.textView?.selectionRanges = [NSRange(location: 0, length: 0)]
        })
        stress.add(StressStep("editor.formats", weight: 1) { run in
            // Line endings and encodings other than UTF-8 with LF (and the status item that shows them).
            // Every one, CRLF last: what the item shows when the step ends, in every run.
            for path in run.some(["latin1.txt", "utf16.txt", "binary.bin"], count: 3) + ["crlf.txt"] { await run.open(path) }
        })

        stress.add(StressCheck("editor.textIsTheDocument") { _ in
            for coordinator in ActiveEditor.shared.all {
                guard let textView = coordinator.textView, textView.window != nil else { continue }
                let shown = textView.documentText as String
                if shown != coordinator.document.text {
                    return "\(coordinator.document.url.lastPathComponent): the editor shows \(shown.utf16.count) characters, the document has \(coordinator.document.text.utf16.count)"
                }
                let length = (shown as NSString).length
                if let range = textView.selectionRanges.first(where: { NSMaxRange($0) > length }) {
                    return "\(coordinator.document.url.lastPathComponent): a selection at \(range) past the end (\(length))"
                }
            }
            return nil
        })
    }

    private static let snippets = [
        "a", "Hello, stress ", "\n", "\t", "    ", "{", "}", "()", "\"", "'", "`", "//", "/* */", "<div>", "</div>",
        "☃", "👩‍👩‍👧", "🏳️‍🌈", "שלום", "مرحبا", "e\u{301}", "漢字", "\u{200B}", "\r\n",
        "func f() {\n    return 1\n}\n", String(repeating: "x", count: 3000), String(repeating: "line\n", count: 300),
    ]

    private static let keys: [Selector] = [
        #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)),
        #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:)), #selector(NSResponder.deleteWordBackward(_:)),
        #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveRight(_:)),
        #selector(NSResponder.moveToBeginningOfDocument(_:)), #selector(NSResponder.moveToEndOfDocument(_:)),
        #selector(NSResponder.moveToBeginningOfLine(_:)), #selector(NSResponder.moveToEndOfLine(_:)),
        #selector(NSResponder.moveWordRight(_:)), #selector(NSResponder.pageDown(_:)), #selector(NSResponder.pageUp(_:)),
        #selector(NSResponder.moveDownAndModifySelection(_:)), #selector(NSResponder.moveWordLeftAndModifySelection(_:)),
        #selector(NSResponder.selectAll(_:)), #selector(NSResponder.selectLine(_:)), #selector(NSResponder.cancelOperation(_:)),
    ]

    private static func addFiles(to stress: StressRegistry) {
        stress.addFile("empty.txt", "")
        stress.addFile("one-line.txt", "no newline at the end")
        // Shorter than the window, like the file 0.4.0 crashed on (D237).
        stress.addFile("src/short.tsx", (1...48).map { "export const item\($0) = { id: \($0), title: 'Item \($0)' }\n" }.joined())
        stress.addFile("src/long.swift", (0..<6000).map { "func f\($0)(_ x: Int) -> Int { x * \($0) } // \(String(repeating: "·", count: $0 % 90))\n" }.joined())
        stress.addFile("src/minified.js", "var a=" + (0..<30000).map { "b\($0)=\($0)" }.joined(separator: ",") + ";")
        stress.addFile("crlf.txt", (0..<300).map { "line \($0)\r\n" }.joined())
        stress.addFile("blank.txt", String(repeating: "\n", count: 2000))
        stress.addFile("tabs.go", "package main\n\nfunc main() {\n" + (0..<400).map { String(repeating: "\t", count: $0 % 12) + "x\($0) := \($0)\n" }.joined() + "}\n")
        stress.addFile("huge.log", (0..<120_000).map { "2026-10-23 12:00:\(String(format: "%02d", $0 % 60)) INFO request \($0) took \($0 % 977) ms path=/api/v1/items/\($0)\n" }.joined())
        stress.addFile("unicode.txt", ["emoji: 👩‍👩‍👧‍👦 🏳️‍🌈 🇯🇵 ✋🏽 ", "RTL: שלום עולם مرحبا بالعالم ", "combining: e\u{301} a\u{308} Z\u{335}\u{336} ",
                                       "CJK: 漢字かなカナ한국어 ", "zero width: a\u{200B}b\u{200C}c\u{200D}d\u{FEFF}e"].map { String(repeating: $0, count: 8) + "\n" }.joined())
        stress.addFile("latin1.txt", "caf\u{E9} na\u{EF}ve r\u{E9}sum\u{E9}\n".data(using: .isoLatin1)!)
        stress.addFile("utf16.txt", "UTF-16 with a BOM: ☃ 漢字\n".data(using: .utf16)!)
        stress.addFile("binary.bin", Data((0..<65536).map { UInt8(truncatingIfNeeded: $0 &* 2654435761 >> 13) }))
        stress.addFile("src/deep/a/b/c/name with spaces & ünïcode.txt", "deep\n")
        stress.prepare { root in
            let fileManager = FileManager.default
            try fileManager.createSymbolicLink(atPath: root.appendingPathComponent("link-to-short.tsx").path, withDestinationPath: "src/short.tsx")
            try fileManager.createSymbolicLink(atPath: root.appendingPathComponent("link-to-deep").path, withDestinationPath: "src/deep")
            try fileManager.createSymbolicLink(atPath: root.appendingPathComponent("broken-link.txt").path, withDestinationPath: "missing.txt")
        }
    }
}
#endif
