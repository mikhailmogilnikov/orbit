# Orbit — Architecture

Core idea: **the kernel knows almost nothing; everything else is a plugin.**

## Stack

| Concern | Choice |
|---|---|
| Platform | macOS 26+, SwiftUI shell, AppKit where performance matters |
| Language | Swift 6 (strict concurrency), UI types are `@MainActor` |
| Build | XcodeGen (`project.yml`) + local SwiftPM package `Packages/OrbitKit` |
| Agents | ACP — Agent Client Protocol, newline-delimited JSON-RPC over stdio |
| Editor | STTextView (TextKit 2) + tree-sitter highlighting via STTextView-Plugin-Neon |
| Diffs | `CollectionDifference` (Myers) over lines → change blocks |
| Change tracking | Shadow git repo per workspace (checkpoints) |

## Modules (`Packages/OrbitKit/Sources`)

```
OrbitAPI       Kernel: plugin protocol, registries (UI, commands, services),
               Workspace (tabs, root), DocumentStore, LineDiff, ChangeTracking protocol
OrbitUI        Shared UI: Theme tokens, DiffView, MarkdownText, small components
OrbitACP       JSON-RPC transport, ACP client, login-shell environment (nonisolated)
OrbitExplorer  Plugin: file tree, Open Folder
OrbitEditor    Plugin: STTextView editor, inline diff rendering, editor commands
OrbitReview    Plugin: ChangeTracker (baselines, keep/revert), checkpoints, Changes panel
OrbitSearch    Plugin: project file index, Open Quickly (⌘P), Find in Project panel
OrbitTerminal  Plugin: SwiftTerm terminals in the bottom panel
OrbitGit       Plugin: Source Control panel (status, stage, commit, branches, pull/push)
OrbitAgents    Plugin: agent providers, sessions, transcript, permissions, fs bridge
OrbitKit       Umbrella: BuiltinPlugins list, re-exports OrbitAPI/OrbitUI
App/           Shell: window, sidebar/inspector hosts, tab bar, status bar,
               command palette, menus generated from commands, settings
```

Dependency rule: plugins depend on `OrbitAPI` (+ `OrbitUI`), **never on each
other**. Cross-plugin features go through service protocols declared in
`OrbitAPI` (e.g. `ChangeTracking`, implemented by Review, used by Editor and
Agents; `AgentCompletion`, implemented by Agents, used by Git for commit
messages; `AgentTerminalHosting`, implemented by Terminal, used by Agents to run
commands).

## Plugin model

A plugin is a class conforming to `OrbitPlugin` with a static `manifest`. In
`activate(_ context:)` it contributes:

- `ui.addSidebarPanel` / `ui.addInspectorPanel` — navigator / inspector panels
- `ui.addEditorProvider` — renders tabs it accepts (highest priority wins)
- `ui.addBottomPanel` — panels under the editor (one shown at a time, the
  shell owns visibility and the resizable edge); `revealBottomPanel` /
  `toggleBottomPanel`
- `ui.presentQuickPick` / `toggleQuickPick` — a floating searchable list (the
  shell renders it; the command palette and ⌘P are both quick picks);
  `FuzzyMatch` gives pickers shared scoring and match highlighting
- `ui.addStatusItem` — status bar items (leading/trailing); `isVisible` says when an item has something to show — the bar is hidden while none do
- `commands.register` — commands with optional shortcuts; they appear in menus
  (by category) and the command palette automatically
- `services.register` — typed services for other plugins
- `settings` — per-plugin namespaced UserDefaults

`PluginHost` activates enabled plugins at launch; enable/disable takes effect
on restart. Built-ins use exactly the public API — no private hooks.

### Plugin roadmap
1. Built-in Swift plugins (now).
2. Code-free agent plugins: JSON manifests in `~/.orbit/agents/*.json` (done).
3. Extensions (D37): data-only packages in `~/.orbit/extensions/<id>/`
   (themes, icon themes, languages + language servers, agents), installed
   from a public GitHub registry. `Extensions` (OrbitAPI) loads built-ins
   from its bundle and user folders (FSEvents live reload) and parses themes
   (Zed formats, D38); `Theme` / `FileIconView` (OrbitUI) expose them to
   views. Authoring guide: `docs/extensions.md`.
4. Code in extensions: TypeScript via JavaScriptCore (in macOS, no Node, small memory).
5. Heavy plugins out-of-process over JSON-RPC (LSP-style).

## Agents (ACP)

- `JSONRPCConnection` spawns the agent via `/usr/bin/env <executable>` with the
  login-shell environment, reads/writes newline-delimited JSON on a serial queue.
- `AgentSession` funnels every notification *and* request into one ordered
  `AsyncStream` consumed on the main actor, so chunks, tool calls and
  permission requests are applied in arrival order.
- Client capabilities: `fs.readTextFile` / `fs.writeTextFile` (served from open
  buffers, so agents see unsaved edits); `terminal` when the Terminal plugin is
  enabled (commands as PTYs in background terminal tabs); and
  `_meta.terminal_output(_delta)`, through which Claude Code / Codex stream the
  commands they run themselves into display-only tabs. Either way the tool
  card shows plain-text output (`AgentTerminal`, `TerminalTextCapture`).
- Built-in providers (npx, unpinned so they auto-update):
  `@agentclientprotocol/claude-agent-acp`, `@agentclientprotocol/codex-acp`.
- `ShellEnvironment` resolves PATH etc. from `$SHELL -ilc env` once at startup
  and strips variables inherited from a host agent session (`CLAUDECODE`,
  `CLAUDE_CODE_*`, and host `ANTHROPIC_*` creds when launched from Claude Code).

## Change review pipeline

1. Before each agent turn: `beginAgentTurn()` snapshots the workspace into a
   shadow git repo (`~/Library/Application Support/Orbit/checkpoints/<hash>`,
   `git add -A` + `write-tree`). The project's own `.git` is never touched;
   project `.gitignore` is honoured plus built-in excludes.
2. On every mutating tool completion and at turn end: diff snapshot ↔ working
   tree; each changed file not already tracked gets its snapshot contents as
   **baseline**. `fs/write_text_file` also records baselines directly.
3. Hunks = `LineDiff.hunks(baseline, current)`. **Keep** writes the block into
   the baseline; **Undo** writes the baseline block into the file. When they
   converge, the file leaves the Changes list.

Why shadow git: agents (notably Codex) edit via shell (`python`, `sed`), which
produces no ACP diff and no `fs/write_text_file` call.

## Inline diff rendering (`OrbitEditor/InlineDiff.swift`)

- Removed lines: a gap is opened above the change by setting
  `paragraphSpacingBefore` on that paragraph's style in the text storage
  (or `paragraphSpacing` on the last paragraph for removals at EOF). A
  `RemovedLinesView` draws the ghost lines in that gap. The file text never
  contains them; undo history is untouched.
- Added lines: `ChangeBackgroundView` (green, full width, left bar) placed
  *below* STTextView's content view so text draws on top.
- Per-block Keep/Undo: a small `NSHostingView` hanging off the block's
  bottom-right corner.
- Overlays are rebuilt on STTextView's `onDidLayoutViewport` (via a tiny
  `STPlugin`) and only for blocks near the viewport.
- Before re-applying, previously decorated paragraphs are found via
  `enumerateAttribute(.paragraphStyle)` and reset to the default style.

## Known constraints / gotchas

- STTextView asserts on out-of-range accessibility selections → we use
  `OrbitTextView` (subclass) that clamps them.
- SwiftUI inspector content must not push min sizes into the split view
  (caused an AppKit constraint-loop crash) → `InspectorHost` pins
  `minWidth/minHeight: 0`.
- `@Observable` `@MainActor` classes conforming to `Identifiable` need a
  `nonisolated` `id`.
- No App Sandbox, no hardened runtime (agents spawn arbitrary CLIs); direct
  distribution later (notarization + Sparkle).
