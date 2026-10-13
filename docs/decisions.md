# Decision log

Short ADR-style records. Newest at the bottom. Each: context → decision → why.
Entries aren't rewritten when a later decision changes them: the later one
says what it supersedes, and the old one gets a one-line note pointing to it.
Entries superseded as a whole move to the archive.

## Index

Read this list, then the entries your work touches. → marks what replaced (part of) an entry;
fully superseded entries live in [decisions-archive.md](decisions-archive.md).

- D1. Native SwiftUI/AppKit, macOS 26+
- D2. Everything is a plugin
- D3. ACP for all agents — presets → D52
- D4. STTextView + tree-sitter for the editor
- D5. Agents write to disk immediately; Orbit reviews after
- D6. Shadow-git checkpoints for change tracking
- D7. Inline diffs in the editor — no separate review tab
- D8. Line-based diff with `CollectionDifference`
- D9. No App Sandbox, direct distribution
- D10. Login-shell environment, filtered
- D11. Built-in agent adapters via unpinned npx — archived, superseded by D52
- D12. Per-block keyboard shortcuts
- D13. App icon as an Icon Composer `.icon`
- D14. Own syntax-highlight plugin instead of `NeonPlugin`
- D15. One brand mark, shared by the icon and the UI
- D16. Status bar only when there's something to say — partly outdated (D54, D65)
- D17. Keep the system window toolbar as is — archived, superseded by D42
- D18. Share compiled tree-sitter highlight queries
- D19. Quick picks in the kernel; project search without ripgrep
- D20. Terminal: SwiftTerm in a bottom panel
- D21. Source Control panel first; worktrees opt-in with "Apply" — worktrees → D35
- D22. Generated commit messages go through the user's agent
- D23. Git diffs open in a tab; explorer shows git colors
- D24. Own line-number ruler; cheaper highlighting
- D25. Replace in files, path globs, recent files
- D26. Ask before unsaved edits are lost
- D27. Agent commands show up in our terminal
- D28. Agent sessions come back: restored tabs + Recent
- D29. Prompt attachments: @-files, ⌘L selection, images
- D30. Git change markers in the gutter
- D31. Stash, history and blame in the Source Control panel
- D32. Syntax colors in diffs
- D33. Disk changes under unsaved edits
- D34. Composer paste and mid-draft mentions
- D35. Isolated sessions use APFS clones, not git worktrees — amends D21
- D36. Settings as a page in the main window
- D37. Extensions: data-first packages, a public registry on GitHub — themes registry → D48
- D38. Themes and icon themes use Zed's file formats
- D39. Themed middle, native edges (like Xcode) — archived, superseded by D40
- D40. Themes color only the code, chrome is native (as in Xcode) — amended by D41
- D41. The theme background under the glass (Xcode 26) — amends D40
- D42. No toolbar: tabs in the title bar — supersedes D17
- D43. Agents panel: always a chat, one options button
- D44. Cursor, Grok Build and OpenCode built in — archived, superseded by D52
- D45. Changed files live in the agent chat, not the navigator
- D46. Usage ring in the composer
- D47. A compositing guard window in full screen
- D48. Themes and icons come from Zed's catalog, with try-on — amends D37
- D49. Theme selector, catalog thumbnails, light/dark pairs
- D50. Catalog is a selectable List with a pinned try-on panel — replaces D48's list
- D51. Translucent ("blurred") theme backgrounds are flattened
- D52. Agents come from the ACP registry; no built-in presets — supersedes D11, D44, D3's presets
- D53. Everything colored by the theme follows a switch live
- D54. LSP: our own small client, our own server table, Mason for installs — in part → D65
- D55. Language servers are tested end to end against the real servers — TS setup → D65
- D56. Completion and signature help: one request per word, filtered locally
- D57. Language servers install from the Mason registry, with our own installer — table → D65
- D58. Extra grammars are compiled lazily, with Zed's highlight queries
- D59. Code actions, rename, formatting, Problems
- D60. Formatting follows the repository
- D61. Formatters are data, overridable per project
- D62. Find references, go to symbol, highlights of the symbol under the caret
- D63. The bottom area has tabs, and the status bar opens its panels
- D64. ESLint and Tailwind run beside a file's language server — in part → D65
- D65. Language support is data; servers understand projects, Orbit doesn't — current
- D66. Fixes in the hover card; ⌥Esc opens completion
- D67. Features are found in a right-click menu, and their shortcuts are taught
- D68. The hover card sits over the line, as in VS Code
- D69. Embedded languages are layers parsed by the highlight worker
- D70. Inlay hints are room in the text plus labels over it

### D1. Native SwiftUI/AppKit, macOS 26+
Goal is minimal memory/battery and an Apple-native feel. Targeting macOS 26
gives Liquid Glass and modern SwiftUI APIs for free. The author uses the app
personally, so no need to support older macOS.

### D2. Everything is a plugin
The author wants a "harness"-like system where anything is pluggable. Built-in
features are plugins on the same public API; plugins talk only via service
protocols in `OrbitAPI`.

### D3. ACP for all agents
> **Presets superseded by D52: no agents are built in; all come from the ACP registry or a custom manifest.**

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

Colors are TextKit 2 rendering attributes set on the layout manager, and
STTextView redraws a line view only when its layout changes. So after each
paint the coordinator marks the painted lines' views dirty: otherwise a first
parse landing after the first frame (a busy open: a language server starting,
a grammar loading) left the file uncolored until a scroll or a keystroke.

### D15. One brand mark, shared by the icon and the UI
The glyph lives in `App/AppIcon.icon/Assets/orbit-mark.svg`; a copy with the
viewBox cropped to the glyph is `OrbitUI/Resources/OrbitMark.svg`, exposed as
the `OrbitMark` view (template image, takes the foreground style). The welcome
screen shows the real app icon (`NSApp.applicationIconImage`); smaller in-app
spots (agents empty state) use `OrbitMark`. No SF Symbol stand-ins for the logo.
If the icon glyph changes, update both SVGs.

### D16. Status bar only when there's something to say
> **Partly out of date: the language item came back as the language server status (D54), with a menu (D65).**

The bottom bar used to be always on, mostly showing just the file's language.
The language item was dropped (the extension already says it), and
`StatusItem.isVisible` lets each plugin report whether it has content; the
shell shows the bar only while at least one item is visible (agents working /
waiting for approval, changes to review).

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

> **The worktree plan below was replaced by APFS clones (D35).**

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

### D40. Themes color only the code, chrome is native (as in Xcode)
> **Amended by D41: the theme background lies under the whole window.**

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

### D51. Translucent ("blurred") theme backgrounds are flattened
Zed themes marked "(blur)" use translucent `background` / `editor.background`
so Zed can blur the desktop through the window. Orbit lays the editor
background under the whole window (D41), so the desktop showed through
unblurred. `editor.background` is composited over the theme's `background`,
itself over black (dark) or white (light), and `terminal.background` over the
result: the color the theme reads as. Real translucency (a blurred window)
could come later as an option; it touches the window setup that crashed
before (D42), so it isn't worth it for a handful of themes now.

### D52. Agents come from the ACP registry; no built-in presets
Supersedes D11 and the presets of D3. Orbit no longer ships agents: Settings
→ Agents lists what's installed and what the ACP registry offers
(`cdn.agentclientprotocol.com/registry/v1/latest/registry.json`, the list Zed
and JetBrains IDEs use, which CI checks for working sign-in), with Install,
Update and Uninstall. Installing writes the same `~/.orbit/agents/<id>.json`
manifest a hand-written custom agent uses, so there is one kind of agent.

The registry offers an agent as a per-platform archive, an npm package or a
PyPI package. A download wins on macOS (it needs nothing else installed): the
archive is checked against its sha256, unpacked with bsdtar into
`~/.orbit/agents/<id>/bin` and run from there. Otherwise `npx -y <pkg@version>`
or `uvx <pkg@version>`; an agent whose launcher isn't on the PATH says it needs
Node.js or uv. Versions are pinned to what was installed (unlike D11's
unpinned npx), and the registry's newer version shows as Update. The
registry's monochrome SVG icon is saved next to the manifest and drawn as a
template; Claude and Codex keep their brand marks.

Migration: Orbit's preset ids `claude-code` and `codex` map to the registry's
`claude-acp` and `codex-acp` in saved tabs, recent chats, options and the
default agent. Once, for people who used the presets, Orbit installs those
two from the registry and writes custom manifests for Cursor, Grok and
OpenCode if their CLIs are on the PATH, so nothing that worked disappears.
With no agent installed, the Agents panel offers "Browse Agents".

### D53. Everything colored by the theme follows a switch live
Syntax-colored diffs bake colors into `AttributedString`s, so they kept the
old theme until reopened. `Extensions.themeKey` (both modes' theme ids plus
the reload revision; observable) is part of their `.task(id:)`, so a pick, a
try-on or a reload rehighlights them; light/dark needs nothing, the colors
are dynamic. The editor's agent-change overlays (added background, removed
lines) take `version_control.added` / `deleted` from the theme like the
gutter does, set from the same `applyTheme` that runs on every switch.

### D54. LSP: our own small client, our own server table, Mason for installs
> **Superseded in part by D65: servers are data (root markers, launch sources, no npx), one per project root rather than per language, and hundreds come from nvim-lspconfig. The launch order below is history.**

Zed's language support can't be reused: its built-in languages are Rust code
in Zed, and extension languages are WASM that decides what to download and
how to launch it. The Languages plugin (`OrbitLanguages`) is a plain LSP
client over the existing JSON-RPC connection (now with `Content-Length`
framing next to ACP's newline framing). Which servers exist and how to launch
them is a small table of our own (`LanguageServerConfig`): Swift uses
`xcrun --find sourcekit-lsp`; TypeScript/JavaScript use the project's
`node_modules/.bin/typescript-language-server`, then a global one, then
`npx -p typescript-language-server -p typescript`. Installing missing servers
will come from the Mason registry (data-only, Apache-2.0, 500+ packages with
per-platform downloads), the same way agents come from the ACP registry.

Cost control, since servers own most of the memory: a server starts with the
first open file of its language (never for diff views), one per language per
project, and stops 10 minutes after its last file closes or when the folder
changes. Typing is coalesced (120 ms) and sent as one incremental change
(common prefix/suffix, UTF-16 positions like `NSString`). Hover waits for the
pointer to rest 450 ms. Semantic tokens are not used: tree-sitter colors code.

The editor gets everything through the `LanguageIntelligence` service (plugins
don't import each other): diagnostics are drawn as small squiggle views only
for the viewport (no text-storage attributes, no relayout), colored by the
theme's `error` / `warning` / `info`; hover is an `NSPopover` with the
problems and the server's markdown; ⌘-click and ⌃⌘J (Xcode's Jump to
Definition) open the definition; ⌘' (Xcode's Next Issue) walks problems. The
status bar shows the active file's server and its error/warning counts.

> **Superseded by D65: no npx; a project without TypeScript gets Orbit's typescript-language-server.**

Amendment (TypeScript 7): TypeScript 7 is the native compiler and has no
`tsserver.js`, so typescript-language-server can't run on it; its own `tsc
--lsp --stdio` is the server. The project's TypeScript decides: 7+ runs its
`node_modules/.bin/tsc --lsp --stdio`, older ones go through
typescript-language-server (project, global, then npx), and a project without
TypeScript gets `npx -p typescript tsc --lsp --stdio`. TypeScript 7 doesn't
push diagnostics; it answers LSP 3.17's `textDocument/diagnostic`. The client
pulls after every open/change when a server advertises `diagnosticProvider`
(dropping answers for older versions) and again on `workspace/diagnostic/refresh`.

### D55. Language servers are tested end to end against the real servers
> **Since D65 the third TypeScript setup is "no project install" (Orbit's typescript-language-server), not npx.**

Unit tests of the LSP client checked our own helpers, but what broke in
practice was the meeting with a real server: how it is launched (TypeScript 7
has no `tsserver.js`), what it expects (pull diagnostics), what it answers
with (SourceKit-LSP returns the folder's real path, not the symlink it was
opened through). So each supported language has a fixture project in
`Tests/OrbitKitTests/Fixtures/Languages` and one scenario,
`LanguageServerIntegrationTests`, drives the real `LanguageServer` the way the
editor does: the error arrives at the right UTF-16 spot (after an emoji and
Cyrillic), moves with an edit above it (incremental sync), goes away when
fixed; hover and go to definition answer across files; after shutdown no
process is left, including what npx spawned. The fixture is opened through a
symlink, like macOS's /var → /private/var. TypeScript runs three ways: the
project's TypeScript 7, TypeScript 5 with typescript-language-server (npm
installs are cached in the temp folder) and npx with no project install. A
server that isn't installed skips its test. A new language is a fixture folder
and a `LanguageCase`.

The client (OrbitACP, the language-intelligence types and OrbitLanguages'
server code) is Foundation-only, so on Linux `Package.swift` declares just
those targets and these tests; cloud sessions install Swift with
`scripts/linux-swift.sh` and run `make test-languages` against the Linux
builds of the same servers before pushing. Only the editor's drawing of the
results needs a look on the Mac.

They found three bugs right away: writing to a server that had died killed
Orbit with SIGPIPE (the pipe is now `F_SETNOSIGPIPE`); a server launched
through npx outlived Orbit's shutdown, because npm doesn't pass `exit` or
SIGTERM on (the connection now closes the server's input, which ends the whole
chain); and go to definition in a folder opened through a symlink pointed at
the real path (server paths are mapped back under the folder as opened).

### D56. Completion and signature help: one request per word, filtered locally
Completion opens while typing, like every IDE: on the first letter of a word
(not a digit) and on the server's trigger characters (`.`, quotes, `<`…, but
not space). ⌃Space opens it anywhere. Return and Tab accept, Esc closes,
↑↓/Page move.

Speed is the point, so the server is asked once per word: further typing
filters that list on the client with a fuzzy matcher (`FuzzyPattern` in
OrbitAPI: the letters in order, the first one at a word start, prefix and
word-start matches first, then the server's `sortText`). A longer pattern
only narrows the previous matches. Only lists the server marks incomplete
(SourceKit-LSP caps its own) are asked again, 40 ms after the last key, and
the superseded request is cancelled with `$/cancelRequest` (JSON-RPC requests
to language servers are tied to Swift task cancellation). A word with no
matches keeps its (hidden) session, so typing a new name doesn't hit the
server per key. Long lists are parsed off the main actor; the popup is an
NSTableView in a non-activating child panel, so only the visible rows exist
and focus never leaves the text view. Documentation is resolved
(`completionItem/resolve`) only for the selected row, after 80 ms.

Accepting uses the server's edit range when it gives one, expands snippets
(`$1`, `${1:name}`, choices, `$0`) with Tab/⇧Tab through the placeholders,
and applies auto-import edits after resolving (they may land a moment
later, as in VS Code). Signature help shows above the line on the server's
trigger characters and follows the caret inside the call. SourceKit-LSP in
Swift 6.2 has no signature help; Swift completions carry placeholders
instead, as in Xcode.

The server side runs against real servers in `make test-languages`
(completion after a dot, resolve, signature help, cancellation); the matcher
and snippet parser have unit tests.

### D57. Language servers install from the Mason registry, with our own installer
> **The table is no longer only ours: D65 adds the servers imported from nvim-lspconfig, and ranks them per file type.**

The author installs the languages they need themselves: opening a file whose
server is missing shows a banner above the editor ("Python support isn't
installed", Install / Not Now; Not Now stops offering that language), and
Settings → Languages and the status bar install too. The server table stays ours (`LanguageServerConfig.all`:
file types, binary, arguments; 20 languages), because the registry says
how to install a package but not how to launch it or for which files. Mason's
registry (data only, Apache-2.0, the list Neovim uses) gives the package and
version: `registry.json.zip` from its GitHub releases, cached a day in
`~/.orbit/languages`. Installing is our code, not Mason's Lua: npm (`npm
install --prefix`), PyPI (a venv; binaries run through the venv's python so
the folder can be moved into place), Go (`go install` with `GOBIN`), Cargo
(`cargo install --root`), GitHub release assets and plain downloads (curl,
tar, unzip, gunzip), with Mason's `{{ … | strip_prefix }}` templates and
per-platform targets. A package installs into a temporary folder and is
swapped in only when complete, with a receipt (`orbit-receipt.json`) saying
how to run its binaries. Orbit's copy wins over one found on the machine;
servers already there (Xcode's SourceKit-LSP and clangd, rustup's
rust-analyzer…) need no install. RubyGems and other package managers aren't
driven: Ruby's server is found on PATH only.

`make test-language-installs` installs every server from the real registry
and runs each on a small project with a problem in it, expecting the
server's diagnostic (or a completion). On its first run it found that the
vscode-langservers (CSS, HTML, JSON) register pull diagnostics dynamically
(`client/registerCapability` is now honored) and that the CSS server crashes
when `workspace/configuration` is answered with null (we answer `{}`).

### D58. Extra grammars are compiled lazily, with Zed's highlight queries
The 20 grammars built into the editor (STTextView-Plugin-Neon's, linked in)
stay: they cost nothing until used. Languages Orbit has servers for but no
grammar (Lua, Zig, Terraform/HCL, Dockerfile, Svelte), or only a stand-in
(Kotlin read as Java, SCSS as CSS, `.tsx`/`.jsx` as TypeScript, which can't
read JSX), get one the first time such a file opens: no prompt, since it's a
small library built in a second or two. `GrammarSource.all` pins each
grammar repository at a commit (the one Zed's extension for that language
uses) and the highlight query from that extension (or Zed's own TSX), so
the capture names are exactly what Zed themes style. Installing is `git
fetch` at the commit, `xcrun clang -dynamiclib` of `parser.c` (+ `scanner.c`),
and the query, into `~/.orbit/grammars/<name>` with a `grammar.json`; the
editor `dlopen`s it on first use and open editors switch to it
(`GrammarRegistry.revision`). Not Zed's wasm grammars: those need a wasm
runtime inside the editor; a native library is smaller and faster. Not
nvim-treesitter's queries: their capture names are Neovim's.

`make test-language-installs` also builds every grammar from its commit,
loads it and checks its sample parses without errors and gets comment,
keyword, string… captures.

### D59. Code actions, rename, formatting, Problems
- **Code actions** (⇧⌘A, Xcode's Show Code Actions; ⌘. stays Stop Agent): a
  menu at the caret, fixes first (the server's preferred one on top), then
  refactorings. The problems under the caret go back to the server verbatim
  (`code`, `data`), which is what TypeScript's fixes key on; SourceKit-LSP's
  fix-its ride on its diagnostics, so the client advertises
  `codeActionsInline`. Actions are resolved lazily; command-only actions run
  through `workspace/executeCommand` and their edits come back as
  `workspace/applyEdit`, which the client now answers.
- **Rename** (⌃⌘E): a field over the symbol (`prepareRename`, or the word
  when the server has none); Return renames across the project.
- **Formatting** (⌃⇧I, Xcode's Format File; Option-only shortcuts never
  reach the menu in a text view, they type a character) with the file's own indentation; "Format on save" in
  Settings → Editor (off by default; a server slower than 2 s doesn't hold
  the save).
- Edits from any of these go through `SourceEditing`: files open in an
  editor change in the text view as one undo step with the caret kept;
  other files are edited and saved on disk.
  Server edits are first applied to a copy of the text and replayed as a
  few changed line blocks (`LinePatch`): TypeScript formats with hundreds of
  one-space edits, and replacing them one by one in the view (each one
  syncing the document, highlighting and squiggles) took seconds. Undo
  restores the caret and scroll position from before the edit (an extra
  undo action registered first in the group, so it runs last).
- **Problems** (⇧⌘M): a bottom panel with every open file's errors and
  warnings, worst files first; a click opens the spot.

They live in a **Code** menu (with Go to Definition and Next Problem) and are
always enabled: SwiftUI menus re-check `isEnabled` only when something they
observe changes, and neither the active editor nor a server's features are
observable, so an item disabled at launch stayed disabled with its shortcut
dead. An action that can't run beeps.

The real-server tests cover a fix per language (add a missing import in
TypeScript 5/7, `var` → `let` in Swift), formatting and a cross-file rename.

### D60. Formatting follows the repository
A language server formats by its own built-in rules, which a repo with
Prettier doesn't follow, and the indentation Orbit passed it was the file's
smallest indent: one space in any file with a JSDoc block (` * …` lines).
Now, in order:
- **The repo's formatter.** The nearest Prettier config (`.prettierrc*`,
  `prettier.config.*`, a `prettier` key in `package.json`) or `biome.json`
  above the file, with the tool in a `node_modules/.bin` up to the folder
  root: the file is piped through it (`--stdin-filepath`, so its ignore
  files, overrides and plugins apply) and the result goes in as one edit,
  reduced to changed line blocks like server edits. Only the repo's own
  copy, never a global one: another major version formats differently. A
  failure (a syntax error) is shown in an alert; it doesn't fall back to
  the server, whose rules would be the wrong ones.
- **Otherwise the server**, with `tabSize`/`insertSpaces` from
  `.editorconfig` (nearest file wins, stops at `root = true` or the folder
  root) or else guessed from the file: the most common step between
  consecutive indented lines, ignoring comment continuation lines.

`format` now returns why it failed instead of a Bool. Real Prettier is
tested with the install tests (`make test-language-installs`).

### D61. Formatters are data, overridable per project
Builds on D60. Rather than code per tool, formatters Orbit recognizes are a
table (`FormatterPreset.all`): Biome, dprint, Prettier, Ruff, Black, StyLua,
each with the config that turns it on (files, a `[tool.x]` table in
`pyproject.toml`, a `package.json` key), where its executable may be
(`node_modules/.bin`, `.venv/bin`, `PATH`) and its stdin arguments. Most
languages need no entry: their servers already run the language's own tool,
which reads the repo's config (swift-format, clang-format, rustfmt, gofmt,
taplo, lua-language-server with `.editorconfig`). The table only covers
ecosystems where the server's formatter isn't what repos use.

Anything else goes in `"formatters"` in `.orbit/settings.json` (the
project's, committed with the repo) or `~/.orbit/settings.json`, keyed by
file type (`"ts, tsx"` works): a preset name, `"server"`, `"off"`, or
`{ "command", "arguments" }` with `{file}` for the path. The project's file
wins, then the user's, then detection, then the server. A rule that can't
run (unknown name, tool not installed) is an error shown to the user, never
a silent fallback to other formatting rules.

The user learns about it where it matters: ⌃⇧I always answers (an alert says
why nothing could format and where to set a formatter up, instead of a
beep), and Settings → Languages → Formatting lists what formats which file
types in the open folder and why (`apps/web/.prettierrc`), flags tools that
are configured but not installed (no `npm install` yet), and opens or
creates the settings files with an example. Real Prettier and Ruff run in
the install tests.

Addendum: ⌃⇧I always shows what happened. A note in the editor's corner
says "Formatted · Prettier" or "Already formatted · TypeScript language
server" (and "Formatting…" if it takes over 250 ms); a failure is an alert
naming the formatter. `format` returns a `FormatOutcome` for it. External
formatters run with their pipes read on dispatch threads (not blocking
Swift's cooperative pool) and are killed after 15 s.

Addendum: more presets. oxfmt and Deno (`deno.json`) for the web; ESLint
(`--fix-dry-run --format json`, the fixed text is `output` in its report, a
fatal message is a parse error); shfmt for shell; Standard Ruby and RuboCop
(binstub, then `bundle exec` when `Gemfile.lock` has the gem, then `PATH`;
exit 1 with offenses left is still a result, `Lint/Syntax` in their errors
isn't); Pint and PHP CS Fixer from `vendor/bin`, run on a temporary copy
with the file's name since neither reliably reads stdin (stdin is
`/dev/null`, so a question gets no answer instead of hanging). Presets got
a mode (stdin, ESLint report, temporary file), success exit codes and a
trigger: ESLint is a fallback, picked only when no formatter is configured
anywhere above the file (a repo with Prettier and ESLint formats with
Prettier); shfmt has nothing to configure but `.editorconfig`, so being
installed is enough, also only as a fallback. Prettier is also picked by
being among `package.json`'s dependencies: its defaults are then the
repo's style. Each one runs for real in the install tests.

### D62. Find references, go to symbol, highlights of the symbol under the caret
- **Find References** (⇧⌃⌘F → ⇧⌘R in D67; Xcode's Find Selected Symbol in Workspace):
  `textDocument/references` with the declaration, listed in a **References**
  bottom panel next to Problems: "12 references to `greet` in 3 files", files
  grouped (the one searched from first), each use as its line with the symbol
  marked; a click opens the spot with the caret on it. A panel rather than a
  popover or picker: the list stays while the user walks through it, as in
  Xcode's Find navigator. SourceKit-LSP answers from its background index, so
  right after opening a Swift package it can come back empty; the panel says so.
- **Go to Symbol in File** (⇧⌘O): the file's outline (`documentSymbol`,
  hierarchical, or flat lists nested by range) in a quick pick, nested symbols
  indented, starting on the symbol the caret is in; typing filters fuzzily.
  **Go to Symbol in Project** (⌘T): `workspace/symbol` asked 120 ms after
  typing pauses, from every running server (a language with no open file has
  no server, and isn't started for a search); the pick re-reads results when
  they arrive (its items read an observable list). No `resolveSupport`, so
  servers send full locations.
- **Highlights**: 250 ms after the caret rests, `documentHighlight` fills the
  other uses of the symbol softly behind the text (writes a little stronger),
  in Zed's `editor.document_highlight.read/write_background` when the theme
  has them. Views only for the viewport, placed under the text view's content
  (no text-storage attributes, like squiggles); cleared on edits; a lone hit
  isn't drawn; moving within a highlighted use doesn't ask again.

Opening a location now puts the caret at its column (`Workspace.open(_:)`,
`pendingReveal` has a column), also for go to definition. The commands live in
the Languages plugin and read the caret through `EditorSelectionProviding.caret`;
only the highlights are the editor's. The real-server tests check references
across files, highlights, the outline's nesting and project search for Swift
and every TypeScript setup.

### D63. The bottom area has tabs, and the status bar opens its panels
With Problems and References next to Terminal, the bottom area showed one
panel with no way to see or switch to the others but shortcuts. Now it has
a header row: a tab per panel with its count (Problems: errors in red, else
warnings in orange; References: the uses found), the shown panel's own
controls after a divider (the terminal's session tabs and +, moved up from
their own row, so the terminal loses no height), and Hide (chevron) on the
right. The status bar starts with a button per bottom panel (icon and count,
tinted while shown) that opens or hides it, like Xcode's debug-area toggle,
so they're reachable with the area closed. Plugins give a panel a `badge`
and an `accessory` in `PanelContribution`.

Addendum (D62): every installable server is checked too. `make
test-language-installs` now also asks each one for its file's outline (all 17
answer, names and nesting checked where they nest: Python, HTML, Svelte) and
for highlights where a symbol is used twice (C, Go, Python, Lua, Bash, PHP;
JSON, YAML, TOML, Markdown, CSS, Dockerfile, Terraform and Svelte templates
have nothing to highlight). Python, Go and Rust got a second file: Find
References from a call reaches the method's declaration there, and ⌘T finds
the type. Other languages' references aren't checked (one-file projects).

### D64. ESLint and Tailwind run beside a file's language server
A file had one server, so a TypeScript project showed no ESLint problems and
no Tailwind class completion. Now the server table has **companions**: tools
that serve a file type alongside its language server, started only when the
file's project uses them (looked up from the file towards the folder, so
monorepo packages count):
> **Superseded in part by D65: Orbit no longer looks for ESLint or Tailwind configs; a companion starts when a package.json on the way up depends on it, and the server finds the config. The monorepo addendum (npx, two levels down) is gone too.**

- **ESLint** (`eslint-lsp`, vscode-eslint's server): an ESLint config
  (`eslint.config.*`, `.eslintrc*`, `eslintConfig` in package.json) *and*
  ESLint in a node_modules on the way up. It runs the project's own ESLint, so
  its rules and plugins apply. The server has no defaults, so Orbit answers
  `workspace/configuration` with what VS Code sends (validate on type, working
  directory "auto" for monorepos, flat config when the root has one) and
  approves `eslint/confirmESLintExecution` itself. Its fixes and "disable for
  this line" come through ⇧⌘A; formatting stays with the formatter (D60).
- **Tailwind CSS** (`tailwindcss-language-server`): a `tailwind.config.*` or
  `tailwindcss` in a package.json's dependencies (v4 has no config file).
  Class completion inside `class`/`className`, the CSS behind a class on hover,
  its lint.

Merging: problems from every server (the Problems panel merges them by file),
completion lists joined (each item remembers its server for resolve; a
trigger character goes only to the server that declared it), hover joined
(the language server's first), code actions joined (run by the server that
offered them). Definition, references, rename, symbols, signature help and
formatting stay the language server's. The status bar lists them after the
language ("TypeScript · ESLint · Tailwind CSS", dimmed while not running,
why in the tooltip). A missing companion is offered above the editor like a
missing language server, saying why ("This project uses ESLint…"); Not Now
stops it. `make test-language-installs` runs both against npm's ESLint 9
and Tailwind 4: the project's rule and its fix, class completion and hover.

Found on the way: formatters were given the file's path as opened, while
they run in the folder's real path; ESLint then calls the file "outside of
base path" and silently doesn't fix it (any folder opened through a
symlink). Formatters now get the real path.

Addendum (D54, D64): monorepos. pnpm doesn't hoist TypeScript to the root,
so a workspace with it only in `apps/*/node_modules` fell back to npx, which
npm refuses to run in a project whose `devEngines` names pnpm
(EBADDEVENGINES). The project's TypeScript is now also looked for in
workspace packages (two levels down), and npx runs outside the folder
(`AgentCommand.workingDirectory`). Tailwind 4 counts as used when a
package.json names only its build plugin (`@tailwindcss/vite`, `/postcss`).

### D65. Language support is data; servers understand projects, Orbit doesn't
Context: every bug in D54/D64 so far was Orbit guessing on a tool's behalf —
where a pnpm monorepo keeps TypeScript, whether Tailwind 4 is used without a
config, which ESLint config applies, whether npx may run (`devEngines`).
Each fix was Swift code for one tool, and the list never ends: every language
has its own version managers, virtualenvs and plugins. Meanwhile the servers
we run already do this discovery themselves (the same code VS Code uses,
written by the tools' authors) and do it better than our copy.

Decision — a thin client. The split of responsibility is:
- **Orbit installs and launches.** Servers come from Mason into our own
  folder (D57), or from the project's toolchain where the server must match
  it. No npx, never the project's package manager.
- **The server understands the project.** Orbit passes the root and the
  default settings VS Code sends; it does not look for tool configs itself.
- **Every server is a data entry**, not Swift code. Four generic mechanisms
  cover all languages, none of them tool-specific:
  1. *Install*: a Mason package (binary, arguments, what it needs).
  2. *Root markers, from the file*: the server runs in the nearest folder
     with one of its markers (`Cargo.toml`, `go.mod`, `pyproject.toml`,
     `package.json`, …). This is monorepo support for every language at once.
  3. *Launch sources, in order*: a binary in the project (nearest
     `node_modules/.bin/tsc` for TypeScript 7), then Orbit's Mason copy (the
     user installed it on purpose), then one already on the machine (the
     login shell's PATH, so mise / asdf / rbenv work; `xcrun`). Toolchain-bound
     servers (TypeScript 7, Swift, Dart, Haskell, OCaml, Ruby) are entries like
     any other, not special cases.
  4. *Project environment*: the nearest root's `.venv/bin` and
     `node_modules/.bin` are prepended to the server's PATH, so e.g. pyright
     sees the project's interpreter.
  Companions (D64) start by one generic rule: the file type plus "a
  package.json on the way up from the file depends on package X (or its
  `@X/` scope)". It only saves processes; correctness is the server's (ESLint
  and Tailwind stay idle in projects that don't use them). ESLint plugins
  alone (`eslint-plugin-*`, as oxlint projects have) don't count.
- **Breadth comes from importing, not writing.** nvim-lspconfig already
  describes 300+ servers in exactly these fields (command, file types, root
  markers, default settings). It is converted into our format the way Mason,
  the ACP registry and Zed's queries are reused; entries with Lua logic are
  rewritten by hand or skipped. Our own table shrinks to overrides for the
  main languages and the companions; `.orbit/settings.json` overrides any
  entry per project. (To check before importing: the license and how much
  converts without hand work.)
- **What is promised.** A short list is tested against real servers (D55):
  TS/JS, ESLint, Tailwind, CSS, Swift, Python, Rust, Go. The rest works "as
  in Neovim": usually well, without our guarantee. We don't chase tools.
- **Project setup is not the IDE's job.** clangd needs
  `compile_commands.json`, Java a JDK, Haskell a matching GHC: Orbit shows
  the server's own message, and the agent is the escape hatch ("set up
  language support for this project" writes `.orbit/settings.json`).

Rejected: hosting VS Code extensions (a Node extension host and a large API
surface — not light), Zed's WASM extensions (D54), and continuing per-tool
detection in Swift.

Consequence: the D54/D64 detection code (config lookups for ESLint and
Tailwind, walking monorepos for TypeScript, the npx ladder) is to be removed
rather than extended. Order: (1) the data format with root markers, launch
sources and project environment, current servers moved into it; (2) the
nvim-lspconfig import; (3) "ask the agent" when a server fails to start.

Step 1 done: `LanguageServerConfig` is a `Codable` value (no closures):
file types, root marker groups, launch sources (`project` / `installed` /
`path` / `xcrun`), install, `usedWith`, settings (with `${rootUri}` /
`${rootName}`). Servers are keyed by config and root, so one folder can run
two rust-analyzers or one TypeScript per JS monorepo (lockfile). Removed:
ESLint / Tailwind config lookups, the monorepo walk for TypeScript, npx and
`AgentCommand.workingDirectory`. A project without TypeScript now runs
Orbit's typescript-language-server (offered like any missing server) instead
of npx's TypeScript 7. Found on the way: ESLint's server reads
`settings.experimental.useFlatConfig` without a check; an empty
`experimental` lets ESLint 8.57+ choose flat or legacy config itself, so
Orbit no longer looks for the config. Verified on a pnpm monorepo with
TypeScript 7 in a package and Tailwind 4 via `@tailwindcss/vite`.

Step 2 done: `make import-lspconfig` runs `scripts/import-lspconfig.py` on
pinned nvim-lspconfig (Apache-2.0), Neovim's file-type table (Apache-2.0),
GitHub Linguist's languages (MIT) and Mason's registry, and writes
`OrbitLanguages/Resources/Servers.json` (committed; bump the pins and read
the diff to update). The script only reads the Lua, never runs it: a field
counts when it is plain data, plus two common shapes — `root_pattern(...)`
for roots and "the project's node_modules/.bin copy, else the global one"
for commands (our `.project` source). 327 of 420 servers convert; the rest
need code (Java's `-data`, C#'s NuGet install) or have no file types Orbit
can match (spell checkers, assistants for every file). Java (jdtls, with
`${dataDir}` under `~/.orbit/languages/data`) and C# (csharp-ls) got entries
of our own instead.

Which server a file gets: ours if one serves it (ours replace the imported
entry of the same lspconfig name and take over the files only it knew:
`go.mod`, `.c++`); else the imported ones ranked for the extension by the
script — the usual choice first where a language has several (`PREFERRED`,
what VS Code's and Zed's extensions run), then installable from Mason, then
the narrower server. Linters, formatters, spell checkers, assistants and
servers for one framework (`NOT_A_DEFAULT`: Ruff, Biome, Harper, GitHub
Actions in YAML…) are never a file's server. At runtime the first candidate
already in the project, installed by Orbit or on the machine wins; else the
first is offered for install. Settings → Languages lists ours, and imported
ones once installed or found (all of them would be hundreds of rows).

Step 3 done. `"languageServers"` in `.orbit/settings.json` (the project's,
then `~/.orbit/settings.json`), keyed by file type like `"formatters"`: a
server's name (Orbit's id or nvim-lspconfig's), `"off"`, `{ "server", … }` or
`{ "command", "arguments", … }`, both with `settings` and
`initializationOptions` merged over the server's own. A rule that can't be
followed (unknown name, invalid JSON) becomes a server that doesn't start and
says why in the status bar, never a quiet fallback (as with formatters, D61).
Editing either file restarts the servers. The status bar's language item has
a context menu: the file type's other servers (ranked), None, back to
Orbit's choice, Edit Settings File; a choice is saved in the user's file (a
personal preference; the project's file is for what a repo wants for
everyone). A file type turned off shows "<language> off" there.

When a server can't run (missing, failed, install failed), the alert offers
"Ask Agent to Set Up": a new chat with a task in its composer — the file type,
what Orbit tried, the error, and the two ways out (install what's missing, or
a `languageServers` rule in the project's settings) — for the user to read and
send. It goes through a new service, `AgentTasks` (OrbitAPI), implemented by
the Agents plugin.

### D66. Fixes in the hover card; ⌥Esc opens completion

From the first pass over the LSP features on a Mac. Hovering a problem also
asks for its code actions: up to three quick fixes (preferred first) are links
in the card, with "More Actions… ⇧⌘A" for the rest, as in VS Code. The card
stays open while the pointer crosses the gap to it, so they can be clicked.

Completion opens on Esc (STTextView's own cancelOperation, as in Xcode) and
⌥Esc as well as ⌃Space: macOS takes ⌃Space for switching input sources when
there are several (a Russian layout), and the key never reaches Orbit.

Addendum: Esc opening the list (a full one, with nothing typed) surprised on
the first try, so Esc only closes things again; ⌥Esc (macOS's own complete:)
and ⌃Space open it.

Clicking the language item in the status bar toggles the Problems panel
(it went to the next problem, which looked like nothing with one).

### D67. Features are found in a right-click menu, and their shortcuts are taught

The first pass on a Mac showed most language features were invisible: known
only from the docs, behind three- and four-key shortcuts. Four layers, none of
them a permanent bar in the window:

1. **The editor's right-click menu** lists what applies here, above Cut, Copy,
   Paste, each with its shortcut drawn: Go to Definition, Find References;
   Rename, Fixes and Actions, Format Document; Ask Agent About This; Keep / Undo
   Change on an agent's hunk. Any plugin's command can be there:
   `OrbitCommand(editorMenu: EditorMenuPlacement(group, title:, isVisible:))`.
   `isVisible` is asked each time the menu opens (it may read unobservable
   state, unlike `isEnabled`); language items show only with a server.
2. **A command run by mouse shows its shortcut** for two seconds in a capsule
   at the bottom of the window: picked from a menu (not by its key), the
   palette, the right-click menu, or a button that runs a command
   (`commands.run(id, teaching: true)`, `commands.teach(_:)`).
3. **Every shortcut in one place**: the keyboard button at the end of the
   status bar opens a popover with all of them by category (the registry's,
   plus the palette and Settings) and the mouse gestures; also Help →
   Keyboard Shortcuts. It first opened while ⌘ was held alone, but holding ⌘
   is how a ⌘-click is aimed, so it moved to a button.
4. **Keys inside the popups**: the hover card on a symbol ends with
   ⌘-click / ⇧⌘R / ⌃⌘E, the completion list with ↑↓ / ↩ ⇥ / ⎋.

Tooltips name what an icon button does and, when a command does the same,
its shortcut (`commands.help(id)`, "Show Problems (⇧⌘M)"); panels name the
command that shows them (`PanelContribution.command(id)`), so the sidebar
switcher, bottom tabs and status-bar toggles say their keys. New keys for
what had none: Toggle Sidebar ⌃⌘S (macOS's), Toggle Agents ⌥⌘I (an
inspector, as in Pages), Show Explorer ⇧⌘E (VS Code's).

With ⌘ held, the symbol under the pointer is underlined in the link color
and the pointer becomes a hand, once the server confirms a definition there
(as in VS Code), so the ⌘-click is seen before it's made.

Find References moved from Xcode's ⇧⌃⌘F to ⇧⌘R, beside ⇧⌘O (symbols),
⇧⌘A (actions) and ⇧⌘M (problems). Other Xcode keys stay (⌃⌘J, ⌃⌘E);
New Isolated Agent Session keeps ⌥⇧⌘N, as the ⌥ variant of ⇧⌘N.

### D68. The hover card sits over the line, as in VS Code

An NSPopover under the word (arrow, centered on it) read as a system
balloon and covered the next lines being read. Now it's a borderless
floating panel (`HoverPanel`, like the completion list): no arrow, above the
line with its left edge at the word, below only when the editor has no room
above. Sections split by lines: the problems (with their source dimmed), a
bar of fixes and "Quick Fix… ⇧⌘A" on a faint fill, the server's symbol info,
then the keys. Taller than 420 pt it scrolls. It closes when the caret moves,
on typing or scrolling, and when the pointer leaves it for anywhere but the
word; clicked into, it takes keys so its text can be copied.

### D69. Embedded languages are layers parsed by the highlight worker

CSS and JS inside HTML and Vue, code blocks and inline text in Markdown,
CSS in `css`/`styled.x` tagged templates are colored by their own grammar,
the way Zed's syntax map does it. The highlight worker (D48) keeps, beside
the file's tree, a list of layers: an embedded language's piece of the text
with its own tree, up to three levels deep (HTML in a Markdown paragraph in
a doc comment). Each layer's captures paint over the file's; `@none`
(Markdown's code block contents) clears the file's color under it. Capture
names of every language share one numbering (`CaptureTable`), so the
main-thread highlight cache and painting didn't change.

- Where to look: the grammar's `injections.scm` (installed grammars fetch it
  next to `highlights.scm`; the install layout went to 2, so older installs
  are redone once); the built-in grammars get a few patterns of ours
  (`BuiltinInjections`) since the bundled files aren't reachable and nvim's
  need predicates we don't run. Both Zed's (`@content`, `@language`) and
  nvim's (`@injection.*`) names work; `#offset!` trims template backticks.
- A language is found by the name the file gives it: a fence's info string
  (`js`, `TypeScript`, `{.python}`), `#set!`'s value, Vue's `lang`. Aliases
  map to a file extension; an installable grammar that's missing is
  installed in the background (Markdown's inline grammar on the first
  Markdown file), then the layers are looked for again.
- After an edit only the changed text is searched again: the edit's lines
  and tree-sitter's changed ranges, widened to whole top-level layers and to
  each layer's whole match (a fence with its language line). Layers
  elsewhere keep their trees; one found again replaces what overlapped it.
- Small layers (≤ 16 KB) are parsed afresh after an edit: Markdown's inline
  grammar parsed incrementally ends up with a different tree than a fresh
  parse in about half of random edit runs. Bigger ones (a long `<script>`)
  are parsed incrementally.
- SwiftTreeSitter's `changedRanges(from:)` takes the receiver as the *old*
  tree; calling it on the new one (as the file's own reparse did since D48)
  missed structural changes such as a fence closing.
- Checked against a fresh highlight after thousands of random edits on
  Linux (HTML, JS, CSS and Markdown grammars from upstream standing in for
  the bundled ones, plus Vue and Markdown inline); unverified on a Mac.

### D70. Inlay hints are room in the text plus labels over it

Types and parameter names from the server (`textDocument/inlayHint`) are
shown between characters, on by default (Settings → Editor, and a command).
The text isn't touched: the room for a label is a `.kern` on the character
before it, a text-storage attribute like the inline diff's gaps (D24), so
it's not in the text, undo or the file; the label is a small view in that
room, on a capsule in the theme's hint colors, made only for the viewport.

- Hints are fetched for the viewport and a screen around it, again after
  typing pauses and on the server's `workspace/inlayHint/refresh`. Until
  fresh ones arrive, edits move the old ones with the text.
- TextKit 2 splits a kern in half around the caret position but draws the
  next glyph after all of it; the label is placed from the glyph, not the
  caret rect.
- The server side runs in `make test-languages` (Swift, TypeScript); the
  drawing is unverified on a Mac.

