# Orbit

Native macOS IDE for AI coding agents (Claude Code, Codex, any ACP agent) —
"Cursor in IDE mode", but SwiftUI/AppKit: light, fast, Apple-native, and
plugin-first.

Read before significant work:
- `docs/product.md` — principles and UX decisions (what to build and why)
- `docs/architecture.md` — modules, plugin model, ACP, review pipeline
- `docs/decisions.md` — decision log: read its index, then the entries your work
  touches; **add an entry** for every new product/tech decision (and a note on
  any older entry it changes)
- `docs/roadmap.md` — done / next / known limitations; keep it current
- `docs/manual-checks.md` — what still needs a look by hand on a Mac: add
  what you couldn't verify, remove what got checked

## Working here

- Code, comments, commits and docs are in English.
- Looks and native feel matter a lot — verify UI visually, don't guess.
- Don't commit unless asked.
- Linux (cloud containers): the app doesn't build, so say what wasn't
  verified. The language-server client does: `scripts/linux-swift.sh`, then
  `make test-languages` (and `make test-language-installs` for server
  install/config changes) before pushing LSP changes.
- The maintainer's cloud sessions (claude.ai/code) commit and push straight
  to `master` (no feature branches or PRs), authored as
  `Mikhail Mogilnikov <mikhail.mogilnikov02@gmail.com>`, without
  `Co-Authored-By` / `Claude-Session` trailers.
- Personal, machine-specific notes go in `CLAUDE.local.md` (not in git).

## Commands

```bash
make build   # xcodegen + xcodebuild (Debug, optimized: D165) → .build/xcode/Build/Products/Debug/Orbit.app
make run     # build, kill running Orbit, open the app
make test    # swift test in Packages/OrbitKit
make test-languages   # LSP client against real servers (D55); runs on Linux too
make test-language-installs   # every server installed from Mason and run (D57); slow once
make import-lspconfig   # regenerate the imported server table from nvim-lspconfig (D65)
make import-grammars    # regenerate the grammar table from Zed and its extension catalog (D71)
make acknowledgements   # regenerate the licenses in About Orbit after a dependency changes (D207)
make release-setup   # once: Sparkle's update key (D129)
make release VERSION=0.2.0   # Release build + appcast in .build/release/0.2.0
make release-publish VERSION=0.2.0   # GitHub release with both (asks nothing: confirm first; docs/releasing.md)
make clean
cd Packages/OrbitKit && swift build   # fast compile check of all modules
pnpm --dir site dev    # the website (Astro, D216) at localhost:4321
site/bench/run.sh && node site/bench/summarize.mjs <output>   # re-measure the site's numbers
```

`Orbit.xcodeproj` is generated — edit `project.yml`, never the project.
The folders open at quit (one per window, D101) are in `defaults read dev.orbit.app orbit.openFolders`.

## Layout

```
App/                      shell (window, tabs, inspector, palette, menus, settings)
Packages/OrbitKit/
  Sources/OrbitAPI        kernel: OrbitPlugin, registries, Workspace, DocumentStore, LineDiff, ChangeTracking, GrammarCatalog
  Sources/OrbitUI         Theme tokens, DiffView, MarkdownText, components
  Sources/OrbitACP        JSON-RPC + ACP client + ShellEnvironment
  Sources/OrbitExplorer   plugin: file tree
  Sources/OrbitEditor     plugin: STTextView editor + InlineDiff.swift
  Sources/OrbitReview     plugin: ChangeTracker + Checkpoints (shadow git)
  Sources/OrbitSearch     plugin: file index, Open Quickly ⌘P, Find in Project
  Sources/OrbitTerminal   plugin: SwiftTerm terminals in the bottom panel
  Sources/OrbitGit        plugin: Source Control panel (GitRepository runs /usr/bin/git)
  Sources/OrbitAgents     plugin: providers, AgentSession, transcript & chat UI
  Sources/OrbitLanguages  plugin: LSP client, server table, Mason installer (Settings → Languages)
  Sources/OrbitPreview    plugin: image / PDF viewer, Markdown preview (WKWebView)
  Sources/OrbitKit        BuiltinPlugins list
  Tests/OrbitKitTests     Swift Testing
docs/                     product & architecture docs (extensions.md: authoring guide)
site/                     the website (Astro); reads docs/ and the Swift sources at build time
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

- One `PluginHost` per window (D101): plugin state goes in the plugin
  instance, never in a static/singleton shared by windows. A closed window
  must free everything, and so must a plugin turned off (D194): an observer
  that re-arms itself stops once `context.isActive` is false (it covers
  `workspace.isClosed`) and captures its models weakly (the workspace or
  `Extensions.shared` keep the observation until their next change; weak
  `context.lifetime` stops it), `deactivate()` stops processes and timers
  (`WindowLifetimeTests`, `PluginTogglingTests`). A plugin needing another
  says so in `requires`; a feature split out of a plugin can be a second
  plugin in the same module, sharing its model through a service.
- **Everything is a plugin.** New features go into a plugin using only the
  public `OrbitAPI` (panels, editor providers, status items, commands,
  services). Plugins never import each other; share functionality through a
  protocol in `OrbitAPI/Services.swift` registered in `ServiceRegistry`.
- Commands registered via `commands.register` automatically get menu items
  and palette entries. A built-in command's place (menu, section, submenu) is
  in `App/MenuLayout.swift` (D176): add new ones there; unlisted commands go
  to the end of the menu their category maps to, unknown categories → "Plugins". `isEnabled` is only re-checked when something
  observable it reads changes: don't gate on unobservable state (it sticks;
  `ActiveEditor` and the inline diff aren't observable, D210). Two commands
  on one key: only the first menu's runs (`ShortcutConflictTests`).
- Swift 6 strict concurrency. UI/model classes are `@MainActor @Observable`;
  their `Identifiable.id` must be `nonisolated`. `OrbitACP` is nonisolated
  (state confined to a serial queue).
- Use `Theme` tokens from OrbitUI for colors, corners and hover/selected
  fills, `Badge` / `DisclosureChevron` (D157), and `.orbitFont(.body)`
  (`TypeScale`, D117) for UI text — no literal point sizes, radii or opacities; Liquid Glass button
  styles (`.glass`, `.glassProminent`) for actions. Buttons are pills (D229):
  a new AppKit-hosted SwiftUI root gets `.pillControls()`.
- Colors that should follow the color theme come from `Theme` (SwiftUI) or
  `Extensions.shared.colorTheme(dark:)` + `Extensions.themeDidChange` (AppKit);
  chrome is never painted: the theme background lies under the window and the
  glass panels pick it up (D41); use `.nativeSurface(_:)`, not a plain
  `.background`, for fills in the middle of the window. File icons: `FileIconView`, not `FileIcon.systemImage`.
- Agent changes are reviewed **inline in the editor** — do not reintroduce a
  separate review mode/tab (explicit product decision D7).
- Icon-only buttons get a `.help` tooltip; when a command does the same,
  use `commands.help(id)` ("Find References (⇧⌘R)") so it carries the
  shortcut, and link a panel to the command showing it with `.command(id)` (D67).
- Alerts and open/save panels: `runSheetModal()`, not `runModal()` (D162).
- A new Settings option gets a `SettingsItem` in its pane's `items` and
  `.settingsItem(id)` on its row, so search finds it (D177).
- Something new the user can install (a kind of extension) is an
  `ExtensionSource` registered with `ui.addExtensionSource`, listed in
  Settings → Extensions (D192), not a catalog page of its own.
- A new `.orbit/settings.json` key gets a line in `SettingsSchema` (D182),
  or the JSON server flags it as not allowed.
- The UI is English, not localized (D211). Dates, numbers and sizes go
  through system formatters (`.formatted`): the app gets English words with
  the Mac's region formats, but `swift test` gets the Mac's language too.
- Keep comment density low; explain *why*, not *what*.

## Gotchas

- Agents may edit via shell; never rely only on ACP diffs — change tracking
  goes through `ChangeTracking.beginAgentTurn/refreshAgentChanges/endAgentTurn`.
- The editor's text view is `OrbitTextView` (clamps accessibility selections;
  stock STTextView crashes on out-of-range ones).
- Split-view columns (sidebar, editor area, inspector) must not propagate min
  sizes into the split view (constraint-loop crash on tab switch); keep
  `minWidth/minHeight: 0` on `SidebarHost`, `EditorArea`, `InspectorHost`.
  `EditorArea` clears the sidebar with its own padding: the inherited inset
  is cancelled (`SidebarInsetCanceller`, D104) or a narrow window crashes.
- SwiftUI ignores `navigationSplitViewColumnWidth` for the sidebar and resets
  the split view item to no max on each drag; `SidebarWidthLimit` re-applies
  the limits. Without a max the detail column (it runs under the sidebar, so
  its min width grows with it) outgrew the screen and AppKit crashed.
- Syntax highlighting is our `SyntaxHighlightPlugin` with Zed's languages
  (`Grammars.json`, D71); no grammar is built in. Never add one by hand:
  bump the pins and rerun `make import-grammars`. Highlighting is not upstream `NeonPlugin`:
  TextKit 2 throws on rendering attributes for empty ranges (see D14).
- Never feed a view's measured size back into its own content (e.g.
  `onGeometryChange` on a scroll view setting its content's `minWidth`):
  in a tight window the layout cycles and AppKit throws (D103). Measure
  from a `GeometryReader` outside instead.
- Since macOS 14 NSViews don't clip to bounds by default: a custom `draw(_:)`
  that fills `dirtyRect` can paint over siblings (the line-number ruler hid
  all editor text). Set `clipsToBounds = true` / fill `dirtyRect ∩ bounds`.
- `NSIntersectionRange`/`NSUnionRange` take unsigned values on macOS (not
  on Linux): a negative location silently gives an empty result. Clamp by hand.
- Line numbers are our `LineNumberRuler` (NSRulerView), not STTextView's
  gutter (`showsLineNumbers` stays off, see D24).
- Inline diff gaps are paragraph styles in the text storage; anything that
  replaces `textView.text` must call `inlineDiff.invalidate()`.
- Views over the text view go through `OverlaySet` (D164): removing and
  re-adding them on each viewport layout re-dirties the layout and the
  editor spins at 100% CPU.
- Don't use the host session's agent credentials for testing.
- Claude Code's command sandbox blocks keychain access and launching GUI apps;
  running agents or `open Orbit.app` needs the sandbox disabled.
- Launching Orbit from inside a Claude Code session leaks its env vars into
  Orbit; `ShellEnvironment` strips them, but prefer testing on a scratch
  folder (e.g. a temporary demo project), not this repo.

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
  MetalToolchain`) and its build-tool plugin is trusted via
  `-skipPackagePluginValidation` in the Makefile.

## Testing the UI

- Build, launch, then inspect the running app (bundle id `dev.orbit.app`),
  e.g. with a computer-use tool in background mode.
- Debug builds have **Plugins → Debug: Simulate Agent Edit**: fakes an agent
  edit of the active file (modify, delete, insert, append) — use it to check
  inline diffs without spending agent requests.
- Background clicks into the STTextView itself don't work (AX); typing into
  the editor can't be automated in background mode.
- Crash reports: `~/Library/Logs/DiagnosticReports/Orbit-*.ips`
  (look at `lastExceptionBacktrace` for ObjC exceptions).
