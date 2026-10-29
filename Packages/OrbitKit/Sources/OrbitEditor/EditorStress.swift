#if DEBUG
import AppKit
import OrbitAPI
@_spi(Plugins) import STTextView

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
            var typed: [String] = []
            for _ in 0..<run.int(1...4) {
                let snippet = run.pick(snippets) ?? "x"
                textView.insertText(snippet, replacementRange: NSRange(location: NSNotFound, length: 0))
                typed.append(snippet.count > 12 ? "\(snippet.prefix(8).debugDescription)… (\(snippet.utf16.count))" : snippet.debugDescription)
            }
            run.note("\(typed.joined(separator: " ")) at \(textView.selectionRanges.first?.location ?? -1) of \(textView.documentText.length)")
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
        // D251: wrapped Markdown scrolled up 100 points at a time from its end,
        // where above the screen is estimated: a line on screen moves by 100.
        // What moves otherwise is noted (it was 26 of 80 steps, by 18–54 points).
        stress.add(StressStep("editor.wrappedScroll", weight: 1) { run in
            let wrapped = options.wrapsLines
            options.wrapsLines = true
            defer { options.wrapsLines = wrapped }
            await run.open("docs/long.md")
            guard let textView = editor()?.textView, let scrollView = textView.enclosingScrollView else { return }
            // Read some way down first: laid out there, estimated past it.
            for _ in 0..<80 {
                let origin = scrollView.contentView.bounds.origin
                scrollView.contentView.scroll(to: NSPoint(x: origin.x, y: origin.y + 100))
                scrollView.reflectScrolledClipView(scrollView.contentView)
                scrollView.layoutSubtreeIfNeeded()
            }
            textView.scrollRangeToVisible(NSRange(location: textView.documentText.length, length: 0))
            await run.settle()
            let content = textView.textContentManager
            // A paragraph in the middle of the screen: where it starts, and how far below the top.
            @MainActor func middle() -> (location: Int, y: CGFloat)? {
                let visible = textView.visibleRect
                guard let fragment = textView.textLayoutManager.textLayoutFragment(for: CGPoint(x: 0, y: visible.midY - textView.contentFrame.minY)) else { return nil }
                return (content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location),
                        fragment.layoutFragmentFrame.minY + textView.contentFrame.minY - visible.minY)
            }
            var jumps: [String] = []
            for step in 0..<80 {
                let origin = scrollView.contentView.bounds.origin
                guard let before = middle(), origin.y > 100 else { break }
                scrollView.contentView.scroll(to: NSPoint(x: origin.x, y: origin.y - 100))
                scrollView.reflectScrolledClipView(scrollView.contentView)
                scrollView.layoutSubtreeIfNeeded()
                await run.settle()
                guard let location = content.location(content.documentRange.location, offsetBy: before.location),
                      let fragment = textView.textLayoutManager.textLayoutFragment(for: location) else { continue }
                let now = fragment.layoutFragmentFrame.minY + textView.contentFrame.minY - textView.visibleRect.minY
                let jump = now - before.y - 100
                if abs(jump) > 1 { jumps.append("\(step): \(Int(jump))") }
            }
            run.note("text moved by more or less than scrolled: \(jumps.count) of 80 steps \(jumps.prefix(8).joined(separator: ", "))")
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
        // Typed in the editor, not saved, while an agent writes the same file on disk.
        stress.add(StressStep("editor.typeWhileAgentWrites", weight: 2) { run in
            let path = run.pick(["tabs.go", "src/short.tsx", "one-line.txt"]) ?? "tabs.go"
            await run.open(path)
            guard let textView = editor()?.textView, let tracker = context.services.resolve(ChangeTracking.self) else { return }
            textView.selectionRanges = [NSRange(location: run.int(0...textView.documentText.length), length: 0)]
            textView.insertText(run.pick(snippets) ?? "x", replacementRange: NSRange(location: NSNotFound, length: 0))
            if run.chance(0.5) { await run.settle() }
            _ = await tracker.beginAgentTurn()
            let url = run.file(path)
            if var lines = (try? String(contentsOf: url, encoding: .utf8))?.components(separatedBy: "\n") {
                lines.insert("// written by a pretend agent \(run.int(0...999))", at: min(lines.count, run.int(0...20)))
                try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            }
            if run.chance(0.5) { textView.insertText("typed during the turn", replacementRange: NSRange(location: NSNotFound, length: 0)) }
            await tracker.refreshAgentChanges()
            await tracker.endAgentTurn()
            context.workspace.fileSystemDidChange()
        })
        // D243: Select All Occurrences in a long file, then Expand Selection, froze the editor.
        // A merge's markers resolved as the conflict bar does, a block at a
        // time or all at once, or edited by hand into a mess (D246).
        stress.add(StressStep("editor.resolveConflicts", weight: 2, needs: "git.conflict", when: { _ in editor().map { MergeConflicts.hasMarkers($0.document.text) } == true }) { run in
            guard let coordinator = editor() else { return }
            let choice = run.pick([MergeConflicts.Choice.current, .incoming, .both]) ?? .current
            switch run.int(0...3) {
            case 0: coordinator.resolveAllConflicts(choice)
            case 1:
                coordinator.revealConflict(forward: run.chance(0.5))
                await run.settle()
                fallthrough
            case 2:
                let conflicts = MergeConflicts.find(in: LineDiff.lines(coordinator.document.text))
                if let conflict = run.pick(conflicts) { coordinator.resolveConflict(conflict, choice) }
            default:
                guard let textView = coordinator.textView, let separator = MergeConflicts.find(in: LineDiff.lines(coordinator.document.text)).first?.separator else { return }
                // The ======= line deleted: what's left is no block at all.
                let text = textView.documentText
                var start = 0
                for _ in 0..<separator { start = NSMaxRange(text.lineRange(for: NSRange(location: start, length: 0))) }
                textView.insertText("", replacementRange: text.lineRange(for: NSRange(location: start, length: 0)))
            }
            await run.settle()
            if run.chance(0.7) { run.run("editor.save") }
        })
        // A closed tab's editor goes with its text view, layout and overlays (D246).
        stress.add(StressStep("editor.closeTab", weight: 2) { run in
            await run.open(run.pick(["src/short.tsx", "src/long.swift", "unicode.txt", "crlf.txt"]) ?? "src/short.tsx")
            let url = context.workspace.activeTab?.url
            // Shown on both sides of a split, the other side's editor stays.
            guard let coordinator = editor(), context.workspace.allTabs.filter({ $0.url == url }).count == 1 else { return }
            context.workspace.closeActiveTab()
            run.expectFreed(coordinator, "a closed tab's editor")
            if let textView = coordinator.textView { run.expectFreed(textView, "a closed tab's text view") }
        })
        // Switching back finds the tab's editor as it was (D249); a tab closed
        // in the background lets its kept editor go.
        final class Finding { var problem: String? }
        let switchBack = Finding()
        stress.add(StressStep("editor.switchBack", weight: 2) { run in
            await run.open("src/short.tsx")
            guard let first = editor(), let url = context.workspace.activeTab?.url else { return }
            await run.open(run.pick(["src/long.swift", "unicode.txt", "crlf.txt"]) ?? "crlf.txt")
            // A preview tab is replaced, not put in the background; one on both sides of a split has two editors.
            let tabs = context.workspace.allTabs.filter { $0.url == url }
            guard tabs.count == 1 else { return }
            if run.chance(0.5) {
                await run.open("src/short.tsx")
                if let back = editor(), back !== first { switchBack.problem = "switching back to short.tsx built its editor again" }
            } else {
                context.workspace.close(tabs[0].id)
                run.expectFreed(first, "a background tab's kept editor, the tab closed")
            }
        })
        stress.add(StressCheck("editor.switchBackKeepsTheEditor") { _ in switchBack.problem })
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
        // 14 000 lines pasted at 351 carets: the gutter's git markers diffed them
        // for 20 s (D249); undone, the fold regions on the removed lines went
        // to negative lines and sticky scroll crashed on them (D250).
        stress.add(StressStep("editor.hugePasteAtManyCarets", weight: 1, regression: true) { run in
            await run.open("src/short.tsx")
            guard let textView = editor()?.textView else { return }
            let length = textView.documentText.length
            textView.selectionRanges = (0..<351).map { NSRange(location: $0 * length / 351, length: 0) }
            let paste = (0..<40).map { "    const pasted\($0) = compute(\($0), \"a fairly long line of pasted text\");" }.joined(separator: "\n")
            textView.insertText(paste, replacementRange: NSRange(location: NSNotFound, length: 0))
            await run.settle()
            // Scrolled down, so sticky scroll pins lines, then undone.
            textView.scrollRangeToVisible(NSRange(location: textView.documentText.length / 2, length: 0))
            await run.settle()
            textView.undoManager?.undo()
            await run.settle()
            textView.selectionRanges = [NSRange(location: 0, length: 0)]
        })
        // D250: `</div>` typed at the top of a 6 000-line Swift file made the
        // rest one expression, and each chunk's highlight query followed it
        // to the end: the worker stayed busy for minutes.
        stress.add(StressStep("editor.unclosedAtTheTop", weight: 1, regression: true) { run in
            await run.open("src/long.swift")
            guard let textView = editor()?.textView else { return }
            textView.selectionRanges = [NSRange(location: 0, length: 0)]
            textView.insertText("()</div>", replacementRange: NSRange(location: NSNotFound, length: 0))
            await run.settle()
            textView.undoManager?.undo()
        })
        // D250: a tab closed and opened again in one update kept its editor,
        // and the editor its closed document: a change from outside showed,
        // typing went into the closed one.
        stress.add(StressStep("editor.closeAndReopenAtOnce", weight: 1, regression: true) { run in
            await run.open("one-line.txt")
            guard let url = context.workspace.activeTab?.url,
                  context.workspace.documents.existingDocument(for: url)?.isDirty == false else { return }
            context.workspace.closeActiveTab()
            context.workspace.reopenClosedTab()
            await run.settle()
            try? context.workspace.documents.write("no newline at the end, changed \(run.int(0...999))", to: url)
            await run.settle()
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
                    let disk = (try? String(contentsOf: coordinator.document.url, encoding: .utf8)).map { "\($0.utf16.count)" } ?? "none"
                    return "\(coordinator.document.url.lastPathComponent): the editor shows \(shown.utf16.count) characters, the document has \(coordinator.document.text.utf16.count), the file \(disk)"
                }
                let length = (shown as NSString).length
                if let range = textView.selectionRanges.first(where: { NSMaxRange($0) > length }) {
                    return "\(coordinator.document.url.lastPathComponent): a selection at \(range) past the end (\(length))"
                }
            }
            return nil
        })
    }

    /// Prose with long lines, emphasis and code, as a README or a design doc.
    private static let longMarkdown = (0..<300).map { index in
        let words = (0..<(20 + index * 7 % 90)).map { "word\($0 % 13)" }.joined(separator: " ")
        return switch index % 6 {
        case 0: "## Section \(index)\n\n\(words) with **bold \(index)** and *italics* in a long line.\n"
        case 1: "- \(words)\n- a short item with `code`\n"
        case 2: "```swift\nlet value\(index) = compute(\(index)) // \(words)\n```\n"
        case 3: "> \(words) _quoted_ and **strong**\n"
        default: "\(words) and a [link](https://example.com/\(index)) at the end.\n"
        }
    }.joined(separator: "\n")

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
        stress.addFile("docs/long.md", longMarkdown)
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
