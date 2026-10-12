# Decision log

Short ADR-style records. Newest at the bottom. Each: context → decision → why.

### D1. Native SwiftUI/AppKit, macOS 26+
Goal is minimal memory/battery and an Apple-native feel. Targeting macOS 26
gives Liquid Glass and modern SwiftUI APIs for free. The author uses the app
personally, so no need to support older macOS.

### D2. Everything is a plugin
The author wants a "harness"-like system where anything is pluggable. Built-in
features are plugins on the same public API; plugins talk only via service
protocols in `OrbitAPI`.

### D3. ACP for all agents
One protocol for Claude Code, Codex, Gemini, etc. New agent = JSON manifest.
Rejected: parsing terminal output (fragile); per-vendor SDKs (N integrations).

### D4. STTextView + tree-sitter for the editor
Native TextKit 2, gutter, plugin system, maintained. Rejected for now: custom
Core Text/Metal renderer (too much work up front), CodeEditSourceEditor.
Revisit if large-file performance becomes a problem.

### D5. Agents write to disk immediately; Orbit reviews after
Cursor model: edits land, user keeps/undoes per block. Simpler than
intercepting writes and works with agents that edit via shell.

### D6. Shadow-git checkpoints for change tracking
Discovered by probing Codex: it edits files with shell commands, producing no
structured diff. Snapshotting the workspace before each turn into a private git
repo catches every change. Project `.git` untouched. (Same idea as Cline.)

### D7. Inline diffs in the editor — no separate review tab
The first version had a review tab; the author explicitly asked for
Cursor-style diffs *in the code* without switching modes. The review tab was
removed. Implementation via paragraph-spacing gaps + overlay views (see
architecture.md).

### D8. Line-based diff with `CollectionDifference`
No dependency, good enough; change blocks are the unit of keep/undo.

### D9. No App Sandbox, direct distribution
Agents must spawn arbitrary CLIs (npx, node, codex). App Store is out.

### D10. Login-shell environment, filtered
GUI apps lack the user's PATH. Resolve once via `$SHELL -ilc env`. Strip host
agent session variables so agents don't think they're nested inside another
Claude Code session or use its credentials.

### D11. Built-in agent adapters via unpinned npx
`npx -y @agentclientprotocol/{claude-agent,codex}-acp` — auto-updates, no
bundling. Cost: ~1–2 s startup. Revisit (cache/bundle) if startup annoys.

### D12. Per-block keyboard shortcuts
Keep ⌥⌘↩, Undo ⌥⌘⌫, next/prev ⌥⌘↓/↑, all ⇧⌘↩ / ⇧⌘⌫. ⌘N/⌘Y (Cursor's) were
avoided because they clash with standard macOS shortcuts.

### D13. App icon as an Icon Composer `.icon`
`App/AppIcon.icon` is compiled by Xcode directly (`ASSETCATALOG_COMPILER_APPICON_NAME`),
so the system renders light/dark/tinted Liquid Glass variants. Edit it in
Icon Composer; no asset catalog or PNG exports.

### D14. Own syntax-highlight plugin instead of `NeonPlugin`
`OrbitEditor/SyntaxHighlighting.swift` is a trimmed copy of STTextView-Plugin-Neon's
plugin (still using its `Theme` and tree-sitter grammars). Reason: tree-sitter
emits zero-length tokens (markdown block markers, MISSING `"` nodes), and
TextKit 2 throws on `addRenderingAttribute` for an empty range — opening any
`.md` file or typing a `"` crashed the app. Our copy skips empty/stale ranges
and keeps the editor's font size (the upstream plugin reset it to 13pt).

### D15. One brand mark, shared by the icon and the UI
The glyph lives in `App/AppIcon.icon/Assets/orbit-mark.svg`; a copy with the
viewBox cropped to the glyph is `OrbitUI/Resources/OrbitMark.svg`, exposed as
the `OrbitMark` view (template image, takes the foreground style). The welcome
screen shows the real app icon (`NSApp.applicationIconImage`); smaller in-app
spots (agents empty state) use `OrbitMark`. No SF Symbol stand-ins for the logo.
If the icon glyph changes, update both SVGs.


### D16. Status bar only when there's something to say
The bottom bar used to be always on, mostly showing just the file's language.
The language item was dropped (the extension already says it), and
`StatusItem.isVisible` lets each plugin report whether it has content; the
shell shows the bar only while at least one item is visible (agents working /
waiting for approval, changes to review).

### D17. Keep the system window toolbar as is
Tried moving editor tabs into the toolbar (Safari/Zed style) and hiding its
items when no file is open. Toolbar items can't stretch, so it needed a
hand-computed strip width per sidebar/inspector state, and hiding the toolbar
also removes the traffic lights. Too fragile for little gain: the toolbar stays
system-managed (title + file path, buttons always visible), tabs are a row
below it. Don't fight AppKit chrome. **Superseded by D42.**

### D18. Share compiled tree-sitter highlight queries
Compiling a highlight query is slow (~230 ms for Swift in Debug) while parsing
and highlighting a typical file takes ~20 ms. Each editor compiled its own
query, so every file open lagged visibly. Queries are now compiled once per
language (`HighlightQueries`, lock-protected cache) and prewarmed off the main
thread when the editor plugin activates.

### D19. Quick picks in the kernel; project search without ripgrep
The command palette overlay became a generic `QuickPick` in `OrbitAPI`, so any
plugin can show a searchable list; the palette and Open Quickly (⌘P) are both
quick picks. Results are recomputed only when the query or the observed data
changes (not on arrow keys).

Find in Project runs in-process (`NSRegularExpression`, files scanned in
parallel) instead of shelling out to ripgrep: `rg` isn't installed by default
and a GUI app can't rely on the user's PATH. It is fast enough for typical
projects (~1.4k files searched in ~0.1 s in Debug). The file list comes from
`git ls-files -co --exclude-standard` so `.gitignore` is honoured, falling back
to a directory walk outside git. Unsaved buffers are searched instead of their
disk copies.

### D20. Terminal: SwiftTerm in a bottom panel
SwiftTerm (pure Swift, SwiftPM, mature AppKit view) over libghostty, which has
no stable embedding API yet and needs a Zig build. Pinned below 1.99 (a fresh
pre-2.0 release). The terminal lives in a new shell slot, `ui.addBottomPanel`,
under the editor like VS Code/Cursor, toggled with ⌃`. Each session owns its
NSView, so hiding the panel or switching tabs keeps scrollback; the panel hosts
it in a container view. Shells start as login shells (`-zsh`) in the project
folder with the app's environment minus host-agent variables; Option is not
Meta so macOS layouts can type their characters.

### D21. Source Control panel first; worktrees opt-in with "Apply"
The git panel came before per-session worktrees: it's needed daily and gives
the git plumbing worktrees will reuse. It shells out to `/usr/bin/git`
(porcelain v2 status), runs operations one at a time off the main actor, uses
the login-shell environment so credential helpers work, and never prompts
(`GIT_TERMINAL_PROMPT=0`); failures show git's own message. Discarding a new
file moves it to the Trash. ⌘↩ commits only from the message field because
the agent composer already owns ⌘↩.

Worktrees (next): opt-in per session via an "Isolated" toggle, off by default,
so a lone agent keeps working in the project as today. Results come back with
an "Apply" action that writes the worktree's changes into the project and
records them as agent changes, so review stays inline (D7) instead of a branch
merge.

### D22. Generated commit messages go through the user's agent
Cursor-style ✨ in the commit box. Instead of a separate model API (which would
need its own key), Git asks the `AgentCompletion` service, implemented by the
Agents plugin: a hidden ACP session of the last used agent, read-only (no
permissions granted, no file writes), low reasoning effort when offered. The
prompt carries the diff (staged, or everything incl. heads of new files,
capped at 24k chars) and the last 12 subjects for style. The agent process is
kept warm for 10 minutes and prewarmed when the Source Control panel shows
changes: measured with Codex ~19 s cold → ~8 s warm; the rest is the agent
harness and model latency.

### D23. Git diffs open in a tab; explorer shows git colors
Clicking a file in Source Control opens a read-only diff tab (index → working
tree, or HEAD → index for staged), like VS Code. This doesn't contradict D7:
agent changes are still reviewed inline in the editor; the tab is for plain
git changes and only offers git actions. Explorer decorations come from the
Git plugin through `FileStatusProviding` (OrbitAPI); colors live on
`FileChangeKind.color` in OrbitUI so the explorer and the git panel match.
Folders take their most important child's kind (conflict > deleted/modified >
renamed > untracked/added).

### D24. Own line-number ruler; cheaper highlighting
Scrolling stuttered. Measured on an offscreen STTextView (2k-line Swift file,
CPU per 120 pt scroll step, Debug): 47 ms before → ~13 ms after.
- STTextView's gutter rebuilt one view per visible line and enumerated every
  paragraph above the viewport on each layout (slower the deeper you scroll).
  Replaced with `LineNumberRuler`, an `NSRulerView` that draws visible numbers
  in one pass using cached line starts; `showsLineNumbers` stays off.
- Highlighting set a font attribute on every token (a text-storage edit and a
  relayout each). Colors stay rendering attributes; fonts are only touched for
  heavier tokens (medium keywords), batched into one editing transaction.
- Neon token requests raised from 1 KB to 4 KB: fewer viewport redraws without
  long first-paint hitches (16 KB averaged slightly better but spiked to ~95 ms).

### D25. Replace in files, path globs, recent files
- Replace previews each match struck out next to its replacement, computed by
  the same search pass (`NSRegularExpression` templates, so `$1` works in regex
  mode; plain mode escapes the template). Replacing re-runs the regex on the
  current text, never trusting stale result ranges; empty matches are skipped,
  same as in search. Open files with unsaved edits change in their buffer and
  stay unsaved; everything else is written through `DocumentStore`. "Replace
  All" asks for confirmation, per-file replace (hover a file row) doesn't.
- Include / exclude are VS Code-style comma-separated globs (`*.swift`, `src`,
  `/docs/**/*.md`, `*.{h,m}`), compiled to case-insensitive regexes; a pattern
  matches a path or any folder above it, and unanchored patterns match at any
  depth. Filters keep applying while their fields are hidden (the toggle stays
  tinted).
- Recent files live in the kernel (`Workspace.recentFiles`, recorded when a
  file tab becomes active, 50 per project folder in UserDefaults) so any plugin
  can use them. ⌘P with an empty query lists them without the current file, so
  ⌘P ↩ goes back to the previous file; with a query they get a small score
  bonus that only wins near-ties.

### D26. Ask before unsaved edits are lost
A standard macOS Save / Cancel / Don't Save alert (⌘D for Don't Save; one
alert listing every file when several are dirty) guards the three ways edits
could vanish: closing the last tab of a dirty file, opening another folder and
quitting. It lives in the kernel (`Workspace.confirmUnsavedChanges`,
`requestClose`) so plugins' user-facing close actions can reuse it, while
programmatic `close` (e.g. a rejected agent file was deleted) never asks.
Quitting asks in `applicationShouldTerminate`; closing the window quits the
app, so a cancelled quit reopens the main window (the workspace and its
buffers live in `PluginHost`, so nothing is lost). App-modal `runModal` rather
than a sheet: it also has to work after the window is gone.

### D27. Agent commands show up in our terminal
The tool card shows a command's output as plain text (expanded while it runs
or after a failure), with "Show in Terminal" to see it in a terminal tab
(sparkles icon) with colors. Tabs never take selection, focus or the panel
from the user. Two paths:
- **Display terminals** (what Claude Code and Codex actually use): their
  adapters never call `terminal/*` — they run commands themselves (checked in
  claude-agent-acp and codex-acp source). When we declare
  `clientCapabilities._meta.terminal_output(_delta)` they tag tool calls with
  `_meta.terminal_info`, stream `terminal_output_delta` and report
  `terminal_exit`. Their tab opens only on "Show in Terminal" (tabs per
  command flooded the panel) and is display-only: no Stop, typing goes nowhere.
  Claude sends a command's output in one piece when it finishes; Codex streams.
  Only `execute` tool calls get a tab: Codex also reads and lists files through
  the shell, and those flooded the panel (their output stays in the card).
- **ACP `terminal/*`** (other ACP agents) when the Terminal plugin is enabled:
  the command is a real PTY we own, so colors, interactive prompts and Stop
  work like any terminal; it gets its background tab right away, since it may
  wait for input.
- Plugins stay independent: `AgentTerminalHosting` + the `AgentTerminal` model
  live in `OrbitAPI`; Terminal hosts, Agents asks.
- What the agent reads is the raw byte stream turned into text
  (`TerminalTextCapture`: escape sequences dropped, `\r` redraws collapsed,
  newest `outputByteLimit` bytes, 1 MB by default), not the rendered screen,
  so scrollback limits and wrapping don't cut it.
- A command line without separate args runs through the user's shell (`-c`);
  `PAGER`/`GIT_PAGER` are `cat` so nothing waits for a keypress. Stop sends
  SIGTERM to the whole process group.
- Tabs don't pile up: a released command's tab closes unless it's selected,
  and only the 5 newest finished agent tabs are kept. "Show in Terminal" works
  anyway: a closed tab is opened again and redrawn from the command's raw
  output (`AgentTerminal.transcript`, colors included).

### D28. Agent sessions come back: restored tabs + Recent
Both adapters support ACP `session/load` (the agent replays the conversation
as `session/update` before answering) and `session/list`.
- Open tabs are saved per folder (provider, session id, title, selection) and
  restored on launch as dormant: an agent process starts only when its tab is
  shown, so ten old tabs don't mean ten `npx` agents at startup.
- Replay is marked by an event queued after `session/load` returns (the
  connection delivers every replayed notification first): while replaying,
  `user_message_chunk` adds the user's messages, and nothing counts as new —
  no change tracking refresh, no terminal tabs.
- If the agent can't load the conversation, the tab says so and continues as
  a new one.
- "Recent" merges Orbit's own records with each agent's `session/list` for the
  folder, which includes conversations started in the agent's CLI. Listing
  needs the agent's process, so it runs in the background once per folder per
  launch and the list fills in. Orbit's hidden helper sessions (commit
  messages) are remembered and filtered out.

### D29. Prompt attachments: @-files, ⌘L selection, images
- `@` at the end of the draft opens a file list above the composer, ranked like
  ⌘P (recent files first for a bare `@`); picking replaces the @-word with a
  chip. Files go to the agent as embedded `resource` blocks (current buffer
  text, unsaved edits included) when the agent declares `embeddedContext` and
  the file is ≤ 200 KB, else as `resource_link`.
- ⌘L works like Cursor: focus the chat and attach the editor's selection
  (a `resource` with a `#Lstart-Lend` URI, or a fenced text block for agents
  without embedded context). A repeat ⌘L doesn't duplicate it.
- Images (drop, paperclip, "Paste Image") are sent as `image` blocks when the
  agent declares `image`; PNG/JPEG/GIF/WebP as is, other formats as PNG,
  5 MB max.
- Plugins stay independent: the file index (`ProjectFileIndex`, Search) and
  the selection (`EditorSelectionProviding`, Editor) are OrbitAPI services.
- Switching folders brings back that folder's saved agent tabs; idle tabs of
  the previous folder close (saved, they return with it), busy ones keep going.

### D30. Git change markers in the gutter
Like VS Code's quick diff: bars on the line-number ruler (green added, blue
modified, a red wedge where lines were deleted), against the **index**, so
staged lines stop being marked. The Git plugin serves the index copy through
`VersionControlBaseline` (OrbitAPI) and bumps `baselineGeneration` whenever
status changes or an operation rewrote files; the editor refetches on that and
re-diffs 300 ms after typing stops, off the main actor (`LineMarkers` in
`LineDiff.swift`). Untracked files get no markers. Agent changes keep their
own inline review (D7); the two don't interact.

### D31. Stash, history and blame in the Source Control panel
- Stashes and History are collapsible sections under the changes, so the
  panel stays one list. Stashing always includes untracked files: the point
  is a clean tree ("stash, switch, pop"). Pop is the default action; delete
  asks first.
- History is the last 200 commits of HEAD. Expanding a commit lists its files
  (`--diff-merges=first-parent`, so a merge shows what it brought in); a file
  opens a read-only diff tab (parent → commit) like the working-tree diffs.
- Blame shows only for the caret's line, in the status bar, rather than as
  per-line annotations that would crowd the editor. It blames the editor's
  current text (`git blame --contents -`), so unsaved edits don't shift lines,
  and is cached per file contents. The cursor comes from the Editor plugin
  through `EditorSelectionProviding.cursor`, debounced, and looked up lazily
  (Git activates before Editor).

### D32. Syntax colors in diffs
The Editor plugin owns tree-sitter, so it serves a `SyntaxHighlighting`
service: one parse of a whole text off the main actor, captures mapped
through the editor's theme into `SyntaxSpan`s. Diffs highlight the full old
and new file (so lines inside multi-line strings or comments are right), then
color only the lines the hunks show (`DiffHighlighting`, OrbitUI). The
working-tree diff reloads every few seconds, so it re-highlights only when
either side's text changed. Texts over 1 MB stay plain.

### D33. Disk changes under unsaved edits
Agents (Codex and any shell edit) write straight to disk, so a buffer with
unsaved edits used to keep its stale copy and the next save silently undid
the agent's work. Now every open buffer syncs with disk whenever the disk may
have changed (`fileSystemDidChange`, and on app activation for other apps):
clean buffers reload; dirty ones get a three-way line merge (base = last
saved text) — changes on other lines just appear, like a teammate's edit in a
shared doc. Only when both touched the same or adjacent lines (git's rule) does
the editor show a "Changed on disk" banner: Compare opens your text against the
disk version with "Use Disk" per block, or take one side whole. Keep Mine saves
immediately so the state is unambiguous again. ⌘S re-checks the disk and asks
before overwriting a change; Save All skips conflicted files. ACP
`fs/write_text_file` still replaces the buffer: the agent read it through the
buffer, so it already saw the unsaved edits.

### D34. Composer paste and mid-draft mentions
⌘V with an image (screenshot) or files copied in Finder on the pasteboard
attaches them instead of pasting names; plain text — even when an image rides
along, as with rich text from some apps — pastes as usual. SwiftUI's text
field consumes the paste before any SwiftUI hook, so a local key-down monitor,
active only while the composer is focused, catches ⌘V first. @-mentions
follow the caret via `TextField(text:selection:)`, so a file can be mentioned
in the middle of a sentence; picking one removes the @-word where it was.
Tool-card diffs get syntax colors through the same `SyntaxHighlighting`
service as git diffs, passed down as a SwiftUI environment value.

### D35. Isolated sessions use APFS clones, not git worktrees
Amends D21. An isolated session's agent works in a clone of the whole project
folder (`clonefile`, one syscall, copy-on-write) under Application Support,
instead of a `git worktree`. A worktree starts from a commit: it lacks the
user's uncommitted work, untracked files, `node_modules`, `.env` and build
caches, so the agent couldn't build or run tests without a setup step. A clone
has all of it, costs almost no disk, works in non-git folders, and the agent's
own git commands (even commits) stay inside the copy. Changes are measured
against a shadow-git snapshot taken right after cloning (same `Checkpoints`
as turn tracking, so `node_modules` and friends never count).

Apply writes each changed file into the project through the document store
and records its previous contents as the agent baseline, so the result looks
exactly like a normal agent turn: inline Keep/Undo. If the project changed the
same file meanwhile, a three-way merge (D33) keeps both when they touch other
lines; otherwise the file is skipped and listed. Apply can repeat: files the
project already matches are skipped. The bar above the composer counts files
not applied yet. The service (`AgentIsolation`) lives in the Change Review
plugin, which owns change tracking; the Agents plugin only points the agent
at the copy, maps prompt attachments into it and skips project turn tracking.

### D36. Settings as a page in the main window
The small macOS Settings window held two tabs and couldn't grow. Settings now
take over the main window as their own native split view (sidebar with search,
the section's form as detail, like System Settings), opened by ⌘, (Orbit menu) and closed by "Back to Project" or Esc. A toolbar gear was
tried and dropped: macOS pins its own sidebar toggle first, so the gear
couldn't sit where it belongs. A hand-made
overlay on top of the workspace clashed with the glass sidebar and the title
bar; swapping views costs the editors' scroll positions, but documents,
terminals and agent sessions live outside the views and survive — closer to Cursor/VS Code, where settings
are something you browse. Plugins contribute sections through
`UIRegistry.addSettingsPane` with search keywords; the shell adds General,
Keyboard Shortcuts and Plugins. Options more than one plugin reads (theme, the
code font size used by the editor and terminal) live in `Preferences` in
OrbitAPI; a plugin's own options stay in its `PluginSettings`. Everything
applies live, no restart (except enabling plugins).

### D37. Extensions: data-first packages, a public registry on GitHub
Orbit gets Zed-style extensions that anyone can publish. An extension is a
folder with `extension.json` (id, name, version, author, repository, minimum
Orbit version, list of contributions), installed into
`~/.orbit/extensions/<id>/`. Contributions are **data first**:
- `themes` — UI accents and syntax colors (light / dark variants);
- `iconThemes` — SVG file and folder icons with match rules;
- `languages` — file types and how to get and launch a language server
  (npm package, GitHub release asset or a path on `PATH`);
- `agents` — the existing ACP agent manifests (`~/.orbit/agents/*.json`
  moves here, the old folder keeps working).
Code (`main`, TypeScript on JavaScriptCore) comes later in the same package
format. Data-only packages can't run anything, so most extensions need no
trust decision; a package that runs code or launches a binary says so and
the install sheet shows it.

The registry is a public GitHub repository with an `index.json` (id, version,
archive URL, sha256); authors add or update an entry by pull request, CI
validates the manifest. No server of our own. Orbit fetches the index,
installs archives after checking the hash, and offers updates; the UI is an
Extensions section in Settings (search, Install / Update / Uninstall).

Tree-sitter grammars stay built in: all ~20 together are a few MB, while
loading native parsers at runtime needs relaxed library validation (or a WASM
runtime). "Install only the languages you need" pays off for language
servers, which are large and downloaded on first use of their language.
Extra grammars in extensions can come later if a language really needs one.

Order: package format + local install with themes and icon themes (pure data,
proves the pipeline) → LSP kernel as a built-in plugin + language extensions →
registry and the Extensions UI → code plugins on JavaScriptCore.

### D38. Themes and icon themes use Zed's file formats
Step 1 of D37. Color themes are Zed theme-family JSON (`themes: [{ name,
appearance, style }]`) and icon themes are Zed icon-theme JSON, read as is;
a folder with Zed's `extension.toml` instead of `extension.json` loads too.
So the hundreds of published Zed themes work by dropping their folder into
`~/.orbit/extensions`, and authors don't learn a second format.

Orbit reads only what it draws itself: editor background / foreground /
active line / line numbers, cursor and selection (`players[0]`),
version-control colors (`version_control.*`, falling back to the older
`created` / `modified` / `deleted`), the terminal's background and 16 ANSI
colors, and `syntax`. The window chrome (sidebar, toolbar, tabs, glass) stays
native and follows only light/dark — a theme repaints content, not macOS.
Anything a theme leaves out uses the system color, which is how the built-in
"Orbit Light / Dark" keep the system editor background.

Light and dark themes are picked separately (Settings → General), like Zed's
`mode: system`: Appearance "System" switches between the two. File icon
themes are picked per mode the same way (icon sets often ship a light
variant); every icon theme is offered in both pickers, its own mode's first. Syntax lookup
tries the exact tree-sitter capture, then its Zed equivalent (our nvim-style
queries say `include`, `method`, `parameter`; Zed themes say `keyword`,
`function.method`, `variable.parameter`), then less specific names
(`keyword.return` → `keyword`). AppKit views (editor, ruler, terminal) resolve
colors for their current appearance and re-apply on a theme or light/dark
switch (`Extensions.themeDidChange`); SwiftUI reads them through `Theme`
and redraws by observation. Icon SVGs render in their own colors through
`FileIconView`, which falls back to the SF Symbols when no icon theme is
picked or it has no icon for a file. `~/.orbit/extensions` is watched
(FSEvents), so editing a theme shows up immediately.

### D39. Themed middle, native edges (like Xcode)
Amends D38. With only the editor themed, a dark theme with its own background
(GitHub Dark `#0D1117`) sat in grey chrome like a window inside a window. Now
the theme's `editor.background` also paints the middle of the window — the
tab bar, the toolbar area above the editor, the bottom panel and the
inspector (agent chat) — through `View.editorBackground(fallback:)`. The
sidebar stays native glass and frames the content, as in Xcode and Nova;
Settings stay fully native. Themes without a background (the built-in Orbit
ones) look exactly as before. Zed's per-surface keys (`tab_bar.background`,
`panel.background`, …) are still ignored: one surface color keeps the middle
calm and works with any Zed theme.
**Superseded by D40.**

### D40. Themes color only the code, chrome is native (as in Xcode)
Reverts D39. Painting the middle of the window fought the system at every
edge: on macOS 26 the toolbar above a `NavigationSplitView` ignores
`toolbarBackground`, the floating sidebar and inspector leave seams, and the
result looked half-painted — worse with every new theme. Now a color theme
colors exactly what Xcode's Font & Color themes do: the editor text area with
its gutter, code in diffs, the terminal, and git colors. Tabs, toolbar,
panels, status bar and the agent chat are always system surfaces in light or
dark mode. Fewer pixels themed, but every theme looks finished.

### D41. The theme background under the glass (Xcode 26)
Amends D40. Chrome is still never painted, but the theme's `editor.background`
now lies under the whole window (`themedWindowBackground()` on the split
view, plus `NSWindow.backgroundColor` for the transparent macOS 26 toolbar).
The glass sidebar and inspector float over it and take on its tint, the tab
bar, bottom panel and status bar drop their own fills (`nativeSurface(_:)`
steps aside under a theme), so the window reads as one theme the way Xcode 26
does. Without a theme background everything is plain native, as in D40.
The toolbar is gone altogether since D42.
Window properties are only touched outside SwiftUI updates and only on a
real change: changing them mid-layout crashed in a layout loop.

### D42. No toolbar: tabs in the title bar
Supersedes D17. Every attempt to theme the system toolbar left something grey
(the toolbar strip in full screen, then an opaque plate under the title), and
SwiftUI's tools for it (`toolbar(removing: .title)`,
`sharedBackgroundVisibility(.hidden)`) crash the full-screen restore. The main
window now uses `.windowStyle(.hiddenTitleBar)`: no title, no toolbar
background, the traffic lights stay. The editor area extends into the title
bar and its top row (`WindowTopBar`) holds the sidebar toggle, the tabs and
the command palette and agents buttons; with the sidebar hidden the row
starts after the traffic lights (not in full screen); empty space in it drags the window
(`WindowDragGesture`). Unlike D17 the tabs are ordinary content, not toolbar
items, so they stretch and need no width math. The window title (project
name) remains for the Window menu and Mission Control; the file path is in
the tab. Settings show their own title in the same row; "Back to Project" sits at
the bottom of the settings sidebar (a Done button in the top row ended up hidden).
The window toolbar is hidden outright (`toolbarVisibility(.hidden,
for: .windowToolbar)`): even empty, in full screen it lives in a separate
window that kept an opaque grey plate for the (hidden) title over the tab
row, and showing it only on hover covered the sidebar instead.
Hiding the toolbar also hides AppKit's title bar container with the traffic
lights (what D17 ran into); `TrafficLightsKeeper` shows it again and keeps it
shown (KVO). It is transparent and 52 pt tall; the tab row is 42 pt
(`Theme.topBarHeight`).
The keeper also moves the lights down a few points
(`trafficLightsDrop`) after every titlebar layout AppKit does: they read as
too high against the tab row.
In full screen the keeper does the opposite and keeps the container hidden:
there it lives in AppKit's separate toolbar window, whose opaque background
showed as a grey plate over the start of the tab row. The system sidebar
toggle that `NavigationSplitView` adds is removed
(`.toolbar(removing: .sidebarToggle)`): it floated over the sidebar next to
our own toggle in the tab row.


### D43. Agents panel: always a chat, one options button
The agents panel always shows tabs and always has a chat to type into: on
opening a folder its saved tabs come back, or a new chat opens; closing the
last tab opens a new one. The start screen with a button per agent is gone.
A new chat that nothing was sent in yet shows recent conversations of the
folder above the composer; it isn't saved to history or to the open tabs,
and resuming a conversation from it takes its place.
The composer has one button (like Cursor) instead of a menu per ACP config
option: it reads "Opus 5 High Plan" and opens a popover listing the settings
(effort, mode…) with icons and the model last. The model page has search and
groups models by agent; other agents' models come from the list each agent
last reported (cached in settings). Picking another agent's model in an empty
chat replaces it with a chat of that agent, keeping the draft; in a
conversation it starts a new chat. Model and effort are remembered per agent
for new chats; mode is not, so a chat never starts in "bypass permissions".
Built-in agents show their brand marks (Claude, OpenAI for Codex) instead of
SF Symbols: SVG paths from Simple Icons (CC0) in `AgentIcon.swift`, rendered
by NSImage's own SVG support as template images; Claude's is in its orange.
Custom agents keep their `systemImage`.

### D44. Cursor, Grok Build and OpenCode built in
Their own CLIs speak ACP over stdio, no adapter needed: `cursor-agent acp`,
`grok agent stdio`, `opencode acp` (all report models through
`configOptions`). Unlike the npx-launched Claude/Codex adapters they must be
installed by the user, so agents whose executable isn't on the login-shell
PATH are hidden from the picker, menus and the default-agent setting
(Settings lists them as "Not installed") and their `session/list` isn't asked.
Logos of Cursor, Grok and OpenCode come from lobe-icons (MIT), drawn even-odd.
A model option with a single choice is kept (Grok Build offers one model), so
the composer button still names the model.

### D45. Changed files live in the agent chat, not the navigator
The Changes panel in the left navigator is gone. Agent edits are made from
the chat on the right, so their list sits there too: a row above the composer
("3 files changed +42 −7", Undo All / Keep All, review next) that expands
into the files, like Cursor. The row is hidden when nothing is pending and
replaced by the isolation bar in isolated sessions (their edits aren't in the
project yet). The Agents plugin draws it from the `ChangeTracking` service, so
OrbitReview keeps only tracking and commands; the status bar's "N to review"
moved along and now opens the list. Review itself stays inline in the editor
(D7). Next/previous change (⌥⌘↓/↑, the banner chevrons) now continue into
the next changed file instead of wrapping inside one. The list is shared by
all sessions; attributing edits to the session that made them is left for
later.

### D46. Usage ring in the composer
A small ring next to the send button shows how full the agent's context is
(ACP `usage_update`: `used` / `size`); it stays neutral and turns orange at
75% and red at 90%. Clicking it opens a popover with the context, plan limits
and this session's cost and tokens. Limits come from Claude Code's adapter
(`_meta["_claude/rateLimit"]`, one window per event: 5-hour, weekly, per-model);
Codex's adapter only shows its limits through `/status`, so they're absent for
it. Token counts are summed from each prompt response's `usage` (agents report
the turn, not the conversation), so they cover what was sent since the chat
was opened in Orbit. The ring is hidden until the agent reports anything.

### D47. A compositing guard window in full screen
In full screen on the built-in ProMotion display, with the title bar hidden,
scrolling lists dropped to ~50–70 fps (smooth on an external display, and as
soon as the title bar was revealed). Profiling showed Orbit's own frames were
cheap (render 2–3 ms, GPU 1–2 ms, main thread mostly idle): alone on screen,
the window is flipped straight to the display, and that path paces it badly.
Xcode never hits it because its toolbar stays visible in full screen; Orbit
has no toolbar (D42). `FullScreenCompositingGuard` (App/MainWindow.swift)
keeps a 1-pt, 1%-opaque, click-through child window over the main window
while it's full screen, so the window is always composited. A fully clear
window doesn't count. Revisit if a future macOS fixes direct flip pacing.

### D48. Themes and icons come from Zed's catalog, with try-on
Amends D37's registry for themes and icon themes. Since D38 reads Zed's
formats as is, Orbit browses Zed's own extension catalog instead of starting
an empty one: Settings → Extensions has an Installed / Catalog switch; the
catalog lists Zed extensions that provide themes or icon themes (search,
sorted by downloads) with Try On, Install, Update and Uninstall. It uses the
API Zed itself uses (`api.zed.dev/extensions?provides=…`, archives from
`/extensions/<id>/<version>/download`, a .tar.gz of the built extension). That
API is Zed's, not a promise to us, so it sits behind one type
(`ExtensionCatalog`) and can move to the `zed-industries/extensions` repo or
our own `index.json` without touching the UI. From an archive Orbit keeps
only manifest, themes, icon themes and icons; WASM, grammars and language
files are deleted, so nothing installed can run code and there is no trust
prompt. Uninstall moves the folder to the Trash.

Try-on unpacks into the caches folder and sets `Extensions.preview`: its
theme draws instead of the picked one (in its own mode, which the app is
switched to while trying it on) and its icons in both modes, nothing is
saved. Settings cover the editor, so the catalog shows a sample (code, file
icons, terminal colors) in the theme; back in the project a glass bar over
the editor offers Install, the catalog, or stop. Install while trying on
reuses the download and picks the tried theme and icons.

### D49. Theme selector, catalog thumbnails, light/dark pairs
Builds on D48. **Select Theme…** (⌃⌘T, View menu and palette) is a quick
pick like Zed's theme selector: the highlighted row is drawn on the real
window through `Extensions.preview` (its mode included), Enter keeps it, Esc
restores what was there, including a try-on started in Settings. Installed
themes come first (the current mode's, then the other's), then catalog
themes that aren't installed; reaching one downloads it after a 250 ms pause
(so arrowing past doesn't download every row) and Enter installs it.
`QuickPick` gained `initialSelection`, `onHighlight` and `onCancel` for this.

Catalog rows show a thumbnail of the theme (background and a few code lines
in its syntax colors). The theme files come from the extension's archive,
cached with try-on downloads, four at a time; extensions that also carry
language support are skipped, their archives are large. Downloading for
thumbnails counts as a download in Zed's stats; each version is fetched once
per machine.

Picking a theme in the selector, or installing one from the catalog while
trying it on, also picks its partner for the other mode from the same
extension (the theme whose name shares the longest prefix: Catppuccin
Mocha → Latte, One Dark → One Light), and a fixed Light/Dark appearance
switches to the theme's mode. The Settings pickers still set one mode only.

### D50. Catalog is a selectable List with a pinned try-on panel
Replaces the paged grouped Form of D48: a Form draws every row up front, so
hundreds of themes lagged. The catalog is a `List` (table-backed, only the
visible rows are drawn) and selecting a row tries it on after a 250 ms
pause, so clicking or arrowing through the list previews like the theme
selector (D49); the Try On / Stop row buttons are gone. The try-on panel
(sample, variant pickers, Install / Stop) sits between the search field and
the list, outside the scroll view, so it never scrolls away. Quick pick rows
are lazy too, which lets the theme selector list the whole catalog.
