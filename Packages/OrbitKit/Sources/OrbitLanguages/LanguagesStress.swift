#if DEBUG
import Foundation
import OrbitAPI

/// The language servers' part of a stress run (D244, D245). Installing a real
/// server downloads from Mason, so it stays out; `*.fake` files get a pretend
/// server instead (a script in the run's project, set in its
/// `.orbit/settings.json`) whose answers are valid but awkward: diagnostics
/// past the end and piled up, huge hovers, definitions in missing files,
/// slow answers, and now and then it dies.
@MainActor
enum LanguagesStress {
    static func register(_ context: PluginContext) {
        let stress = context.stress
        stress.addFile("tools/fake-lsp.py", script)
        stress.addFile("src/sample.fake", (0..<120).map { "value\($0) = call(\($0)) // Ünïcödé \($0 % 7 == 0 ? "👩‍👩‍👧" : "")\n" }.joined())
        stress.addFile("src/other.fake", "other = 1\n")
        stress.addFile("src/many.fake", (0..<40).map { "line\($0)\n" }.joined())
        stress.prepare { root in
            let settings: [String: Any] = ["languageServers": ["fake": ["command": "/usr/bin/python3",
                                                                        "arguments": ["-I", root.appendingPathComponent("tools/fake-lsp.py").path]]]]
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try FileManager.default.createDirectory(at: root.appendingPathComponent(".orbit"), withIntermediateDirectories: true)
            try data.write(to: root.appendingPathComponent(".orbit/settings.json"))
        }

        stress.add(StressStep("languages.fakeServer", weight: 3) { run in
            let path = run.pick(["src/sample.fake", "src/other.fake"]) ?? "src/sample.fake"
            await run.open(path)
            if let document = context.workspace.documents.existingDocument(for: run.file(path)) {
                document.text += run.pick(["x = 1\n", "call(", "\n\n", "👩‍👩‍👧 = ü\n", String(repeating: "y", count: 2000)]) ?? "x"
            }
            try? await Task.sleep(for: .milliseconds(run.int(50...600)))
            for command in run.some(["editor.goToDefinition", "languages.fileSymbols", "editor.format", "languages.findReferences",
                                     "languages.peekReferences", "editor.codeActions", "languages.problems"], count: run.int(1...3)) {
                run.run(command)
                await run.settle()
            }
            if run.chance(0.1) { run.run("languages.restart") }
            run.note("\(context.services.resolve(LanguageIntelligence.self)?.diagnostics(for: run.file(path)).count ?? -1) diagnostics")
        })
        // D245: a List of problems torn down mid-update (the bottom panel switching
        // away from Problems) crashed in SwiftUI's own OutlineListCoordinator.
        stress.add(StressStep("languages.problemsTeardown", weight: 1, regression: true) { run in
            await run.open("src/many.fake")
            // References and a call hierarchy too: their panels are lists as well.
            for command in ["languages.findReferences", "languages.callHierarchy"] {
                run.run(command)
                await run.settle()
            }
            for _ in 0..<run.int(5...12) {
                context.ui.revealBottomPanel(run.pick(["problems", "references", "hierarchy"]) ?? "problems")
                try? await Task.sleep(for: .milliseconds(run.int(0...80)))
                // The columns around the editor sliding while the list goes.
                if run.chance(0.6) { run.run(run.pick(["shell.toggleAgents", "shell.toggleSidebar"]) ?? "shell.toggleAgents") }
                try? await Task.sleep(for: .milliseconds(run.int(0...150)))
                if run.chance(0.5) { context.ui.revealBottomPanel("terminal") } else { context.ui.isBottomPanelVisible.toggle() }
                if run.chance(0.3), let document = context.workspace.documents.existingDocument(for: run.file("src/many.fake")) {
                    document.text += "x\n"
                }
                try? await Task.sleep(for: .milliseconds(run.int(0...80)))
            }
        })
        stress.exempt(StressCoverage.source(.languageServers), because: "installs servers from the network (Mason)")
    }

    private static let script = #"""
#!/usr/bin/env python3
# A pretend language server for Orbit's stress run (D245), for *.fake files:
# LSP over stdio with Content-Length headers. Its answers are valid but
# awkward on purpose: diagnostics past the end of the file and on top of each
# other, hundreds at once, huge hovers, a definition in a file that isn't
# there, slow answers, and now and then it dies.
import json, os, random, sys, time

documents = {}

def send(message):
    body = json.dumps(message).encode("utf-8")
    sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
    sys.stdout.buffer.flush()

def read():
    length = 0
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            sys.exit(0)
        if line in (b"\r\n", b"\n"):
            break
        if line.lower().startswith(b"content-length:"):
            length = int(line.split(b":")[1])
    return json.loads(sys.stdin.buffer.read(length))

def notify(method, params):
    send({"jsonrpc": "2.0", "method": method, "params": params})

def answer(message, result):
    send({"jsonrpc": "2.0", "id": message["id"], "result": result})

def position(line, character):
    return {"line": line, "character": character}

def diagnostics(uri):
    lines = documents.get(uri, "").split("\n")
    found = []
    for _ in range(400 if "many" in uri else random.choice([0, 1, 5, 40, 400])):
        line = random.randint(0, len(lines) + 5)        # some past the last line
        start = random.randint(0, 200)                  # some past the line's end
        found.append({"range": {"start": position(line, start), "end": position(line + random.randint(0, 3), start + random.randint(0, 50))},
                      "severity": random.randint(1, 4), "source": "fake", "code": random.randint(1, 9999),
                      "message": random.choice(["Unused value", "Ünïcödé 👩‍👩‍👧 problem", "A very long message " * 30, "x"])})
    notify("textDocument/publishDiagnostics", {"uri": uri, "diagnostics": found})

def chaos():
    if random.random() < 0.15:
        time.sleep(random.uniform(0.2, 2.5))
    if random.random() < 0.01:
        os._exit(7)

while True:
    message = read()
    method = message.get("method")
    params = message.get("params") or {}
    if method == "initialize":
        answer(message, {"capabilities": {
            "textDocumentSync": 1, "hoverProvider": True, "definitionProvider": True, "referencesProvider": True,
            "documentSymbolProvider": True, "documentFormattingProvider": True, "renameProvider": True,
            "completionProvider": {"triggerCharacters": [".", "("]}, "codeActionProvider": True, "callHierarchyProvider": True},
            "serverInfo": {"name": "fake-lsp", "version": "1"}})
    elif method == "initialized":
        send({"jsonrpc": "2.0", "id": "progress-1", "method": "window/workDoneProgress/create", "params": {"token": "fake"}})
        notify("$/progress", {"token": "fake", "value": {"kind": "begin", "title": "Indexing pretend files"}})
        notify("$/progress", {"token": "fake", "value": {"kind": "end"}})
    elif method in ("textDocument/didOpen", "textDocument/didChange"):
        document = params["textDocument"]
        text = document.get("text") if method == "textDocument/didOpen" else params["contentChanges"][-1].get("text", "")
        documents[document["uri"]] = text
        chaos()
        diagnostics(document["uri"])
    elif method == "textDocument/didClose":
        documents.pop(params["textDocument"]["uri"], None)
    elif method == "textDocument/hover":
        chaos()
        answer(message, {"contents": {"kind": "markdown", "value": "**fake** `hover` Ünïcödé\n\n```swift\nfunc f() {}\n```\n" + "More. " * random.choice([1, 20, 3000])}})
    elif method == "textDocument/completion":
        chaos()
        answer(message, {"isIncomplete": True, "items": [{"label": f"item{i} {'👩‍👩‍👧' if i % 7 == 0 else ''}", "kind": i % 25 + 1,
            "detail": "fake", "insertText": f"item{i}"} for i in range(random.choice([0, 3, 500]))]})
    elif method in ("textDocument/definition", "textDocument/references"):
        chaos()
        uri = params["textDocument"]["uri"]
        here = {"uri": uri, "range": {"start": position(0, 0), "end": position(0, 3)}}
        missing = {"uri": uri.rsplit("/", 1)[0] + "/missing.fake", "range": {"start": position(9, 0), "end": position(9, 3)}}
        far = {"uri": uri, "range": {"start": position(99999, 0), "end": position(99999, 3)}}
        answer(message, [here, missing, far] if "many" in uri else random.choice([[here], [missing], [far], [here, missing, far], []]))
    elif method in ("textDocument/prepareCallHierarchy", "callHierarchy/incomingCalls", "callHierarchy/outgoingCalls"):
        chaos()
        uri = (params.get("textDocument") or params.get("item") or {}).get("uri", "file:///missing.fake")
        def item(i):
            return {"name": f"caller{i}", "kind": 12, "uri": uri, "range": {"start": position(i, 0), "end": position(i, 5)},
                    "selectionRange": {"start": position(i, 0), "end": position(i, 5)}}
        if method == "textDocument/prepareCallHierarchy":
            answer(message, [item(0)])
        else:
            key = "from" if method.endswith("incomingCalls") else "to"
            answer(message, [{key: item(i), "fromRanges": [{"start": position(i, 0), "end": position(i, 2)}]} for i in range(60 if "many" in uri else random.choice([0, 3, 60]))])
    elif method == "textDocument/documentSymbol":
        chaos()
        def symbol(name, line, children):
            return {"name": name, "kind": 12, "range": {"start": position(line, 0), "end": position(line + 1, 0)},
                    "selectionRange": {"start": position(line, 0), "end": position(line, 3)}, "children": children}
        answer(message, [symbol(f"outer{i}", i * 3, [symbol(f"inner{i}", i * 3 + 1, [])]) for i in range(random.choice([0, 5, 200]))])
    elif method == "textDocument/formatting":
        chaos()
        text = documents.get(params["textDocument"]["uri"], "")
        lines = text.split("\n")
        answer(message, [{"range": {"start": position(0, 0), "end": position(len(lines), 0)}, "newText": text.strip() + "\n"}])
    elif method == "shutdown":
        answer(message, None)
    elif method == "exit":
        sys.exit(0)
    elif "id" in message and method is not None:
        answer(message, None)
"""#
}
#endif
