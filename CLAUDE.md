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
- Don't commit unless asked. Exception — cloud sessions (claude.ai/code): the
  author can't see changes otherwise, so commit and push straight to `master`
  (no feature branches or PRs), authored as
  `Mikhail Mogilnikov <mikhail.mogilnikov02@gmail.com>`, without
  `Co-Authored-By` / `Claude-Session` trailers. The cloud container is Linux:
  nothing here builds, so say what wasn't verified and expect screenshots back.

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
  Sources/OrbitReview     plugin: ChangeTracker + Checkpoints (shadow git)
  Sources/OrbitSearch     plugin: file index, Open Quickly ⌘P, Find in Project
  Sources/OrbitTerminal   plugin: SwiftTerm terminals in the bottom panel
  Sources/OrbitGit        plugin: Source Control panel (GitRepository runs /usr/bin/git)
  Sources/OrbitAgents     plugin: providers, AgentSession, transcript & chat UI
  Sources/OrbitKit        BuiltinPlugins list
  Tests/OrbitKitTests     Swift Testing
docs/                     product & architecture docs (extensions.md: authoring guide)
examples/extensions/      sample extensions (theme, icon theme)
```

## Apple references & tooling

- Xcode MCP (`xcode`, local config → `xcrun mcpbridge`; needs Xcode open with
  `Orbit.xcodeproj`): use `DocumentationSearch` before relying on memory for
  recent SwiftUI/AppKit APIs, `RenderPreview` to look at a view in isolation,
  `XcodeRefreshCodeIssuesInFile` for diagnostics. Never use its project-mutating
  tools (`XcodeMV/RM/MakeDir/NewTarget`, `UpdateTargetBuildSetting`,
  `AddInfoPlist`, `AddEntitlement`…): the project is generated — edit `project.yml`.
- Apple's agent guides ship inside Xcode — read the relevant one before touching
  Liquid Glass, toolbars, styled text or concurrency:
  `/Applications/Xcode.app/Contents/PlugIns/IDEIntelligenceChat.framework/Versions/A/Resources/AdditionalDocumentation/`
  (`SwiftUI-Implementing-Liquid-Glass-Design.md`, `AppKit-Implementing-Liquid-Glass-Design.md`,
  `SwiftUI-New-Toolbar-Features.md`, `SwiftUI-Styled-Text-Editing.md`, `Swift-Concurrency-Updates.md`).
- Skill `swift-concurrency` (`.claude/skills`, vendored from
  AvdLee/Swift-Concurrency-Agent-Skill). Settings it asks about: Swift 6
  language mode everywhere (package tools 6.2, app `SWIFT_VERSION` 6.0), so
  complete strict checking; no default actor isolation, no upcoming-feature
  flags, no Approachable Concurrency.

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
- Colors that should follow the color theme come from `Theme` (SwiftUI) or
  `Extensions.shared.colorTheme(dark:)` + `Extensions.themeDidChange` (AppKit);
  chrome is never painted: the theme background lies under the window and the
  glass panels pick it up (D41); use `.nativeSurface(_:)`, not a plain
  `.background`, for fills in the middle of the window. File icons: `FileIconView`, not `FileIcon.systemImage`.
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
- SwiftUI ignores `navigationSplitViewColumnWidth` for the sidebar and resets
  the split view item to no max on each drag; `SidebarWidthLimit` re-applies
  the limits. Without a max the detail column (it runs under the sidebar, so
  its min width grows with it) outgrew the screen and AppKit crashed.
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

- The window has no toolbar (D42): tabs and window buttons are the content's
  top row (`WindowTopBar`). Window changes must survive restoring a full-screen
  window (launch Orbit a few times while it was full screen):
  `.toolbar(removing: .title)`, `.sharedBackgroundVisibility(.hidden)` and a
  themed fill on the status bar each crashed it in an endless constraint pass. Touch `NSWindow` properties
  only async and on a real change (`WindowBackground` in OrbitUI/Theme.swift).

- Full screen on the built-in ProMotion display: the window alone on screen
  scrolls at ~60 fps; `FullScreenCompositingGuard` (a 1-pt child window)
  keeps it composited (D47). Don't remove it as dead weight.

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
