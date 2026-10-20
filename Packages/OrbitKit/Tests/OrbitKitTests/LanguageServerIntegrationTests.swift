import Foundation
@testable import OrbitACP
@testable import OrbitAPI
@testable import OrbitLanguages
import Testing
#if canImport(Glibc)
import Glibc
#endif

/// Each supported language against its real server, the way the editor uses
/// it (D55): errors arrive at the right UTF-16 spot, follow edits, hover and
/// go to definition answer, and the process is gone after shutdown. A server
/// that isn't installed skips its test. Adding a language = a fixture folder
/// in `Fixtures/Languages` + a `LanguageCase`.
@MainActor
@Suite(.timeLimit(.minutes(5)))
struct LanguageServerIntegrationTests {
    @Test(.enabled(if: LanguageCase.swift.isAvailable))
    func swift() async throws { try await exercise(.swift) }

    /// TypeScript 7 is native: the project's `tsc --lsp`, pull diagnostics.
    @Test(.enabled(if: LanguageCase.typeScript7.isAvailable))
    func typeScript7InProject() async throws { try await exercise(.typeScript7) }

    /// TypeScript 5/6 go through typescript-language-server over tsserver.
    @Test(.enabled(if: LanguageCase.typeScript5.isAvailable))
    func typeScript5InProject() async throws { try await exercise(.typeScript5) }

    /// No TypeScript in the project: the latest one through npx.
    @Test(.enabled(if: LanguageCase.typeScriptBare.isAvailable))
    func typeScriptWithoutProjectInstall() async throws { try await exercise(.typeScriptBare) }

    /// The alert shows why a server died: its last stderr lines.
    @Test func serverDyingInHandshakeSaysWhy() async throws {
        let config = LanguageServerConfig(
            id: "broken", name: "Broken", languages: ["broken": "broken"],
            launch: [.path(binary: "sh", arguments: ["-c", "echo 'no tsserver.js here' >&2; exit 3"])]
        )
        let server = LanguageServer(config: config, root: FileManager.default.temporaryDirectory)
        #expect(await server.start(environment: Task { ProcessInfo.processInfo.environment }) == false)
        guard case .failed(let message) = server.state else {
            Issue.record("expected a failure, got \(server.state)")
            return
        }
        #expect(message.contains("no tsserver.js here"))
    }

#if canImport(CoreServices)
    /// D77: a file written straight to disk (an agent's shell) reaches a server
    /// that leaves watching to the editor, so the type it adds is found.
    @Test(.enabled(if: LanguageCase.swift.isAvailable))
    func swiftSeesFilesCreatedOnDisk() async throws {
        let root = try LanguageCase.swift.makeProject()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let server = LanguageServer(config: .swift, root: root)
        let started = await server.start(environment: Task { ProcessInfo.processInfo.environment })
        try #require(started, "Swift didn't start: \(server.state)")
        let events = try #require(FileEventStream(root: root) { server.filesChanged($0) })
        defer { withExtendedLifetime(events) {} }

        let main = root.appendingPathComponent("Sources/Demo/main.swift")
        server.sync(main, text: "print(Extra.value)\n")
        _ = try await firstError(server, main, LanguageCase.swift.timeout) { $0.message.contains("Extra") }

        try "enum Extra { static let value = 1 }\n".write(
            to: root.appendingPathComponent("Sources/Demo/Extra.swift"), atomically: true, encoding: .utf8
        )
        try await eventually(LanguageCase.swift.timeout, "the error about Extra to go") {
            server.diagnostics[main.standardizedFileURL]?.contains { $0.message.contains("Extra") } == false
        }
        server.shutdown()
    }

#endif

    /// D200: callers and callees of a function, supertypes and subtypes of a type.
    @Test(.enabled(if: LanguageCase.swift.isAvailable))
    func swiftCallAndTypeHierarchies() async throws {
        let root = try LanguageCase.swift.makeProject()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let file = root.appendingPathComponent("Sources/Demo/Shapes.swift")
        let text = """
        protocol Shape { func area() -> Double }
        struct Square: Shape {
            func area() -> Double { side() * side() }
            func side() -> Double { 2 }
        }
        func total() -> Double { Square().area() }

        """
        try text.write(to: file, atomically: true, encoding: .utf8)
        let server = LanguageServer(config: .swift, root: root)
        let started = await server.start(environment: Task { ProcessInfo.processInfo.environment })
        try #require(started, "Swift didn't start: \(server.state)")
        defer { server.shutdown() }
        server.sync(file, text: text)

        let side = try #require(Self.position(of: "side() -> Double { 2", in: text))
        var callers: [HierarchyItem] = []
        try await eventually(LanguageCase.swift.timeout, "area() among the callers of side()") {
            callers.contains { $0.name.contains("area") }
        } poll: {
            if let item = await server.prepareHierarchy(.calls, at: side, in: file).first {
                callers = await server.hierarchy(.incoming, of: item)
            }
        }
        let area = try #require(callers.first { $0.name.contains("area") })
        #expect(area.callSites.count == 2, "\(area.callSites)")
        #expect(area.callSites.allSatisfy { $0.url.path == file.standardizedFileURL.path && $0.range.start.line == 2 })
        // Going up from the caller (the item came from the server and goes back to it).
        let higher = await server.hierarchy(.incoming, of: area)
        #expect(higher.contains { $0.name.contains("total") }, "\(higher.map(\.name))")
        let callees = await server.hierarchy(.outgoing, of: area)
        #expect(callees.contains { $0.name.contains("side") }, "\(callees.map(\.name))")

        let square = try #require(Self.position(of: "Square: Shape", in: text))
        let type = try #require(await server.prepareHierarchy(.types, at: square, in: file).first)
        #expect(type.name.contains("Square"))
        let supertypes = await server.hierarchy(.incoming, of: type)
        #expect(supertypes.contains { $0.name.contains("Shape") }, "\(supertypes.map(\.name))")
    }

    /// D202: a JSX tag's name and its closing tag's edit together; selections grow by syntax.
    @Test(.enabled(if: LanguageServerConfig.config(id: "vtsls").map {
        $0.command(file: nil, root: FileManager.default.temporaryDirectory, environment: ProcessInfo.processInfo.environment, installer: .shared) != nil
    } ?? false))
    func typeScriptLinkedEditingAndSelectionRanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-linked-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try #"{ "compilerOptions": { "jsx": "preserve", "strict": true } }"#.write(to: root.appendingPathComponent("tsconfig.json"), atomically: true, encoding: .utf8)
        let file = root.appendingPathComponent("app.tsx")
        let text = "export const app = <section className=\"x\">{1 + 2}</section>;\n"
        try text.write(to: file, atomically: true, encoding: .utf8)
        let config = try #require(LanguageServerConfig.config(id: "vtsls"))
        let server = LanguageServer(config: config, root: root)
        let started = await server.start(environment: Task { await ShellEnvironment.resolve() })
        try #require(started, "vtsls didn't start: \(server.state)")
        defer { server.shutdown() }
        server.sync(file, text: text)

        let tag = try #require(Self.position(of: "section", in: text, inside: true))
        var linked: [SourceRange] = []
        try await eventually(.seconds(60), "the tag's linked ranges") { linked.count == 2 } poll: {
            linked = await server.linkedEditingRanges(at: tag, in: file) ?? []
        }
        let closing = try #require(Self.position(of: "section>;", in: text))
        #expect(linked.contains { $0.start == closing }, "\(linked)")

        // D203: `;` tidies the statement it ends.
        let script = root.appendingPathComponent("tidy.ts")
        let statement = "export const a=1;\n"
        try statement.write(to: script, atomically: true, encoding: .utf8)
        server.sync(script, text: statement)
        #expect(server.triggers.formatOnType.contains(";"), "\(server.triggers.formatOnType)")
        let edits = await server.onTypeFormatting(";", at: SourcePosition(line: 0, character: 17), in: script, tabSize: 2, insertSpaces: true) ?? []
        #expect(SourceEdit.apply(edits, to: statement) == "export const a = 1;\n", "\(edits)")

        let inner = try #require(Self.position(of: "1 + 2", in: text))
        let chains = try #require(await server.selectionRanges(at: [inner], in: file))
        let chain = try #require(chains.first)
        #expect(chain.count > 2, "\(chain)")
        // Each step holds the one before it.
        for (narrow, wide) in zip(chain, chain.dropFirst()) {
            #expect(wide.start <= narrow.start && narrow.end <= wide.end)
        }
    }

    /// D201: the server's semantic tokens arrive and land on the right names.
    @Test(.enabled(if: LanguageCase.swift.isAvailable))
    func swiftSemanticTokens() async throws {
        let root = try LanguageCase.swift.makeProject()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let file = root.appendingPathComponent("Sources/Demo/Greeter.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        let server = LanguageServer(config: .swift, root: root)
        let started = await server.start(environment: Task { ProcessInfo.processInfo.environment })
        try #require(started, "Swift didn't start: \(server.state)")
        defer { server.shutdown() }
        server.sync(file, text: text)
        var tokens: [SemanticToken] = []
        try await eventually(LanguageCase.swift.timeout, "a property token") {
            tokens.contains { $0.type == "property" }
        } poll: {
            tokens = await server.semanticTokens(in: file) ?? []
        }
        // Declarations are tree-sitter's; the server adds what a name refers to:
        // the standard library's String, the property read inside the interpolation.
        let string = try #require(Self.position(of: "String", in: text))
        #expect(tokens.contains { $0.line == string.line && $0.character == string.character && $0.modifiers.contains("defaultLibrary") }, "\(tokens)")
        let property = try #require(Self.position(of: "name)", in: text))
        #expect(tokens.contains { $0.line == property.line && $0.character == property.character && $0.type == "property" }, "\(tokens)")
    }

    /// D78: unused code comes tagged (drawn faded), deprecated code too (struck through).
    @Test(.enabled(if: LanguageCase.typeScriptBare.isAvailable))
    func typeScriptTagsUnusedAndDeprecated() async throws {
        let root = try LanguageCase.typeScriptBare.makeProject()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let server = LanguageServer(config: .typescript, root: root)
        let started = await server.start(environment: Task { ProcessInfo.processInfo.environment })
        try #require(started, "TypeScript didn't start: \(server.state)")
        let file = root.appendingPathComponent("src/tags.ts")
        let text = """
        /** @deprecated use next */
        export function old() {}
        export function run() { const unused = 1; old() }

        """
        try text.write(to: file, atomically: true, encoding: .utf8)
        server.sync(file, text: text)
        try await eventually(LanguageCase.typeScriptBare.timeout, "tagged problems") {
            let found = server.diagnostics[file.standardizedFileURL] ?? []
            return found.contains { $0.tags.contains(.unnecessary) } && found.contains { $0.tags.contains(.deprecated) }
        }
        let found = server.diagnostics[file.standardizedFileURL] ?? []
        let unused = try #require(found.first { $0.tags.contains(.unnecessary) })
        #expect(unused.range.start == Self.position(of: "unused", in: text))
        server.shutdown()
    }

    /// The schema for .orbit/settings.json (D182): an unknown key is flagged
    /// (and validation is on at all: the server checks nothing unless told to).
    @Test(.enabled(if: FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.orbit/languages/json-lsp")))
    func jsonServerChecksOrbitSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-schema-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(".orbit/settings.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = #"{ "editor": { "wordWrapp": true } }"#
        try text.write(to: file, atomically: true, encoding: .utf8)
        let config = try #require(LanguageServerConfig.all.first { $0.id == "jsonls" })
        let server = LanguageServer(config: config, root: root)
        let started = await server.start(environment: Task { ProcessInfo.processInfo.environment })
        try #require(started, "JSON didn't start: \(server.state)")
        server.sync(file, text: text)
        try await eventually(.seconds(20), "the unknown key flagged") {
            server.diagnostics[file.standardizedFileURL]?.contains { $0.message.contains("wordWrapp") } == true
        }
        server.shutdown()
    }

    @Test func missingServerSaysWhatToInstall() async {
        let config = LanguageServerConfig(
            id: "absent", name: "Absent", languages: ["absent": "absent"],
            launch: [.path(binary: "orbit-absent-server")], missingHint: "Install the absent server."
        )
        let server = LanguageServer(config: config, root: FileManager.default.temporaryDirectory)
        #expect(await server.start(environment: Task { [:] }) == false)
        #expect(server.state == .unavailable("Install the absent server."))
    }

    /// macOS's SourceKit-LSP resolves the folder's own symlink but keeps
    /// /var (not /private/var): any spelling of a file maps back under the folder.
    @Test func serverPathsMapBackUnderTheFolderAsOpened() throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("orbit-lsp-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: base) }
        let real = base.appendingPathComponent("disk/real")
        try manager.createDirectory(at: real.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data().write(to: real.appendingPathComponent("src/a.swift"))
        try manager.createSymbolicLink(at: base.appendingPathComponent("var"), withDestinationURL: base.appendingPathComponent("disk"))
        try manager.createSymbolicLink(at: real.deletingLastPathComponent().appendingPathComponent("project"), withDestinationURL: real)
        let root = base.appendingPathComponent("var/project")
        let server = LanguageServer(config: .swift, root: root)
        let expected = root.appendingPathComponent("src/a.swift").standardizedFileURL

        #expect(server.local(base.appendingPathComponent("var/real/src/a.swift")) == expected)
        #expect(server.local(real.appendingPathComponent("src/a.swift")) == expected)
        #expect(server.local(expected) == expected)
        let outside = URL(fileURLWithPath: "/usr/include/stdio.h")
        #expect(server.local(outside) == outside)
    }

    // MARK: The scenario

    private func exercise(_ language: LanguageCase) async throws {
        let root = try language.makeProject()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let server = LanguageServer(config: language.config, root: root)
        let started = await server.start(environment: Task { ProcessInfo.processInfo.environment })
        try #require(started, "\(language.name) didn't start: \(server.state)")
        let pid = try #require(server.processIdentifier)

        // Opening the file reports its error where it is (UTF-16, after an emoji and Cyrillic).
        let main = root.appendingPathComponent(language.main)
        var text = try String(contentsOf: main, encoding: .utf8)
        server.sync(main, text: text)
        let error = try await firstError(server, main, language.timeout) { _ in true }
        #expect(error.message.contains(language.errorMessage), "\(error.message)")
        #expect(error.range.start == Self.position(of: language.errorAt, in: text))

        // Hover and go to definition on the call into the other file.
        let call = try #require(Self.position(of: language.callAt, in: text, inside: true))
        let hover = await server.hover(at: call, in: main)
        #expect(hover?.markdown.contains(language.hoverContains) == true, "\(hover?.markdown ?? "no hover")")
        let definitions = await server.definition(at: call, in: main)
        let target = root.appendingPathComponent(language.definitionFile)
        let targetText = try String(contentsOf: target, encoding: .utf8)
        let expected = try #require(Self.position(of: language.definitionAt, in: targetText))
        #expect(definitions.contains { $0.url.path == target.standardizedFileURL.path && $0.range.start.line == expected.line },
                "\(definitions)")

        // Navigation (D62): uses of the method, the variable's uses in this file, the other file's outline, project search.
        // SourceKit-LSP answers from its index, which is built in the background.
        var references: [OrbitAPI.SourceLocation] = []
        // The other file's reference can land in the index after this one's.
        try await eventually(language.timeout, "references to greet()") {
            references.contains { $0.url.path == main.standardizedFileURL.path && $0.range.start.line == call.line }
                && (!language.renamesAcrossFiles
                    || references.contains { $0.url.path == target.standardizedFileURL.path && $0.range.start.line == expected.line })
        } poll: {
            references = await server.references(at: call, in: main)
        }
        let variable = try #require(Self.position(of: "greeter.", in: text))
        let highlights = await server.highlights(at: variable, in: main)
        let declared = try #require(Self.position(of: "greeter =", in: text))
        #expect(highlights.contains { $0.range.start == declared } && highlights.contains { $0.range.start == variable }, "\(highlights)")
        server.sync(target, text: targetText)
        let outline = try #require(await server.symbols(in: target))
        let type = try #require(outline.first { $0.name == "Greeter" }, "\(outline.map(\.name))")
        #expect(type.depth == 0 && type.kind.isContainer, "\(type)")
        let method = try #require(outline.first { $0.name.hasPrefix("greet") && $0.name != "Greeter" }, "\(outline.map(\.name))")
        #expect(method.depth == 1 && method.kind == .method, "\(method)")
        #expect(method.location.range.start.line == expected.line)
        server.close(target)
        if language.renamesAcrossFiles {
            var found: [LanguageSymbol] = []
            try await eventually(language.timeout, "Greeter in the project's symbols") {
                found.contains { $0.name == "Greeter" && $0.location.url.path == target.standardizedFileURL.path }
            } poll: {
                found = await server.projectSymbols(matching: "Greet")
            }
        }

        // An edit above moves the error down with it (incremental sync).
        text = "\n\n" + text
        server.sync(main, text: text)
        let moved = try await firstError(server, main, language.timeout) { $0.range.start.line == error.range.start.line + 2 }
        #expect(moved.range.start.character == error.range.start.character)

        // Fixing it clears it.
        text = text.replacingOccurrences(of: language.fix.from, with: language.fix.to)
        server.sync(main, text: text)
        try await eventually(language.timeout, "the error to go away") {
            !(server.diagnostics[main.standardizedFileURL] ?? []).contains { $0.severity == .error }
        }

        // Inlay hints for the whole file, with the settings Orbit sends.
        text += "\n" + language.inlayHint.code
        server.sync(main, text: text)
        let lineCount = text.components(separatedBy: "\n").count
        var hints: [InlayHint] = []
        try await eventually(language.timeout, "an inlay hint \"\(language.inlayHint.label)\"") {
            hints.contains { $0.label.contains(language.inlayHint.label) }
        } poll: {
            hints = await server.inlayHints(in: SourceRange(start: .init(line: 0, character: 0), end: .init(line: lineCount, character: 0)), url: main)
        }
        let hinted = try #require(hints.first { $0.label.contains(language.inlayHint.label) })
        #expect(hinted.position == Self.position(of: language.inlayHint.at, in: text), "\(hints)")

        // Completion after a dot, filtered as the editor does; a superseded request is cancelled harmlessly.
        #expect(server.triggers.completion.contains("."))
        text += "\n" + language.memberAccess
        server.sync(main, text: text)
        let end = try #require(Self.position(of: language.memberAccess, in: text)).advanced(by: language.memberAccess.utf16.count)
        let superseded = Task { await server.completions(at: end, in: main, trigger: .invoked) }
        superseded.cancel()
        _ = await superseded.value
        let list = try #require(await server.completions(at: end, in: main, trigger: .invoked))
        let typed = FuzzyPattern("gre")
        let best = list.items.filter { typed.score($0.filterText) != nil }.max { typed.score($0.filterText)! < typed.score($1.filterText)! }
        let greet = try #require(best, "\(list.items.prefix(20).map(\.label))")
        #expect(greet.filterText.hasPrefix("greet"))
        #expect(greet.kind == .method)
        let inserted = greet.isSnippet ? Snippet(greet.insertText).text : greet.insertText
        #expect(inserted.hasPrefix("greet"))
        let resolved = await server.resolve(greet)
        #expect(resolved.detail?.contains("String") == true || resolved.documentation?.contains("String") == true
                || resolved.label.contains("String") || resolved.detail?.contains("string") == true, "\(resolved)")

        // Signature help inside a call, on the first parameter (SourceKit-LSP before Swift 6.3 has none).
        if language.requiresSignatureHelp || !server.triggers.signatureHelp.isEmpty {
            #expect(server.triggers.signatureHelp.contains("("))
            text += "\n" + language.call
            server.sync(main, text: text)
            let inCall = try #require(Self.position(of: language.call, in: text)).advanced(by: language.call.utf16.count)
            let help = try #require(await server.signatureHelp(at: inCall, in: main, trigger: "(", isRetrigger: false))
            let signature = help.signatures[help.activeSignature]
            let parameter = try #require(signature.parameters.first)
            #expect((signature.label as NSString).substring(with: parameter).contains("name"), "\(signature)")
            #expect((signature.activeParameter ?? help.activeParameter) == 0)
            // The unfinished call would break what follows.
            text = text.replacingOccurrences(of: "\n" + language.call, with: "")
            server.sync(main, text: text)
        }

        // A quick fix, applied like the editor does.
        text += "\n" + language.typo.line
        server.sync(main, text: text)
        let typoAt = try #require(Self.position(of: language.typo.line, in: text))
        var typoRange: SourceRange?
        try await eventually(language.timeout, "a problem about \(language.typo.problem)") {
            typoRange = server.diagnostics[main.standardizedFileURL]?.first {
                $0.range.start.line == typoAt.line && $0.message.localizedCaseInsensitiveContains(language.typo.problem)
            }?.range
            return typoRange != nil
        }
        let actions = await server.codeActions(for: try #require(typoRange), in: main)
        let fix = try #require(actions.first { $0.title.localizedCaseInsensitiveContains(language.typo.fixMentions) }, "\(actions.map(\.title))")
        // TypeScript's fixes run a command that sends the edit back (`workspace/applyEdit`).
        var applyToMain: (WorkspaceEdit) -> Bool = { _ in false }
        applyToMain = { edit in
            guard let edits = edit.files[main.standardizedFileURL] else { return false }
            text = SourceEdit.apply(edits, to: text)
            return true
        }
        server.onApplyEdit = { applyToMain($0) }
        let applied = await server.perform(fix) { applyToMain($0) }
        #expect(applied)
        #expect(text.contains(language.typo.fixed), "\(text)")
        server.sync(main, text: text)

        // Formatting tidies a badly spaced line.
        if language.formats {
            text += "\n" + language.messy.line
            server.sync(main, text: text)
            let edits = try #require(await server.formatting(main, tabSize: 4, insertSpaces: true))
            text = SourceEdit.apply(edits, to: text)
            #expect(text.contains(language.messy.tidy), "\(text)")
            server.sync(main, text: text)
        }

        // Renaming the method changes its declaration in the other file and the call here.
        let callSite = try #require(Self.position(of: language.callAt, in: text, inside: true))
        let renameTarget = try #require(await server.prepareRename(at: callSite, in: main))
        #expect(renameTarget.placeholder == "greet")
        let renamed = try await server.rename(at: callSite, in: main, to: "salute")
        #expect(renamed.files[main.standardizedFileURL]?.isEmpty == false, "\(renamed)")
        if language.renamesAcrossFiles {
            let declaration = try #require(renamed.files[target.standardizedFileURL], "\(renamed.files.keys)")
            #expect(SourceEdit.apply(declaration, to: targetText).contains("salute"))
        }

        // Nothing keeps running after shutdown, including what npx started.
        let processes = [pid] + Self.descendants(of: pid)
        server.shutdown()
        try await eventually(.seconds(10), "the server's processes \(processes) to exit") {
            processes.allSatisfy { kill($0, 0) != 0 }
        }
    }

    private func firstError(
        _ server: LanguageServer, _ url: URL, _ timeout: Duration, where matches: @escaping (Diagnostic) -> Bool
    ) async throws -> Diagnostic {
        var found: Diagnostic?
        try await eventually(timeout, "an error in \(url.lastPathComponent); state \(server.state)") {
            found = server.diagnostics[url.standardizedFileURL]?.first { $0.severity == .error && matches($0) }
            return found != nil
        }
        return try #require(found)
    }

    private func eventually(
        _ timeout: Duration, _ what: String, _ condition: () -> Bool, poll: () async -> Void = {}
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        await poll()
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for \(what)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(50))
            await poll()
        }
    }

    static func descendants(of pid: Int32) -> [Int32] {
        guard let output = try? Self.run("/usr/bin/pgrep", ["-P", String(pid)]) else { return [] }
        let children = output.split(whereSeparator: \.isNewline).compactMap { Int32($0) }
        return children + children.flatMap { descendants(of: $0) }
    }

    private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Where `needle` starts in `text`, as a server counts it; `inside` points into it.
    static func position(of needle: String, in text: String, inside: Bool = false) -> SourcePosition? {
        let string = text as NSString
        let range = string.range(of: needle)
        guard range.location != NSNotFound else { return nil }
        return SourcePosition(offset: range.location + (inside ? 1 : 0), in: SourcePosition.lineStarts(of: string))
    }
}

/// A language, its fixture project and what its server must say about it.
extension SourcePosition {
    func advanced(by characters: Int) -> SourcePosition {
        SourcePosition(line: line, character: character + characters)
    }
}

struct LanguageCase: Sendable {
    var name: String
    var fixture: String
    var config: LanguageServerConfig
    /// Installed into the fixture's node_modules (cached between runs).
    var npmPackages: [String] = []
    var main: String
    var errorMessage: String
    var errorAt: String
    var callAt: String
    var hoverContains: String
    var definitionFile: String
    var definitionAt: String
    var fix: (from: String, to: String)
    /// Appended once the file is clean; `label` should show up just before `at`.
    var inlayHint: (code: String, label: String, at: String)
    /// Typed at the end of the file: completion and signature help there.
    var memberAccess = "greeter.gre"
    var call: String
    var requiresSignatureHelp = true
    var typo: (line: String, problem: String, fixMentions: String, fixed: String)
    var formats = true
    var messy: (line: String, tidy: String)
    /// SourceKit-LSP needs an index of the package for that.
    var renamesAcrossFiles = true
    /// Cold servers index the project first (SourceKit-LSP builds the package).
    var timeout: Duration = .seconds(60)

    static let swift = LanguageCase(
        name: "Swift", fixture: "swift", config: .swift,
        main: "Sources/Demo/main.swift",
        errorMessage: "convert value of type 'String' to specified type 'Int'",
        errorAt: "message\n",
        callAt: "greet()",
        hoverContains: "func greet() -> String",
        definitionFile: "Sources/Demo/Greeter.swift", definitionAt: "greet()",
        fix: ("let count: Int", "let count: String"),
        inlayHint: ("let inferred = 1 + 1", "Int", " = 1 + 1"),
        call: "_ = Greeter(",
        requiresSignatureHelp: false,
        typo: ("func later() -> Int { var later = 1; return later }", "never mutated", "let", "let later = 1"),
        messy: ("let   spaced=1", "let spaced = 1"),
        timeout: .seconds(180)
    )

    private static let typeScript = LanguageCase(
        name: "TypeScript", fixture: "typescript", config: .typescript,
        main: "src/main.ts",
        errorMessage: "Type 'string' is not assignable to type 'number'",
        errorAt: "count: number",
        callAt: "greet()",
        hoverContains: "greet(): string",
        definitionFile: "src/greeter.ts", definitionAt: "greet()",
        fix: ("count: number", "count: string"),
        inlayHint: ("function twice(times: number) { return times * 2 }\ntwice(21);", "times", "21);"),
        call: "new Greeter(",
        typo: ("shout(\"hi\");", "shout", "import", "shout } from"),
        messy: ("const   spaced=1", "const spaced = 1")
    )

    static let typeScript7 = with(typeScript) { $0.name = "TypeScript 7"; $0.npmPackages = ["typescript@7"] }
    static let typeScript5 = with(typeScript) {
        $0.name = "TypeScript 5"
        $0.npmPackages = ["typescript@5", "typescript-language-server@5"]
    }
    /// The project has no TypeScript: Orbit's typescript-language-server (or one on PATH) with its own.
    static let typeScriptBare = with(typeScript) { $0.name = "TypeScript (no project install)" }

    private static func with(_ base: LanguageCase, _ change: (inout LanguageCase) -> Void) -> LanguageCase {
        var copy = base
        change(&copy)
        return copy
    }

    var isAvailable: Bool {
        let environment = ProcessInfo.processInfo.environment
        if !npmPackages.isEmpty { return Shell.which("npm", in: environment) != nil }
        let root = Self.fixtures.appendingPathComponent(fixture)
        return config.command(file: nil, root: root, environment: environment, installer: .shared) != nil
    }

    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Languages")

    /// A fresh copy of the fixture, opened through a symlink like macOS's
    /// /var → /private/var: servers answer with the real path.
    func makeProject() throws -> URL {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("orbit-lsp-\(UUID().uuidString)")
        let real = base.appendingPathComponent("real")
        try manager.createDirectory(at: base, withIntermediateDirectories: true)
        try manager.copyItem(at: Self.fixtures.appendingPathComponent(fixture), to: real)
        if !npmPackages.isEmpty {
            try manager.createSymbolicLink(at: real.appendingPathComponent("node_modules"), withDestinationURL: try Self.installedPackages(npmPackages))
        }
        let link = base.appendingPathComponent("project")
        try manager.createSymbolicLink(at: link, withDestinationURL: real)
        return link
    }

    /// One install per package set, reused by later runs.
    static func installedPackages(_ npmPackages: [String]) throws -> URL {
        let key = npmPackages.joined(separator: "+").replacingOccurrences(of: "/", with: "_")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-lsp-npm/\(key)")
        let modules = directory.appendingPathComponent("node_modules")
        if FileManager.default.fileExists(atPath: modules.appendingPathComponent(".installed").path) { return modules }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let environment = ProcessInfo.processInfo.environment
        let npm = try #require(Shell.which("npm", in: environment))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: npm)
        process.arguments = ["install", "--no-save", "--no-audit", "--no-fund", "--prefix", directory.path] + npmPackages
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "npm install \(npmPackages) failed")
        _ = FileManager.default.createFile(atPath: modules.appendingPathComponent(".installed").path, contents: nil)
        return modules
    }
}
