#if DEBUG
import Foundation
import OrbitACP
import OrbitAPI

/// The agents' part of a stress run (D244, D245). A run never starts a real
/// agent (a CLI with the user's account): while one runs the store lists only
/// a pretend ACP agent, a script in the run's project, whose prompts pick a
/// scenario: a reply, edits through Orbit and through its own shell, a
/// permission, a slow stream to stop or queue behind, a crash, an error.
@MainActor
enum AgentsStress {
    static let provider = AgentProvider(
        id: "stress-agent", name: "Stress Agent", systemImage: "ladybug",
        command: AgentCommand(executable: "/usr/bin/python3", arguments: ["-I", "tools/fake-acp-agent.py"])
    )

    static func register(_ context: PluginContext, store: AgentStore) {
        let stress = context.stress
        stress.addFile("tools/fake-acp-agent.py", script)

        /// A ready session: the selected one, or a new one when it isn't (one a
        /// crash scenario failed), now and then a new one anyway.
        func session(_ run: StressContext) async -> AgentSession? {
            if store.selected.map({ ![.ready, .dormant, .starting].contains($0.status) }) ?? true || run.chance(0.15) {
                run.run(run.chance(0.2) ? "agents.newIsolated" : "agents.new.\(provider.id)")
            }
            guard let session = store.selected else { return nil }
            if session.status == .dormant { await session.start() }
            for _ in 0..<80 where session.status != .ready { try? await Task.sleep(for: .milliseconds(100)) }
            return session.status == .ready ? session : nil
        }
        func turn(_ session: AgentSession, _ scenario: String) async {
            session.draft = "stress:\(scenario) — and some Ünïcödé 👩‍👩‍👧"
            session.submit()
            for _ in 0..<80 where session.status == .working {
                // A permission is answered as a person would: either way.
                if let request = session.firstPendingPermission, let option = request.option(allow: Bool.random()) { request.choose(option) }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        stress.add(StressStep("agents.turn", weight: 4) { run in
            guard let session = await session(run) else { return }
            await turn(session, run.pick(["reply", "edit", "read", "permission", "big", "error"]) ?? "reply")
        })
        stress.add(StressStep("agents.stop", weight: 1) { run in
            guard let session = await session(run) else { return }
            session.draft = "stress:slow"
            session.submit()
            for _ in 0..<30 where session.status != .working { try? await Task.sleep(for: .milliseconds(50)) }
            try? await Task.sleep(for: .milliseconds(run.int(100...800)))
            // Queued behind the turn, then the turn stopped.
            session.draft = "stress:reply queued"
            session.submit()
            run.run("agents.stop")
        })
        stress.add(StressStep("agents.crash", weight: 1) { run in
            guard let session = await session(run) else { return }
            await turn(session, "crash")
        })
        stress.add(StressStep("agents.closeWhileWorking", weight: 1) { run in
            guard let session = await session(run) else { return }
            session.draft = "stress:slow"
            session.submit()
            try? await Task.sleep(for: .milliseconds(run.int(50...500)))
            store.close(session)
        })
        // Notes on lines, as the inline review writes them, then sent to the agent.
        stress.add(StressStep("agents.reviewComments", weight: 1) { run in
            guard let session = await session(run) else { return }
            for _ in 0..<run.int(1...3) {
                let start = run.int(0...40)
                store.reviewComments.save(ReviewComment(url: run.file("src/short.tsx"), lines: start...(start + run.int(0...3)),
                                                        code: "export const item = 1", text: run.pick(["Rename this", "Why? 👩‍👩‍👧", ""]) ?? "Why?"))
            }
            run.run("agents.sendReviewComments")
            for _ in 0..<50 where session.status == .working { try? await Task.sleep(for: .milliseconds(100)) }
        })
        // The transcript re-laid out under a long reply: text sizes and the panel's width change (D245).
        stress.add(StressStep("agents.transcriptRelayout", weight: 1) { run in
            guard let session = await session(run) else { return }
            context.ui.revealInspectorPanel("agents")
            await turn(session, run.pick(["big", "reply", "edit"]) ?? "big")
            for _ in 0..<run.int(3...8) {
                Preferences.shared.interfaceTextSize = Double(run.int(10...15))
                await run.settle()
            }
        })
        stress.add(StressCheck("agents.sessionsSettle") { _ in
            // A turn that never ends (an answer Orbit dropped) keeps a session working forever.
            let stuck = store.sessions.filter { $0.status == .working && Date().timeIntervalSince($0.updatedAt) > 60 }
            return stuck.isEmpty ? nil : "\(stuck.count) agent session(s) working for over a minute"
        })
        stress.exempt(StressCoverage.source(.agents), because: "installs agents from the network registry")
    }

    private static let script = #"""
#!/usr/bin/env python3
# A pretend ACP agent for Orbit's stress run (D245): newline-delimited JSON-RPC
# on stdio. A prompt's "stress:<scenario>" picks what it does; any other text
# gets a reply. It never touches the network or a real model.
import json, os, random, sys, time

pending = []          # messages read while waiting for an answer
next_id = 1000
cancelled = set()

def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()

def read():
    if pending:
        return pending.pop(0)
    line = sys.stdin.readline()
    if not line:
        sys.exit(0)
    return json.loads(line)

def notify(method, params):
    send({"jsonrpc": "2.0", "method": method, "params": params})

def ask(method, params):
    """A request to Orbit (fs, permission): waits for its answer, keeping what else comes."""
    global next_id
    next_id += 1
    send({"jsonrpc": "2.0", "id": next_id, "method": method, "params": params})
    while True:
        message = read()
        if message.get("id") == next_id and "method" not in message:
            return message
        if message.get("method") == "session/cancel":
            cancelled.add(message["params"]["sessionId"])
        else:
            pending.append(message)

def update(session, kind, **fields):
    notify("session/update", {"sessionId": session, "update": {"sessionUpdate": kind, **fields}})

def say(session, text, chunks=8, delay=0.0):
    size = max(1, len(text) // chunks)
    for start in range(0, len(text), size):
        if session in cancelled:
            return
        update(session, "agent_message_chunk", content={"type": "text", "text": text[start:start + size]})
        if delay:
            time.sleep(delay)

REPLY = """Here's what I found. **Bold**, `code`, a [link](https://example.invalid), and Ünïcödé 👩‍👩‍👧 שלום.

```swift
func pretend(_ x: Int) -> Int { x * 2 }
```

| File | Change |
| --- | --- |
| src/short.tsx | renamed a value |
"""

def edit(session, cwd, through_orbit):
    path = os.path.join(cwd, random.choice(["src/short.tsx", "tabs.go", "one-line.txt", "unicode.txt"]))
    call = f"edit-{random.randint(0, 10**9)}"
    update(session, "tool_call", toolCallId=call, title=f"Edit {os.path.basename(path)}", kind="edit", status="in_progress",
           locations=[{"path": path}])
    try:
        old = open(path, encoding="utf-8").read()
    except OSError:
        old = ""
    lines = old.split("\n")
    lines.insert(min(3, len(lines)), "// added by the pretend agent")
    new = "\n".join(lines)
    if through_orbit:
        ask("fs/write_text_file", {"sessionId": session, "path": path, "content": new})
    else:
        # As agents do through their own shell: Orbit finds it in the turn's changes.
        with open(path, "w", encoding="utf-8") as file:
            file.write(new)
    update(session, "tool_call_update", toolCallId=call, status="completed",
           content=[{"type": "diff", "path": path, "oldText": old, "newText": new}])

def prompt(request):
    params = request["params"]
    session = params["sessionId"]
    cancelled.discard(session)
    text = " ".join(block.get("text", "") for block in params.get("prompt", []) if block.get("type") == "text")
    scenario = text.split("stress:", 1)[1].split()[0] if "stress:" in text else "reply"
    cwd = sessions.get(session, os.getcwd())
    update(session, "agent_thought_chunk", content={"type": "text", "text": "Thinking about it…"})
    update(session, "plan", entries=[{"content": "Look", "priority": "high", "status": "completed"},
                                     {"content": "Change", "priority": "medium", "status": "in_progress"}])
    stop = "end_turn"
    if scenario == "edit":
        edit(session, cwd, through_orbit=True)
        edit(session, cwd, through_orbit=False)
        say(session, "I changed two files.")
    elif scenario == "read":
        answer = ask("fs/read_text_file", {"sessionId": session, "path": os.path.join(cwd, "src/short.tsx"), "line": 1, "limit": 5})
        say(session, "The file starts with:\n\n```\n" + answer.get("result", {}).get("content", "") + "\n```")
    elif scenario == "permission":
        call = f"run-{random.randint(0, 10**9)}"
        update(session, "tool_call", toolCallId=call, title="Run `rm -rf build`", kind="execute", status="pending")
        answer = ask("session/request_permission", {"sessionId": session, "toolCall": {"toolCallId": call, "title": "Run `rm -rf build`"},
            "options": [{"optionId": "allow", "name": "Allow", "kind": "allow_once"}, {"optionId": "always", "name": "Always", "kind": "allow_always"},
                        {"optionId": "reject", "name": "Reject", "kind": "reject_once"}]})
        outcome = answer.get("result", {}).get("outcome", {})
        update(session, "tool_call_update", toolCallId=call, status="completed" if outcome.get("optionId") in ("allow", "always") else "failed",
               rawOutput={"output": "removed build/"})
        say(session, f"Permission: {outcome}")
    elif scenario == "slow":
        say(session, "A long answer that streams slowly. " * 40, chunks=80, delay=0.05)
    elif scenario == "big":
        say(session, (REPLY + "\n") * 400, chunks=200)
    elif scenario == "crash":
        say(session, "About to fall over…")
        os._exit(3)
    elif scenario == "error":
        send({"jsonrpc": "2.0", "id": request["id"], "error": {"code": -32603, "message": "The pretend agent failed on purpose"}})
        return
    else:
        say(session, REPLY)
    if session in cancelled:
        stop = "cancelled"
    update(session, "usage_update", used=random.randint(1000, 90000), size=200000)
    send({"jsonrpc": "2.0", "id": request["id"], "result": {"stopReason": stop}})

sessions = {}
while True:
    message = read()
    method, identifier = message.get("method"), message.get("id")
    if method is None:
        continue
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": identifier, "result": {"protocolVersion": 1, "agentCapabilities": {"loadSession": False},
                                                             "authMethods": [], "agentInfo": {"name": "stress", "version": "1"}}})
    elif method == "session/new":
        session = f"stress-{random.randint(0, 10**9)}"
        sessions[session] = message["params"].get("cwd", os.getcwd())
        send({"jsonrpc": "2.0", "id": identifier, "result": {"sessionId": session}})
        update(session, "available_commands_update", availableCommands=[{"name": "review", "description": "Review the changes"}])
    elif method == "session/prompt":
        prompt(message)
    elif method == "session/cancel":
        cancelled.add(message["params"]["sessionId"])
    elif identifier is not None:
        send({"jsonrpc": "2.0", "id": identifier, "error": {"code": -32601, "message": f"{method} isn't something the pretend agent does"}})
"""#
}
#endif
