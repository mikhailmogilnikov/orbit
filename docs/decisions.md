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
below it. Don't fight AppKit chrome.

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
