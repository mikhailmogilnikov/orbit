import AppKit
import OrbitAPI
@testable import OrbitEditor
@testable import OrbitGit
@testable import OrbitLanguages
@testable import OrbitTerminal
import Testing

@Suite struct SmallFeatureTests {
    @Test func problemsBecomeAPromptWithTheirCode() {
        let root = URL(fileURLWithPath: "/project")
        let file = root.appendingPathComponent("src/a.ts")
        let at = SourcePosition(line: 4, character: 2)
        let problem = Diagnostic(range: SourceRange(start: at, end: at), severity: .error, message: "Cannot find name 'x'.", source: "ts")
        let text = (1...10).map { "line \($0)" }.joined(separator: "\n")
        let prompt = ProblemPrompt.text(for: [FileProblems(url: file, diagnostics: [problem])], root: root) { _ in text }
        #expect(prompt.hasPrefix("Fix this problem:"))
        #expect(prompt.contains("`src/a.ts:5:3` error (ts): Cannot find name 'x'."))
        #expect(prompt.contains("5> line 5"))
        #expect(prompt.contains("2  line 2") && prompt.contains("8  line 8") && !prompt.contains("9  line 9"))
    }

    @Test func terminalPathsOpenAtTheirLine() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("links-\(UUID().uuidString)").standardizedFileURL
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "x".write(to: root.appendingPathComponent("src/a.ts"), atomically: true, encoding: .utf8)
        let file = root.appendingPathComponent("src/a.ts")
        #expect(TerminalLink.file("src/a.ts:12:5", in: [root])! == (file, 11, 4))
        #expect(TerminalLink.file("./src/a.ts:3", in: [root])! == (file, 2, nil))
        #expect(TerminalLink.file("src/a.ts(7,2)", in: [root])! == (file, 6, 1))
        #expect(TerminalLink.file(file.absoluteString, in: [])! == (file, nil, nil))
        #expect(TerminalLink.file("src/missing.ts:1", in: [root]) == nil)
        #expect(TerminalLink.file("https://example.com/a.ts", in: [root]) == nil)
    }

    @Test func colorsAreFoundAndWrittenInTheirOwnNotation() throws {
        let text = """
        color: #FF5500;
        background: rgba(0, 128, 255, 0.5);
        border-color: rgb(10 20 30 / 50%);
        fill: hsl(120, 100%, 50%);
        Fixes #123 and see &#123;
        """
        let colors = ColorLiterals.find(in: text, prose: true)
        let hex = try #require(colors[0])
        #expect(hex.notation == .hex(digits: 6, uppercase: true))
        #expect((text as NSString).substring(with: hex.range) == "#FF5500")
        #expect(hex.written(NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)) == "#00FF00")
        #expect(hex.written(NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 0.5)) == "#00FF0080")
        let rgba = try #require(colors[1])
        #expect(abs(rgba.blue - 1) < 0.001 && abs(rgba.alpha - 0.5) < 0.001)
        #expect(rgba.written(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)) == "rgba(255, 0, 0, 1)")
        let spaced = try #require(colors[2])
        #expect(spaced.written(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.25)) == "rgb(255 0 0 / 0.25)")
        let hsl = try #require(colors[3])
        #expect(abs(hsl.green - 1) < 0.001 && hsl.red < 0.001)
        #expect(hsl.written(NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)) == "hsl(240, 100%, 50%)")
        #expect(colors[4] == nil)
        #expect(ColorLiterals.find(in: "let issue = \"#123\"", prose: false)[0] != nil)
    }

    @Test func remotesBecomeWebLinks() {
        #expect(RemoteLink.web(remote: "git@github.com:me/app.git") == URL(string: "https://github.com/me/app"))
        #expect(RemoteLink.web(remote: "ssh://git@gitlab.com:22/team/app") == URL(string: "https://gitlab.com/team/app"))
        #expect(RemoteLink.web(remote: "https://github.com/me/app.git\n") == URL(string: "https://github.com/me/app"))
        let github = URL(string: "https://github.com/me/app")!
        #expect(RemoteLink.file(in: github, commit: "abc", path: "src/My File.ts", lines: 3...5)?.absoluteString
                == "https://github.com/me/app/blob/abc/src/My%20File.ts#L3-L5")
        #expect(RemoteLink.file(in: URL(string: "https://gitlab.com/t/a")!, commit: "abc", path: "a.ts", lines: 7...7)?.absoluteString
                == "https://gitlab.com/t/a/-/blob/abc/a.ts#L7")
        #expect(RemoteLink.file(in: URL(string: "https://bitbucket.org/t/a")!, commit: "abc", path: "a.ts", lines: 1...2)?.absoluteString
                == "https://bitbucket.org/t/a/src/abc/a.ts#lines-1:2")
    }

    @Test func linesSortDedupeAndCasesConvert() {
        let text = "b\na10\na2\nb\n" as NSString
        let sorted = TextTransforms.lines(text, selections: [NSRange(location: 0, length: 0)], .sortAscending)
        #expect(sorted?.replacement == "a2\na10\nb\nb\n")
        let unique = TextTransforms.lines(text, selections: [NSRange(location: 0, length: 0)], .removeDuplicates)
        #expect(unique?.replacement == "b\na10\na2\n")
        // Only the selected lines.
        let some = TextTransforms.lines(text, selections: [NSRange(location: 0, length: 6)], .sortAscending)
        #expect(some?.range == NSRange(location: 0, length: 5) && some?.replacement == "a10\nb")

        #expect(TextTransforms.words("HTTPServer_url-path2") == ["HTTP", "Server", "url", "path2"])
        #expect(TextTransforms.convert("userName", to: .snake) == "user_name")
        #expect(TextTransforms.convert("user_name", to: .camel) == "userName")
        #expect(TextTransforms.convert("user-name", to: .pascal) == "UserName")
        #expect(TextTransforms.convert("userName", to: .constant) == "USER_NAME")
        #expect(TextTransforms.convert(" myValue,", to: .kebab) == " my-value,")
        let caret = TextTransforms.changeCase("let fooBar = 1" as NSString, selections: [NSRange(location: 6, length: 0)], to: .snake)
        #expect(caret?.replacement == "foo_bar" && caret?.range == NSRange(location: 4, length: 6))
    }

    @Test @MainActor func pastedImageFilesLandInAssets() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("paste-\(UUID().uuidString)").standardizedFileURL
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("shot \(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data([0x89, 0x50]).write(to: outside)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("orbit-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([outside as NSURL])
        let document = folder.appendingPathComponent("README.md")
        let text = try #require(PastedImages.paste(from: pasteboard, into: document))
        #expect(text == "![](<assets/\(outside.lastPathComponent)>)")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("assets/\(outside.lastPathComponent)").path))
        #expect(PastedImages.paste(from: pasteboard, into: folder.appendingPathComponent("a.swift")) == nil)
    }

    @Test func terminalEditingKeysSendWhatShellsExpect() {
        typealias Keys = TerminalKeys
        #expect(Keys.action(keyCode: Keys.left, modifiers: .option) == .send([0x1B, 0x62]))
        #expect(Keys.action(keyCode: Keys.right, modifiers: [.option, .function, .numericPad]) == .send([0x1B, 0x66]))
        #expect(Keys.action(keyCode: Keys.left, modifiers: .command) == .send([0x01]))
        #expect(Keys.action(keyCode: Keys.delete, modifiers: .option) == .send([0x1B, 0x7F]))
        #expect(Keys.action(keyCode: Keys.delete, modifiers: .command) == .send([0x15]))
        #expect(Keys.action(keyCode: Keys.enter, modifiers: .shift) == .send([0x1B, 0x0D]))
        #expect(Keys.action(keyCode: Keys.k, modifiers: .command) == .clear)
        // Left alone: plain keys, ⌥ letters (they type characters), shortcuts with more modifiers.
        #expect(Keys.action(keyCode: Keys.left, modifiers: []) == nil)
        #expect(Keys.action(keyCode: 0, modifiers: .option) == nil)
        #expect(Keys.action(keyCode: Keys.left, modifiers: [.command, .shift]) == nil)
    }
}
