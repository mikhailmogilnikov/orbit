# Orbit

Native macOS IDE for AI coding agents (Claude Code, Codex, any ACP agent) —
"Cursor in IDE mode", but SwiftUI/AppKit: light, fast, Apple-native, and
plugin-first. Built primarily for the author's own use.

Read before significant work:
- `docs/product.md` — principles and UX decisions (what to build and why)
- `docs/architecture.md` — modules, plugin model, ACP, review pipeline
- `docs/decisions.md` — decision log; **add an entry** for every new product/tech decision
- `docs/roadmap.md` — done / next / known gaps; keep it current

## Working with the author

- Speaks Russian; reply in Russian. Code, comments, commits and docs are in English.
- Doesn't know Swift well and delegates technical decisions: pick the best
  solution yourself, explain it briefly in plain terms. Ask only about product/UX.
- Cares a lot about looks and native feel — verify UI visually, don't guess.
- Don't commit unless asked.

## Commands

```bash
make build   # xcodegen + xcodebuild (Debug) → .build/xcode/Build/Products/Debug/Orbit.app
make run     # build, kill running Orbit, open the app
make test    # swift test in Packages/OrbitKit
make clean
cd Packages/OrbitKit && swift build   # fast compile check of all modules
```

`Orbit.xcodeproj` is generated — edit `project.yml`, never the project.
The last opened folder is stored in `defaults read dev.orbit.app orbit.lastWorkspaceRoot`.

## Layout

```
App/                      shell (window, tabs, inspector, palette, menus, settings)
Packages/OrbitKit/
  Sources/OrbitAPI        kernel: OrbitPlugin, registries, Workspace, DocumentStore, LineDiff, ChangeTracking
  Sources/OrbitUI         Theme tokens, DiffView, MarkdownText, components
  Sources/OrbitACP        JSON-RPC + ACP client + ShellEnvironment
  Sources/OrbitExplorer   plugin: file tree
  Sources/OrbitEditor     plugin: STTextView editor + InlineDiff.swift
  Sources/OrbitReview     plugin: ChangeTracker + Checkpoints (shadow git) + Changes panel
  Sources/OrbitSearch     plugin: file index, Open Quickly ⌘P, Find in Project
  Sources/OrbitTerminal   plugin: SwiftTerm terminals in the bottom panel
  Sources/OrbitGit        plugin: Source Control panel (GitRepository runs /usr/bin/git)
  Sources/OrbitAgents     plugin: providers, AgentSession, transcript & chat UI
  Sources/OrbitKit        BuiltinPlugins list
  Tests/OrbitKitTests     Swift Testing
docs/                     product & architecture docs
```

## Rules of the codebase

- **Everything is a plugin.** New features go into a plugin using only the
  public `OrbitAPI` (panels, editor providers, status items, commands,
  services). Plugins never import each other; share functionality through a
  protocol in `OrbitAPI/Services.swift` registered in `ServiceRegistry`.
- Commands registered via `commands.register` automatically get menu items
  (by category: File, Agents, Review; others → "Plugins" menu) and palette entries.
- Swift 6 strict concurrency. UI/model classes are `@MainActor @Observable`;
  their `Identifiable.id` must be `nonisolated`. `OrbitACP` is nonisolated
  (state confined to a serial queue).
- Use `Theme` tokens from OrbitUI for colors/fonts/corners; Liquid Glass button
  styles (`.glass`, `.glassProminent`) for actions.
- Agent changes are reviewed **inline in the editor** — do not reintroduce a
  separate review mode/tab (explicit product decision D7).
- Keep comment density low; explain *why*, not *what*.

## Gotchas

- Agents may edit via shell; never rely only on ACP diffs — change tracking
  goes through `ChangeTracking.beginAgentTurn/refreshAgentChanges/endAgentTurn`.
- The editor's text view is `OrbitTextView` (clamps accessibility selections;
  stock STTextView crashes on out-of-range ones).
- Split-view columns (sidebar, editor area, inspector) must not propagate min
  sizes into the split view (constraint-loop crash on tab switch); keep
  `minWidth/minHeight: 0` on `SidebarHost`, `EditorArea`, `InspectorHost`.
- Syntax highlighting is our `SyntaxHighlightPlugin`, not upstream `NeonPlugin`:
  TextKit 2 throws on rendering attributes for empty ranges (see D14).
- Since macOS 14 NSViews don't clip to bounds by default: a custom `draw(_:)`
  that fills `dirtyRect` can paint over siblings (the line-number ruler hid
  all editor text). Set `clipsToBounds = true` / fill `dirtyRect ∩ bounds`.
- Line numbers are our `LineNumberRuler` (NSRulerView), not STTextView's
  gutter (`showsLineNumbers` stays off, see D24).
- Inline diff gaps are paragraph styles in the text storage; anything that
  replaces `textView.text` must call `inlineDiff.invalidate()`.
- The standalone `claude` CLI on this machine isn't logged in (author uses the
  Claude desktop app); Claude Code sessions fail until `claude` → `/login`.
  Codex is logged in. Don't use the host session's credentials for testing.
- The command sandbox blocks keychain access and launching GUI apps; running
  agents or `open Orbit.app` needs the sandbox disabled.
- Launching Orbit from inside a Claude Code session leaks its env vars into
  Orbit; `ShellEnvironment` strips them, but prefer testing on a scratch
  folder (e.g. a demo project in the scratchpad), not this repo.

- SwiftTerm needs Xcode's Metal Toolchain (`xcodebuild -downloadComponent
  MetalToolchain`, installed here) and its build-tool plugin is trusted via
  `-skipPackagePluginValidation` in the Makefile.

## Testing the UI

- Build, launch, then inspect with computer-use (`dev.orbit.app`) in
  background mode: `app_screenshot`, `app_click` by element index.
- Debug builds have **Plugins → Debug: Simulate Agent Edit**: fakes an agent
  edit of the active file (modify, delete, insert, append) — use it to check
  inline diffs without spending agent requests.
- Background clicks into the STTextView itself don't work (AX); typing into
  the editor can't be automated in background mode.
- Crash reports: `~/Library/Logs/DiagnosticReports/Orbit-*.ips`
  (look at `lastExceptionBacktrace` for ObjC exceptions).
