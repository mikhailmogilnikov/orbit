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
- D36. Settings as a page in the main window — layout → D158
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
- D58. Extra grammars are compiled lazily, with Zed's highlight queries — list → D71
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
- D69. Embedded languages are layers parsed by the highlight worker — lookup → D71
- D70. Inlay hints are room in the text plus labels over it
- D71. Syntax highlighting is Zed's languages, imported; nothing built in
- D72. Our server entries only where we know more than nvim-lspconfig
- D73. ⌘/ and bracket pairs come from Zed's language configs
- D74. Vue: tsserver with Vue's plugin, Vue's server beside it
- D75. Problems cover the files the agent changed, not just open ones
- D76. Server defaults borrowed from Zed: settings pushed, Tailwind at-rules, TS memory
- D77. Servers hear about files changed on disk
- D78. Unused code is faded, deprecated code struck through
- D79. Code folding: server regions or indentation, lines hidden by TextKit 2
- D80. The editing session comes back: tabs, caret and scroll, folders, layout
- D81. Code actions on save; companions configured in `.orbit/settings.json`
- D82. Sticky scroll and a path bar instead of an outline panel
- D83. Typing follows the file's indentation
- D84. Overview ruler under the scroller
- D85. Restore files to before a message
- D86. MCP servers for every agent from `.orbit/settings.json`
- D87. Notifications and a Dock badge for agents in the background
- D88. Queue messages while the agent works
- D89. Image / PDF viewer and Markdown preview (Preview plugin)
- D90. Split editor: two groups, the tab row split along the same line
- D91. Drag and drop of tabs and files (Cursor-style)
- D92. Moving files between folders in the explorer
- D93. Rename, new file / folder, delete and undo in the explorer
- D94. Preview tabs: a click in the explorer reuses one tab
- D95. The explorer's context menu: Cursor's useful items
- D96. Explorer folders: selected on click, gray, toggled reliably
- D97. The accent comes from the color theme, never the system blue
- D98. Getting around by keyboard
- D99. Go Back / Go Forward and the ⌃Tab recent-tab switcher
- D100. Dock menu and Open Recent: recent folders
- D101. A window per project; the welcome window
- D102. Close Folder; folders from Finder and the Dock
- D103. Tab rows measure their width outside the scroll view
- D104. The editor column cancels the sidebar's inherited safe-area inset
- D105. Text editing basics: line moves, multiple carets, Go to Line, bracket match, zoom
- D106. Files keep their encoding and line endings; binary and huge files aren't opened
- D107. Shortcuts can be reassigned in Settings → Keyboard Shortcuts
- D108. Editor and agent options in `.orbit/settings.json`
- D109. The isolated-copy sweep leaves this run's copies and other processes alone
- D110. Indent guides, Find in Folder, Compare Files, terminal find and font
- D111. Side-by-side diffs, replace undo, explorer multiple selection, Peek References
- D112. Performance and memory pass: review cache, git refresh coalescing, streaming Markdown
- D113. Second performance pass: shadow-git queue, cancelled searches and diagnostics pulls
- D114. Third performance pass: media reloads, tool-card diffs, line starts
- D115. Slash commands in the composer; a live working line and a turn summary
- D116. Reads and searches in a row fold into one transcript line
- D117. One type scale for the UI (`Font.orbit`)
- D118. Tool cards open their files; permissions by keyboard; other chats' approvals shown
- D119. Changed files name their chat; an empty chat lists what the composer takes
- D120. The chat catches up with Claude Code: pinned plan, timed thoughts, Esc / ↑ / ⇧Tab, mode in view
- D121. Output follows only from the bottom of the transcript
- D122. Tool calls fold like Claude Code: quiet lines, runs as "Ran 4 commands"
- D123. Explorer folders open and close without animation
- D124. The usage popover: context first, plan limits for Claude and Codex, remembered
- D125. Review comments: notes on agent changes in the editor, sent to the chat together
- D126. The open folder is watched: changes made outside Orbit show up by themselves; the window title is the project's name
- D127. ⌘K edits the selection with a hidden agent; the result is an inline agent change
- D128. Tasks: the project's scripts run from a picker, each in its own terminal tab
- D129. Releases: Sparkle updates from GitHub Releases; ad hoc signing until a Developer ID
- D130. All agents at a glance: an overview of every window's chats; Allow / Deny in notifications
- D131. Queued messages and review notes survive a relaunch
- D132. Rewind: the chat goes back with the files
- D133. Isolated sessions become pull requests
- D134. Merge conflicts are resolved in the editor
- D135. Blame for every line, beside the line numbers
- D136. History of any branch, searchable, with a graph
- D137. Tasks' errors go to Problems and the editor
- D138. Running tasks in the status bar; tasks of monorepo packages
- D139. Box selection by ⌥-drag
- D140. Format Selection: the whole file formatted, only the selection's changes kept
- D141. Large files open in a light mode
- D142. `orbit` in the terminal opens folders and files
- D143. A built-in browser for dev servers, in editor tabs
- D144. Later agent turns are pushed to the pull request
- D145. SVG opens as its picture; Show Source flips the tab to the code
- D146. Image thumbnails beside the line numbers
- D147. Fix with Agent from the Problems panel
- D148. ⌘-click a path in the terminal opens it in the editor
- D149. Color swatches beside the line numbers, edited with the color panel
- D150. Copy GitHub Link and Open on GitHub
- D151. Text transforms: sort, dedupe, reverse lines; change case and naming style
- D152. Images pasted into Markdown are saved in assets/
- D153. The Mac stays awake while an agent works; a sound when one finishes
- D154. A stash's files and diffs in the Source Control panel
- D155. The terminal's editing keys, as in Terminal.app and iTerm
- D156. History rows on two lines; one badge per branch; a calmer graph
- D157. Corner, fill and badge tokens in `Theme`
- D158. Settings laid out like System Settings: groups, tiles, header cards, pages
- D159. System empty states; numbers and symbols animate like Apple's apps
- D160. The welcome screen laid out like Xcode 26's welcome window
- D161. Command palette and Open Quickly look like Spotlight
- D162. Alerts and open panels are sheets on the window
- D163. The chat: Claude Code's flow, Apple's look
- D164. Editor overlays are kept between layouts, not rebuilt
- D165. The everyday build is optimized
- D166. The empty editor: quiet, like Xcode's "No Editor"
- D167. Terminal sessions are a list beside the output
- D168. Tabs like Xcode 26 and Safari 26
- D169. The sidebar switcher is Xcode's navigator bar
- D170. A quieter status bar
- D171. Source Control looks like Xcode's navigator
- D172. Problems and References read like Xcode's issue navigator
- D173. Editor popups are Liquid Glass
- D174. Quieter details: plain output, empty panels, a lone chat, VoiceOver names
- D175. The shortcuts popover is a searchable list you can rebind from
- D176. The menu bar is laid out like Xcode's
- D177. Settings search finds options, not just panes
- D178. Settings → Terminal and Settings → Files
- D179. A page per agent; options a project sets carry a Project badge
- D180. Code font family, default indentation, auto save
- D181. Text sizes: interface, chat, code, terminal
- D182. A JSON Schema for settings.json; the JSON server validates
- D183. Setting an option for the project from Settings
- D184. Plugins: steady tiles, a way to their settings, Restart Now
- D185. Settings → Checkpoints: disk use and keeping snapshots
- D186. Automatic updates; a switch per language server
- D187. Blame after the caret's line, as GitLens; the column is gone
- D188. Line height, ligatures, a switch for closing brackets
- D189. File history, line history, comparing with a branch or commit
- D190. Clickable things are in the text color, not the theme's accent
- D191. The terminal has the editor's background
- D192. One Extensions page for everything that can be installed
- D193. npx agents start outside the project; exits say why
- D194. Plugins turn on and off live, require each other; Git Lens and Browser split out
- D195. Extensions bring snippets, agents, language servers and tasks; the Extensions page lists packages
- D196. Blank chats stay out of Recent, even when the agent lists them
- D197. A click anywhere on the selected folder's row toggles it
- D198. Problems also check the files that use what the agent changed
- D199. Server edits create, rename and delete files; rename can be previewed
- D200. Call and type hierarchies in a bottom panel
- D201. Semantic tokens over tree-sitter's colors; code lenses after the line
- D202. Every caret gets the typing rules; linked tags, Expand Selection, squiggles that move
- D203. Formatters in a row from settings; format on type
- D204. Remote branches in History; a file at a commit, with its blame
- D205. A first-launch tour: a short film, four setup steps, one closing line
- D206. GPL-3.0, and the files an open-source repo is expected to have
- D207. Dependencies' licenses in About Orbit

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
The snapshots double as restore points for each message (D85).

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
Keyboard Shortcuts and Plugins. (Sidebar groups, tiles and panes redone in D158.) Options more than one plugin reads (theme, the
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
showed as a grey plate over the start of the tab row. (Later the keeper shows it in full screen too, with the toolbar window made
clear.) There the revealed traffic lights ignored clicks, which went through
to the window below: a click on a button's spot is caught by a local event
monitor and closes the window or leaves full screen itself. The system sidebar
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
> **D201: semantic tokens now recolor what tree-sitter can't tell (types, parameters, properties).**

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

Note: the hand-written list and the built-in grammars are gone (D71): every
language comes from Zed's catalog, installed the same lazy way.

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
  > **D199: ⇧↩ previews it first; file operations in edits are applied.**
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
  > **D75: also the files the agent changed, open or not.**

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

Note: `BuiltinInjections` and the alias table are gone (D71): every language
has Zed's `injections.scm`, and an embedded language is found as Zed finds it.

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

### D71. Syntax highlighting is Zed's languages, imported; nothing built in

Context: highlighting had three hand-made layers — 20 grammars linked into
the app (STTextView-Plugin-Neon's, with their nvim-style queries), a list of
10 grammars installed on demand (D58), and our own injection patterns and
language aliases (D69). Language servers covered ~230 file types (D65); about
190 of them had no colors (Astro, Elixir, Nix, Haskell, Scala, Dart…).
Adding grammars by hand doesn't scale, and every built-in one was a second
source of truth next to Zed's queries, which already set the capture names
our themes (D48) style.

Decision — Zed's languages are the only source, converted like
nvim-lspconfig's servers (D65): `make import-grammars` runs
`scripts/import-grammars.py` on pinned commits of Zed (its own languages:
`crates/grammars/src/*/config.toml`, grammar versions from Cargo.toml /
Cargo.lock) and of its extension catalog (each language extension's
`extension.toml` and `languages/*/config.toml` at the catalog's submodule
commit; Zed's API only says which extensions have languages and their
downloads). It writes `OrbitAPI/Resources/Grammars.json`: ~520 languages and
the grammars they use. Nothing of theirs is bundled, only where to fetch it.

- A *language* is a name, file suffixes, a first-line pattern and URLs of
  Zed's `highlights.scm` / `injections.scm`; a *grammar* is a repository at a
  commit, a folder and the exported symbol. Languages may share one (JS is
  parsed with TSX's grammar, JSONC with JSON's, `.env` with Bash's); compiled
  grammars live in `~/.orbit/grammars/lib/` and are shared.
- A file's language is picked as Zed picks it: the longest matching suffix
  (`tsconfig.json` → JSONC over `.json`), ties to the earlier language (Zed's
  own, then extensions by popularity), else the first line (shebangs). So
  `.mdx` is Markdown, as in Zed. An embedded language (injection, code fence)
  is found by name or suffix, any case, then modeline aliases.
- Every language installs lazily (D58's mechanism): the first open of a
  TypeScript file now compiles TSX's grammar (a second or two, once). When a
  folder opens, the languages of its files are installed one by one in the
  background, from the Search plugin's file list (`ProjectFileIndex.allPaths`).
  Old installs (layout < 3) and unused libraries are pruned at launch.
- The importer checks what the app will fetch: each grammar's commit (crates
  sometimes name a commit never pushed — then the release tag's; if the
  repository is gone, the published crate archive, as for Diff), each query
  URL (symlinked query files are resolved: raw GitHub serves a link's target
  path, not the file). Left out: repositories that vanished (Jai), queries
  that can't be fetched (FSharp, SysML), and two extensions whose queries
  don't fit their own grammar (`BROKEN_LANGUAGES`).
- Git LFS smudging is off when fetching a grammar (some repositories keep
  fixtures there; the parser never is).

Rejected: keeping the built-in grammars for instant first open (two sources
of truth, nvim capture names, a dependency); nvim-treesitter or Helix as the
source (capture names differ from our Zed themes; Zed covers what our
servers need); Zed's wasm grammars (a wasm runtime in the editor, D58).

Cost: the first file of each language opens uncolored for a second or two,
and a Mac without network or Xcode's command line tools gets no colors at
all. `make test` installs Swift, Markdown, JS, CSS and HTML into the temp
folder on its first run (network). `make test-language-installs` installs
all ~520 languages, loads each grammar and compiles its queries (~5 min);
all pass.

### D72. Our server entries only where we know more than nvim-lspconfig

JSON, CSS, HTML, YAML, Shell, Markdown, TOML, Dockerfile, PHP, Zig, Svelte
and Terraform had entries of ours that said what the imported ones (D65)
already do: the same server ranked first for their files, the same Mason
package, `node_modules/.bin` first where lspconfig has it. They are removed;
those files get the imported entries. Kept: Swift and C (Xcode's tools), TS
(the project's TypeScript 7, tsserver preferences), Python and Rust (root
markers lspconfig writes as Lua), Go and Lua (inlay hints on), Ruby, Java,
C# (installs Orbit can't do, `-data`), and the companions.

Lost on the way: `.zsh` and `.tfvars` have no server (lspconfig doesn't map
them); Settings → Languages shows the removed ones only once installed or
found, like every imported server. Server ids changed to lspconfig's names
(`cssls`, not `css-lsp`): a `languageServers` rule naming an old id needs
the new one.

Also (D65's import): servers built on tsserver (Astro, MDX) whose lspconfig
entry finds TypeScript in a `before_init` get `typescript.tsdk =
${typescriptSdk}`: the project's `node_modules/typescript/lib` from the root
up (skipping TypeScript 7, which has no tsserver library), else the one
installed with the server, else typescript-language-server's.

### D73. ⌘/ and bracket pairs come from Zed's language configs

The grammar import (D71) also takes each language's `line_comments`,
`block_comment`, `brackets` (those with `close`) and `autoclose_before` into
`Grammars.json`, so editing rules exist for every language with nothing
written per language (`EditingRules`).

- ⌘/ (Code → Toggle Comment, also in the editor menu): the selected lines get
  the first line comment at their common indent, or lose any of the
  language's markers (longest first: `///` before `//`) when all have one.
  Without a line comment (HTML, CSS) the lines are wrapped in a block comment.
- Typing an opening bracket or quote adds the closing one, as Zed does: only
  before whitespace, the end or an `autoclose_before` character; not a quote
  right after a letter or digit (apostrophes). Multi-character openers (`/*`,
  `"""`, `f"`) close on their last character. With a selection, the pair
  wraps it. Typing a closing character in front of the same one steps over
  it; Backspace inside an empty pair removes both.
- Zed's `not_in` (no pairs inside strings and comments) isn't followed yet:
  it needs the capture under the caret.

Also: file icons come from the icon theme everywhere (the chat's attachment
chip was the last SF Symbol by extension); `FileIcon.systemImage` is only the
fallback symbol.

### D74. Vue: tsserver with Vue's plugin, Vue's server beside it

Vue's server (3.x) no longer answers for TypeScript: it sends
`tsserver/request` notifications and waits for `tsserver/response` from its
client, which runs them on a tsserver that loads `@vue/typescript-plugin`.
The imported `vue_ls` entry ran it alone, so every request in a `.vue` file
hung.

- `.vue`'s language server is `vue`: typescript-language-server (the project's,
  else Orbit's) with the plugin from beside Orbit's Vue server (versions must
  match), else the project's. It answers the component's TypeScript, in the
  script and the template's expressions: completion, hover, navigation,
  problems.
- `vue-language-server` is a companion (D64) for projects depending on `vue`
  or `nuxt`: tags, directives, Vue's checks. Its `tsserver/request`s go to the
  `vue` server of the same root (`typeScriptServer`) through
  `typescript.tsserverRequest`; with none running each gets a null body, never
  silence.
- tsserver leaves `.vue` files unformatted, so server formatting goes to the
  companion (`formatsWith`).
- Installing a package restarts every server using it (TypeScript and Vue
  share typescript-language-server) and the tsserver loading a plugin from it.

Also: `workspace/configuration` answers null, not `{}`, for an unset dotted
section (Astro iterated `html.customData`'s `{}` and crashed); a whole
section still gets `{}` (the CSS server fails on null). `shutdown` and `exit`
go without `params` (TypeScript 7 rejected `"params": null` and kept running).
A crashed server's message shows the stack's error line instead of its last
frames.

### D75. Problems cover the files the agent changed, not just open ones

An agent edits a dozen files per turn; errors showed only in the ones the
author happened to open. Servers can't be relied on to check a whole project:
LSP's workspace diagnostics are rare (Pyright has them behind
`diagnosticMode: workspace`, slow on big projects; tsserver has none).

- Every file the Review plugin tracks as changed (`ChangeTracking.changedFiles`)
  is opened on its servers in the background with its text from disk, re-read
  when the workspace's `fileSystemGeneration` moves. Its servers start for it
  like for an open file, and its problems join the Problems panel.
- After review (keep or undo) a file stays checked while it still has
  problems, so keeping broken code doesn't hide the errors; it drops out once
  they're fixed. At most 100 files.
- Problems a server pushes for files nobody opened (rust-analyzer's
  `cargo check`, gopls) were already kept and still are.

Not covered: files the agent didn't touch but broke (an importer of a changed
module) unless the server reports them on its own.

> **Covered since D198: the users of changed files are checked too.**

### D76. Server defaults borrowed from Zed: settings pushed, Tailwind at-rules, TS memory

A Svelte + Tailwind v4 project showed problems VS Code and Zed users don't
see or know to silence. Zed's language adapters (GPL: ideas and values
taken, no code) were read for what they set up that we didn't.

- **Settings are pushed after `initialized`** (`workspace/didChangeConfiguration`
  with the whole settings object), as VS Code and Zed do. Svelte's server
  never asks for its settings, so it ran with none; the others ask again.
- **Tailwind projects ignore unknown CSS at-rules** (`css/scss/less.lint.
  unknownAtRules: ignore`) on every server that runs the CSS service (CSS,
  Svelte, Vue, Astro, HTML) when the root's package.json depends on
  Tailwind: `@apply`, `@reference`, `@theme` are Tailwind's, and its own
  server checks them. Zed doesn't do this (its Tailwind CSS server fork is
  opt-in); VS Code users set it by hand. Project settings win.
- **TypeScript:** tsserver gets 8 GB (`maxTsServerMemory`; the 3 GB default
  runs out on big projects) and functions complete with their parentheses
  and argument stops (`completeFunctionCalls`), like Zed. Inlay hints stay
  ours (quieter than Zed's all-on).
- **Problem messages** set names and types in code type (`'x'` from
  TypeScript, Swift, Svelte; `` `x` `` from Rust), like Zed's
  `diagnostic_message_to_markdown`. The Problems panel joins the lines
  around blank ones, so "Error in svelte.config.js\n\n<cause>" shows the cause.
- **Completion takes the snippet from `completionItem/resolve`**:
  typescript-language-server adds a function's parentheses there, not in the
  list. Only the text: the range stays the list's (Zed found the resolved one
  stale once more was typed). Accepting before the resolve lands inserts the
  plain name.
- **A problem whose range is only a line break** (Python's missing `:`, from
  the end of a line to the start of the next) is underlined at the line's
  last character; it was invisible.
- **Type hints that start with `:` drop their left padding**
  (typescript-language-server pads them: `foo : boolean`).
- **A crashed server starts again**, up to 4 times in 3 minutes (VS Code's
  client's budget); after that it stays down with its message until Restart
  Language Servers. Before, a crash left it "running" with no process: every
  request quietly came back empty.
- **Hover and fixes wait at most 1.5 s per server**; a slow companion is
  cancelled, and the card still shows the problem under the pointer.

Taken later: `didChangeWatchedFiles` (D77), fading and strikes (D78).
Not taken: Zed's ESLint setup that reads the ESLint version and config kind
to pick flat/legacy options (ours leaves `experimental` empty, ESLint 8.57+
decides); worth it once an old `.eslintrc` project misbehaves.

### D77. Servers hear about files changed on disk

Agents write files through the shell. tsserver, rust-analyzer, Svelte and
Tailwind watch the disk themselves; SourceKit-LSP, gopls, Pyright, clangd
and ESLint (its config) leave it to the editor, and Orbit told them
nothing: a Swift file the agent created stayed unknown ("cannot find X in
scope") until Restart Language Servers.

- Orbit offers `workspace/didChangeWatchedFiles` with dynamic registration;
  a server registers the globs it cares about (SourceKit-LSP: `**/*`), and
  each burst of changes goes to it filtered by those globs and kinds
  (create / change / delete). LSP globs (`**`, `*`, `?`, `{a,b}`, `[…]`,
  relative patterns) become regexes, matched against the full path and the
  path under the server's root.
- One FSEvents stream per open folder, per-file events, 0.3 s bursts. What
  is on disk decides the kind (FSEvents merges flags). It watches the
  folder's real path (FSEvents doesn't follow a symlinked folder) and maps
  events back under the folder as opened.
- `.git/`, `node_modules/` and `.build/` are skipped: thousands of changes
  per install or build, and SourceKit-LSP's own index build writes into
  `.build/` while it works (echoing those back made it busy for nothing).
  No server we run needs them from us.
- Saves from the editor go out too, as VS Code sends them.

Tested against the real SourceKit-LSP: an error about a type disappears
once a file defining it is written to disk, and stays without the events.

### D78. Unused code is faded, deprecated code struck through

Servers tag problems `unnecessary` (an unused import, variable, parameter;
unreachable code) and `deprecated`, once the client says it understands
tags (`publishDiagnostics.tagSupport`), which Orbit didn't. VS Code and Zed
draw them; the code's state was invisible here (hints get no squiggle).

- **Unnecessary: faded, keeping its syntax colors** at 55% (VS Code's
  opacity is about that). The highlighter paints it: the same rendering
  attributes as the colors, with alpha, so the caret and selection stay
  as they are. An overlay in the background color would have faded those
  too and shown as blocks where the window's glass shows through. Files
  with no grammar don't fade.
- **Deprecated: a 1-pt line through it** in the text color, an overlay
  like the squiggles.
- Their messages show on hover even when they're hints ("'x' is declared
  but its value is never read"), with the server's fixes ("Remove unused
  declaration"). Errors and warnings with tags keep their squiggles.
- Fading follows the server's latest report; after an edit that moves the
  code it may sit a few characters off until the next one (a fraction of a
  second), like the squiggles.

### D79. Code folding: server regions or indentation, lines hidden by TextKit 2

Folding was missing, and it's used every day in long files.

- **Regions come from the language server** (`textDocument/foldingRange`,
  `lineFoldingOnly`); a file without one, or a server with none, folds by
  **indentation**, as VS Code and Zed do: a line opens a region when the
  lines below it go deeper, and it ends at the last of them, so a closing
  brace stays visible. Zed's languages aren't used for this: our grammar
  table carries only highlight and injection queries, and Zed itself folds
  by indentation. Several regions on one line: the outermost. A region
  around the whole file (JSON's root braces, `<html>`) gets no chevron:
  folding it leaves one line.
- **Hiding is TextKit 2's own**: the content storage's delegate skips the
  paragraphs of folded lines (`shouldEnumerate`), so the text, undo, search
  and the server stay untouched, and the caret can't land inside. A
  "⋯" capsule after the header (inlay-hint colors) unfolds on click.
- **A fold is the characters it hides**, so edits elsewhere move it; an
  edit reaching into it or the caret landing in it (go to line, search)
  opens it. A whole-text replace (agent edit, reload) maps folds through a
  line diff, as VS Code does: untouched ones move with their lines, one
  with changed lines inside (or right after it) opens, so the agent's edits
  are never hidden.
- **Folds are remembered per file** (UserDefaults, the last 300 files) by
  header line, as VS Code and Xcode do, and fold again on open once their
  regions are known. When regions refresh,
  a fold whose header no longer starts one opens.
- **Gutter chevrons** between the numbers and the text: open regions show
  theirs while the pointer is over the gutter (VS Code), folded ones always.
- Xcode's keys: Fold ⌥⌘←, Unfold ⌥⌘→, Fold All ⌥⇧⌘←, Unfold All ⌥⇧⌘→.
- **Animated as in Xcode** (0.22 s): the text below slides up over the
  region, or down to uncover it. The real text changes at once; a bitmap
  of the visible part below the header (gutter included) is cut into two
  layers that Core Animation moves, so there's no layout or drawing per
  frame. Fold All / Unfold All, Reduce Motion and headers off screen
  aren't animated.

### D80. The editing session comes back: tabs, caret and scroll, folders, layout

Every launch, every reopened folder and every tab switch started from
scratch: no file tabs, the caret at the top of the file, the tree
collapsed, the panels back to defaults. VS Code and Xcode bring all of it
back. (Agent tabs already did, D28.)

- **File tabs and the active one, per folder** (UserDefaults, relative
  paths), restored on launch and when the folder is opened again; files
  gone from disk are skipped. A tab is only a title until it's shown, so
  twenty restored tabs cost nothing.
- **Caret, selection and the top visible line, per file** (the last 300),
  as line and column, which survive edits made while the file was closed.
  Kept in memory and written when an editor closes and when the app quits,
  never per keystroke or caret move. Coming back scrolls with TextKit 2's
  `relocateViewport`, which estimates the text above instead of laying it
  out. A file opened to a location (definition, search result) goes there
  instead. Folds that come back a moment later (D79) shift the text, so the
  editor scrolls to the line again within the first seconds.
- **Expanded folders in the tree, per folder**, parents first.
- **The window's layout**: sidebar and agents panel shown or hidden, their
  selected panels, the bottom panel and its tab.

### D81. Code actions on save; companions configured in `.orbit/settings.json`

Saving a JS/TS file left ESLint's fixable problems in place (VS Code users
turn on `source.fixAll.eslint` on save), and ESLint and Tailwind couldn't be
turned off or configured per project: only "Not Now" on their install offer.

- **On save, code actions run before the formatter** (VS Code's order), by
  kind, listed per file type in `"codeActionsOnSave"`:
  `{ "ts, tsx": ["source.organizeImports", "source.fixAll.eslint"], "js": [] }`.
  Each kind is asked of every server of the file over the whole text
  (`context.only`, `triggerKind` automatic); the first action of that kind
  is applied. Save waits for them and the formatter at most 3 s.
- **The default is ESLint's fixes alone** (`source.fixAll.eslint`), which
  does nothing where ESLint doesn't run. Import order is the linter's call:
  projects that care have a rule for it (`simple-import-sort`,
  `import/order`, Biome), and ESLint's fixes apply it. TypeScript's own
  Organize Imports sorts by its rules and drops imports not used yet, so
  it's opt-in (`"source.organizeImports"` in the list) and a command,
  Organize Imports ⌃⌥O (VS Code's ⇧⌥O types a letter on a Mac).
- **`"companions"`**, keyed by tool (`eslint`, `tailwindcss`; `tailwind`
  and `vue` work too): `"off"` doesn't start it (and stops offering it),
  `"on"` starts it even when no package.json names the tool, an object
  merges `"settings"` / `"initializationOptions"` over Orbit's defaults
  (`{ "enabled": true | false }` in it does what "on"/"off" do). The
  project's file wins over `~/.orbit/settings.json`, entry by entry.
- Tested against npm's ESLint 9 (`make test-language-installs`): asked for
  `source.fixAll.eslint` over the file, it fixes the project's rule.

### D82. Sticky scroll and a path bar instead of an outline panel

An outline panel (VS Code's Outline, JetBrains' Structure) was next on the
list. It would take room from the explorer or the agents, and ⇧⌘O already
jumps to a symbol faster than scanning a tree. What it really answers is
"where am I in this file", which two cheaper things answer without a panel:

- **Sticky scroll** (VS Code, Zed): the first lines of the scopes the top of
  the view is inside stay pinned above the text, up to five, the innermost
  last; a scope about to end pushes its line up. Scopes are the folding
  regions (D79: the server's, else indentation), comments skipped. One view
  over the editor and its gutter draws them, line numbers included, with
  the highlighter's colors from its cache; nothing in the text changes, and
  it's recomputed once per scroll or layout pass. A click goes to the line.
- **A path bar above the editor** (Xcode's jump bar): the file's folders,
  the file, then the symbols around the caret (`Store › subscribeSelector`)
  from the server's outline (`documentSymbol` ranges; `LanguageSymbol.extent`).
  A folder lists its files (read when clicked), the file its top-level
  symbols, a symbol its neighbors. Without an outline the blocks around the
  caret by indentation, named by their first line. The outline is fetched
  once typing pauses.
- Both can be turned off in Settings → Editor.

### D83. Typing follows the file's indentation

Tab inserted a tab character drawn at AppKit's default width, so in a
2-space file a Tab went deeper than the lines around it. Every editor
(VS Code's `detectIndentation`, Zed, Sublime, Xcode) instead types the
file's own indentation:

- A file's indentation is its `.editorconfig`, else guessed from the file
  when it opens (`Indentation` — the formatter's guess from D60/D61, moved
  to OrbitAPI so the editor and the Languages plugin share it). It's kept
  per file for the session; the status bar shows it ("Spaces: 2") and its
  menu changes it for that file.
- Tab goes to the next indent stop (spaces or a tab); with several lines
  selected it indents them, ⇧Tab outdents. Return keeps the line's
  indentation, one level deeper after `{ [ (`, and between a pair puts the
  closing one on its own line. Backspace in leading spaces deletes back to
  the previous stop.
- Tabs are drawn `size` columns wide (the paragraph style's tab interval).
- Not done: language-aware indentation (Python's `:`, outdenting a typed
  `}`), converting a file between tabs and spaces.

### D84. Overview ruler under the scroller

VS Code's overview ruler: a 12-pt strip at the editor's right edge, under
the vertical scroller, marks where things are in the whole file, so a
problem or a change far off screen is visible and the scroller jumps to it.
Three lanes, as VS Code: git changes (the gutter's markers, left), uses of
the symbol at the caret (LSP document highlights, middle), problems (right,
errors over warnings); the caret is a line across. Lines map to the strip's
height proportionally (exact without wrapping, close with it). It is one
view drawing rects, takes no clicks (the scroller over it does), and
redraws only when one of those inputs changes.

Not marked yet: ⌘F matches (STTextView's text finder doesn't expose them)
and occurrences of a selected word (the editor doesn't highlight those).

### D85. Restore files to before a message

Cursor's "Restore checkpoint" / Claude Code's `/rewind`: every user message
in an agent chat gets a restore point, and hovering the message shows ↺
(confirmation first) that brings the project's files back to how they were
before it was sent.

- The restore point is the shadow-git tree `beginAgentTurn` already writes
  (D6); it now snapshots every turn and returns the tree, while parallel
  sessions keep sharing the first turn's tree as the review baseline.
  Shadow repos get `gc.auto 0` so unreferenced trees aren't pruned.
- Restoring writes every file that differs from the tree (gitignored files
  and the D6 excludes aren't touched), trashes files created since, and
  records what it overwrote as unreviewed changes: the restore shows inline
  like an agent edit and is undone block by block or with Undo All, no
  separate undo history. Binary files are put back without review.
- (D132 adds rewinding the chat too.) Only the files go back, not the conversation: ACP can't truncate a
  session. The agent's next message starts with a note that the files were
  restored, so it doesn't trust its earlier edits.
- Restore points persist with the session (`SavedSession.checkpoints`, last
  100) and are matched to a reopened conversation's replayed messages by
  their text; messages whose text the agent replays differently lose theirs.
- Not in isolated sessions yet (their copy isn't tracked by `ChangeTracking`)
  and not while any agent turn runs.

### D86. MCP servers for every agent from `.orbit/settings.json`

Orbit passed agents an empty `mcpServers` list, so an MCP server had to be
set up in each agent's own config. Now `"mcpServers"` in
`~/.orbit/settings.json` (all projects) and the project's
`.orbit/settings.json` go to every agent in `session/new` and `session/load`.

- The format is Claude Code's `.mcp.json` / Cursor's `mcp.json` / Claude
  Desktop's (`command` + `args` + `env`, or `url` + `headers` with `type`
  `http` / `sse`; `disabled: true` skips one), so existing configs paste in.
  `${VAR}` and `${VAR:-default}` expand from the login shell; a bare command
  is resolved on its PATH (agents don't spawn through a login shell).
- The project's servers win over global ones by name. Agents keep their own
  servers too; whether an adapter dedupes a server configured in both
  places isn't checked, so keep each server in one place.
- Remote servers go only to agents declaring `mcpCapabilities.http` / `sse`.
- Edited as JSON, like formatters (D60), not in a form: Settings → Agents →
  MCP Servers lists what's configured and its problems, with buttons that
  open the files (adding an empty `"mcpServers"`). Problems aren't posted in
  the chat: a notice would replace the new-chat screen.
- Servers are read when a chat starts; open chats keep theirs.

### D87. Notifications and a Dock badge for agents in the background

Parallel agents run for minutes; nothing told the user one was done or
blocked on a permission while they were in another app.

- While Orbit isn't the active app, a session posts a system notification
  when its turn ends (the agent's last reply as the body), when it fails or
  its agent exits mid-turn, and when it asks for a permission (that one also
  bounces the Dock icon once). A turn the user stopped posts nothing.
- One notification per chat (its id is the session's), so a newer one
  replaces the older instead of piling up; clicking it selects the chat and
  shows the Agents panel.
- The Dock badge counts chats that wanted the user since Orbit went to the
  background; it clears when Orbit comes to the front.
- Nothing is posted while Orbit is in front: the chat tabs already show it.
- A turn that hands over to a queued message (D88) posts nothing; the last
  one in the queue does.
- Settings → Agents → "Notify when an agent finishes or needs you" (on by
  default) turns both off. Notification permission is asked on the first
  notification, not at launch.
- Lives in the Agents plugin (`AgentNotifier`), which owns the
  `UNUserNotificationCenter` delegate; another plugin wanting notifications
  would need a shared service first.

### D88. Queue messages while the agent works

The composer was locked while a turn ran, so a follow-up thought had to wait
or be kept elsewhere. As in Cursor and Claude Code, Return while the agent
works now queues the message (the placeholder says so); queued messages sit
above the composer and go out one by one as turns end.

- Each queued row has Send Now (stops the running turn, then sends it),
  Edit (back into the composer when that's empty) and Remove.
- The queue goes on after a normal end (also hitting a token or turn limit);
  after Stop, a refusal, an error or a crash it pauses ("Queue paused…") so
  the user can rethink, and Send Now resumes it.
- Messages are sent as written, each its own turn with its own restore point
  (D85); they aren't merged into one prompt. The queue isn't saved: it's gone
  when Orbit quits.

### D89. Image / PDF viewer and Markdown preview (Preview plugin)

Images opened as garbled text, and the READMEs and plans agents write could
only be read as source. A new `OrbitPreview` plugin, through editor
providers only:

- **Images** (png, jpg, gif, webp, heic, tiff, bmp, ico, icns, avif) and
  **PDFs** open in a viewer (provider priority 10, above the text editor).
  Images fit the view when larger, else show at 1×, centered; pinch or
  ⌘-scroll zooms, double-click toggles fit / actual size (as Preview.app);
  a glass capsule shows pixel size and file size. PDFs use PDFKit. Both
  reload when the file changes on disk. SVG stays text (it's edited).
- **Markdown preview**: File ▸ Open Markdown Preview (⇧⌘V; ⇧⌘V in the
  preview goes back to the source) opens a "Preview README.md" tab that
  follows the open buffer as you type (150 ms debounce), unsaved edits
  included, and the disk when the file isn't open.
- Rendering: Foundation's `AttributedString(markdown:)` (cmark-gfm) walked
  into HTML (`MarkdownHTML`): headers with GitHub anchors, lists, task
  lists, quotes, tables with alignment, code blocks colored by the
  `SyntaxHighlighting` service, images, raw HTML. No dependency; shown in a
  WKWebView with a GitHub-like stylesheet in the system font and colors over
  the window's theme background.
- The page's own scripts are off (`allowsContentJavaScript = false`): a
  repo's Markdown can't run code; only our injected `innerHTML` update runs,
  which also keeps the scroll position. Local images load through an
  `orbit-file:` scheme handler. Links: anchors scroll, local files open in
  Orbit, everything else in the default browser.
- A tab beside the source, not a split: there's no split editor yet; "Open
  Preview to the Side" waits for one. Preview tabs aren't restored on launch.
  → D90: ⇧⌘V and the eye button now open the preview in the other group.
- Closing a file's tab no longer keeps its document open because a preview
  (another tab kind) shows the same URL.
- An eye button at the end of the path bar opens the preview (a new
  `EditorAction` API: plugins add command buttons there for the files they
  apply to; without the path bar they float in the editor's corner); the
  preview has a glass button back to the source.
- Front matter (YAML between `---` lines at the top: skills, Jekyll, Astro)
  shows as a key / value table instead of a paragraph under a rule; values
  join their indented and `- ` lines, quotes are dropped. Not a YAML parser:
  nested maps read as flattened text.

### D90. Split editor: two groups, the tab row split along the same line

`Workspace` holds `groups` (one or two `EditorGroup`s, each with its tabs
and shown tab) and `focusedGroup`. `tabs`, `activeTabID` and `activeTab`
stay as the focused group's, so plugins kept working unchanged; `allTabs`
is every group's.

- Side by side only, at most two groups: enough for source + preview, code
  + test, a file + the agent's other file. No vertical splits or grids.
- The author picked Zed's layout: no extra row. The window's tab row is
  split at the same x as the editors, the left group's tabs over the left
  editor, the right group's over the right one; the side without focus has
  dimmed tabs. The line between the editors drags (15–85 %, remembered).
- A click in a side focuses it (a local mouse-down monitor: AppKit text
  views swallow SwiftUI tap gestures). Commands act on the focused side.
- Opening a tab that's already open on the other side focuses it there
  instead of duplicating it (Zed); Split Editor (⌘\\) is the deliberate
  duplicate: the active tab also opens on the other side. Two editors of one
  file share its `TextDocument` and follow each other's edits.
- Tabs also move and split by drag and drop (D91).
- Move Tab to Other Side ⌥⌘\\, Focus Other Side ⌃⌘\\, Join Editors (all
  tabs into one group); tab menus have Move to Other Side and Open to the
  Side. A side whose last tab closes disappears.
- `openBeside(_:)` opens a tab on the other side keeping focus: the Markdown
  preview (D89) opens there, so typing stays in the source.
- Both groups' file tabs come back on launch (`groups` in the D80 entry;
  `files`/`active` still hold the first group's).

### D91. Drag and drop of tabs and files (Cursor-style)

- **Tabs** are dragged by our own gesture inside the window (`TabDrag` in
  `App/EditorDrops.swift`), not the system drag: a glass chip follows the
  pointer, an accent line marks where it lands in a tab row, the editor
  shows the zone it would fill. Release: reorder in the row, move to the
  other side's row (a side that empties closes), split on an editor edge,
  or attach its file to the agent chat. The first version used the system
  drag (`onDrag`): after a drop its image hung in the air for seconds and
  SwiftUI's drop delegate left the insertion line behind; a gesture ends
  exactly on release. Views report their global frames (rows, tabs, editor,
  chat) to `TabDrag`, which picks the target under the pointer.
- **Files** (explorer rows, Finder) use the system drag. Explorer rows use
  `.draggable` on the row, which List turns into its own row drag (the whole
  row, every time; `onDrag` on the label caught only its text), with a
  `DragPreview` (icon and name on a material capsule in the window's color
  scheme): the default snapshot of the row drew the name in black in dark
  mode. Files drop on a tab row (between tabs), on an editor (open there, or
  on an outer quarter of an unsplit editor, a new side), or anywhere on the
  agent chat ("Add to Chat", attaches). Folders attach but don't open.
- Editors are AppKit text views registered for file drops themselves, so a
  SwiftUI `onDrop` above them never fires: the editor area has an AppKit
  catcher view on top, registered for file URLs only, whose `hitTest` is
  nil so clicks and text selection pass through (AppKit picks drag
  destinations by registered types, not `hitTest`). Text drags inside the
  editor are untouched.
- The tab row is in the title bar strip, where a mouse drag moves the
  window: while the pointer is on a tab the window is made immovable
  (`isMovable`, set async on a change), so the drag goes to the tab; the
  empty part of the row still moves the window.
- Tabs dropped on the chat attach through `AgentTasks.attachFile` (the App
  knows the chat's frame as the inspector's "agents" panel).

### D92. Moving files between folders in the explorer

As in Cursor: explorer rows (D91) dropped on a folder row move there; on a
file row, into that file's folder; below the rows, into the project's top
folder. The target folder's row lights up (the whole list is outlined for
the top folder) and expands after the drop.

- The project's own files move (⌥ while dropping copies); files from Finder
  or another folder are copied in, as Finder does across folders.
- A confirmation first ("Move “a.ts” into “src”?"), as in Cursor and VS
  Code, with "Don't ask again": a drag released on the wrong row is easy to
  miss and there's no undo yet. Nothing is replaced: a name that's taken, or
  a folder dropped into itself, is reported and skipped.
- `Workspace.moveItems(_:into:copy:)` (OrbitAPI) does the move so open tabs
  and buffers follow the files, unsaved edits included (a document's URL is
  fixed, so its text moves to a new one), on both sides of a split, previews
  too. Agent review baselines (D5) keep the old paths.
  → D93: moves (and copies in) are undoable with ⌘Z.

### D93. Rename, new file / folder, delete and undo in the explorer

Cursor's file operations, with Finder's keys:

- Rename inline: Return on the selected row or "Rename…" in its menu turns
  the name into a field (a file's name selected up to its extension);
  Return or clicking away keeps it, Escape cancels. Open tabs and buffers
  follow, as for moves (D92): `Workspace.moveItem(_:to:)` /
  `renameItem(_:to:)` share `relocate`. A case-only rename goes by way of a
  temporary name (the disk is case-insensitive).
- New File (⌘N) / New Folder (⌥⌘N): from a folder's menu, the hover buttons
  on the project's header (or its menu), or the File menu, which uses the
  folder chosen in the tree or the active file's. A field appears at the
  top of the folder; a path ("src/a.ts") creates the missing folders, as in
  Cursor. A new file opens.
- Move to Trash (⌘⌫ or the menu), never a hard delete: asks first with
  "Don't ask again", but always when unsaved edits would go. Tabs of what
  went (and of what was inside a folder) close.
- Undo/redo go on the window's undo manager, so ⌘Z and Edit → Undo
  ("Undo Rename") work with the explorer (or nothing) focused while the
  editor and text fields keep their own. Undo moves things back, takes a
  new or copied item to the Trash and puts a trashed one back where it was;
  each undo registers its redo. Opening another folder clears them.
- Rows' selection still follows the active file; a folder chosen with the
  arrow keys stays selected so Return and ⌘⌫ reach it.
  → D96: a clicked folder stays selected too.

### D94. Preview tabs: a click in the explorer reuses one tab

As in Cursor, VS Code and Zed: a single click (or the arrow keys) on a file
in the explorer opens it in the group's preview tab, its title in italics;
the next click replaces that tab in place instead of adding one, so
browsing the tree doesn't pile up tabs. The tab is kept (a normal tab) by a
double click on the file or on the tab, "Keep Open" in the tab's menu, or an
edit; a preview with unsaved edits is never replaced. Everything else (Open
Quickly, go to definition, search, agent links, New File) opens kept tabs,
and clicking a file that's already open just shows it. Dragging a tab to
the other side keeps it. Not saved across launches: restored tabs are kept.
`EditorGroup.previewTabID`, `Workspace.open(_:preview:)` and `pin(_:)`.

### D95. The explorer's context menu: Cursor's useful items

Cursor's file menu, minus what Orbit has no feature for (remote, timeline,
tests, compare, find references): New File / New Folder (folders), Open to
the Side ⌃↩, Open With (the default app first, then the others, Other…),
Reveal in Finder ⌥⌘R, Open in Integrated Terminal (the file's folder), Add
to Agent Chat / Add to New Agent Chat, Cut ⌘X / Copy ⌘C / Paste ⌘V, Copy
Path ⌥⌘C / Copy Relative Path ⇧⌥⌘C, Rename ↩, Move to Trash ⌘⌫. The keys
work on the selected row; ⌘X ⌘C ⌘V go through the Edit menu.

- Cut and Copy put file URLs on the general pasteboard, so Finder pastes
  them and Finder's copies paste here. Paste moves what Orbit cut (open
  tabs follow, D92) and copies anything else; a taken name gets "a
  copy.txt" as in Finder, so pasting into the same folder duplicates.
  Both are undoable (D93).
- The terminal and the agent chat are other plugins: two services,
  `TerminalOpening` (new) and `AgentTasks.attachFileToNewChat`, looked up
  when the menu opens, so an item disappears with its plugin.

### D96. Explorer folders: selected on click, gray, toggled reliably

The tree is a SwiftUI `List` (an outline view underneath) whose selection is
the active file. A click on a folder used to select it for one turn and
snap back, so the next click on it registered again: the highlight flashed
on every click and sometimes stuck on a folder. Now, as in Cursor, a
clicked folder stays selected (New File and Paste go into it) until a file
is chosen. The first click toggles it through the selection; a click on the
already selected row reaches only the row's tap gesture, which toggles it
then (`folderTapped`; the first click's tap is skipped).

Folders still animate open and closed, but their children load before the
animation (the rows below shifted while a half-filled folder opened).
Clicks during the animation were lost to the selection that hadn't snapped
back yet; the tap gesture takes them now.

The selection is drawn by the rows (`RowHighlight`): always the translucent
gray of an unfocused sidebar. The list's own highlight is off
(`selectionHighlightStyle = .none` on the outline view found under it):
it turned blue whenever the list had the focus (a folder click, the start
of a drag) and could stay on a folder the selection had already left after
a file was dragged out to split the editor. Keyboard selection still works.

### D97. The accent comes from the color theme, never the system blue

The system accent (blue by default) clashed with color themes: selected
panel tabs, toggles, prominent buttons, drop outlines and match highlights
were blue whatever the theme. `Theme.accent` (and `accentNSColor` for
AppKit) is the theme's `text.accent` (else `icon.accent`, `border.focused`),
both variants so it follows light and dark; with no color theme it's the
text color, so the System theme is monochrome. The window sets it as
`.tint`, so `.tint` styles, `.glassProminent` buttons and controls follow;
code uses `Theme.accent` instead of `Color.accentColor` /
`controlAccentColor`. Open Quickly's matched letters are bold in the text
color. Status colors stay semantic (info, modified, completion kinds).
Native list selections elsewhere still take the system accent while
focused (AppKit has no per-window accent).
*Changed by D190: the window's `.tint` is the text color; the accent is
only for selections, matches and drop marks.*

### D98. Getting around by keyboard

Arrow keys in the explorer stopped after one step: each step previewed the
file and the new editor took the focus. Opening now says whether to take
it (`Workspace.open(_:preview:focus:)`): the explorer's clicks and arrow
keys don't (`quietTabID`), as in VS Code and Cursor, so the tree keeps the
keys while it previews. Anything that means "go there" does:
`focusEditor(group:)` sends a request the code editor answers by taking
the focus (`editorFocusRequest`).

Keys, VS Code's and Cursor's on a Mac:

- Explorer: arrows move (← → close and open folders), Space keeps the
  previewed file's tab, Escape or a double click goes to the editor,
  Return renames, ⌃↩ opens to the side, ⌘⌫ trashes; ⇧⌘E shows the explorer
  and puts the keys in it.
- ⌘1 the editor (its left side), ⌘2 the right side; ⌃⌘\ the other side.
- ⇧⌘] / ⇧⌘[ next and previous tab; ⇧⌘T reopens the last closed tab (the
  last 30, forgotten with the folder).
- ⌥⌘R Reveal in Finder, ⌥⌘C / ⇧⌥⌘C copy the path: commands on the
  explorer's selected row, else the active file, so they work from the
  editor too.
- Already there: ⌘P files, ⇧⌘O symbols, ⌘L agent chat, ⌃` terminal,
  ⌃⇧G source control, ⇧⌘F search, ⌃⌘S / ⌥⌘I sidebars.

Two sides showing one file both answer a focus request (the last wins).

### D99. Go Back / Go Forward and the ⌃Tab recent-tab switcher

VS Code's and Cursor's keys: ⌃- goes back to where the caret was before a
jump, ⌃⇧- forward again; ⌃Tab, with ⌃ held, walks the open tabs from the
most recently shown (⇧ walks back, Escape cancels) and letting go of ⌃
shows the picked one. A quick ⌃Tab flips between the last two tabs.

History lives in `Workspace` beside D98's API, as back and forward stacks
of `EditorLocation` (file, line, column; 50 kept, forgotten with the
folder). A jump is recorded where it leaves from, so the caret where it
lands is the current place:

- the shown file changes for any reason (Open Quickly, the explorer, go
  to definition, search results, a tab click, ⌃Tab): the previous file's
  last caret;
- `openFile(_:line:column:)` within the shown file: the caret before it;
- the editor reports every caret move (`caretMoved(to:)`); one of 10 lines
  or more is a jump, as in VS Code. Moves from text pushed in by an agent
  and the caret a new text view starts with aren't reported.

A new jump drops the forward stack; files gone from disk are skipped.
⌃- and ⌃⇧- are caught by the window's key monitor along with ⌃Tab: a menu
shortcut with ⇧ on "-" reads as "_" and never matches. The menu items stay
for discovery (View menu, palette); "Show Recent Tab" picked from the menu
flips to the previous tab. In the terminal ⌃- no longer reaches the shell
(readline's undo), as in VS Code.

### D100. Dock menu and Open Recent: recent folders

As in Cursor, a right click on the Dock icon lists the folders opened
lately (the open one checked; a click opens it in the window, asking about
unsaved edits first), then Open Folder… and New Agent Chat; AppKit adds the
window list, Options, Show All Windows, Hide and Quit. Orbit has one
window, so Cursor's New Window has no counterpart. *(Changed by D101: a
window per project; the Dock menu got New Window, every open folder is
checked, and a recent folder opens in its own window.)* The same folders are in
File → Open Recent (with Clear Menu). `RecentFolders` (App) remembers the
last 10 in `orbit.recentFolders`, following `Workspace.root`; folders gone
from disk are left out.

### D101. A window per project; the welcome window

Several projects at once, as in Cursor: each window has its own folder
and its own `PluginHost` — a full set of plugins, so tabs, terminals,
agent chats, language servers, git and checkpoints are per window and
never mix. Plugins needed no change: they already kept their state in the
plugin instance. What was app-wide and window-bound became per window:
the active editor for keyboard commands (`ActiveEditor`: the main window's
editor), the tab drag (`TabDrag` in the environment), the ⌃Tab switcher,
the shortcut cheat sheet and the window layout (sidebar, inspector, bottom
panel height: each window its own, the last change is what a new window
starts with).

- `WindowGroup(for: ProjectWindowID)`; `ProjectWindows` (App) makes each
  window's host, knows the main window (menus and their shortcuts act on
  its host's commands) and opens windows. SwiftUI's own window
  restoration is off: the folders open at quit (`orbit.openFolders`, in
  window order) come back as windows on launch, the first in the window
  macOS opens.
- Open Folder (⌘O, Open Recent, the Dock) in a window that shows a project
  opens a new window; in a window without one it opens there. A folder
  already open just brings its window forward. `Workspace.requestOpenFolder`
  asks the app through `openFolderElsewhere`.
- File → New Window (⇧⌘N, as in Cursor), also in the Dock menu.
- A window without a folder is the welcome window, after Cursor's: Open
  Folder and Clone Repository (`git clone` into a folder picked in a
  panel, then opened), and Recent Projects (6, Show All; × removes one).
- Closing a window asks about its unsaved edits (a stand-in in front of
  SwiftUI's window delegate) and stops its plugins. Closing the last one
  still quits, and its folder opens next launch; ⌘Q asks window by window.

No Close Folder yet: plugins were written for a folder that only changes
to another folder, not back to none. *(Added by D102.)*

A closed window must free its project. The registries hold closures that
hold the plugins, which hold the registries, so `PluginHost.shutdown()`
empties them and `Workspace.close()` drops buffers and tabs (the saved
tabs stay) and sets the folder to none; observers that re-arm on the
folder stop once `Workspace.isClosed` (`WindowLifetimeTests` checks the
whole graph goes). It runs after the window is gone, so the window doesn't
flash the welcome screen. `ShellEnvironment.resolve()` runs the login
shell once per app, not three times per window.

### D102. Close Folder; folders from Finder and the Dock

File → Close Folder turns the window into a welcome window, as in Cursor.
Rather than teach every plugin a folder going back to none, the window
stops its host (terminals, agents, language servers end as when it
closes, after asking about unsaved edits) and gets a fresh one without a
folder; `ProjectWindows.hostRevisions` tells its view, and the view's
layout state starts over with the host. No shortcut: Cursor's ⌘K F is a
chord, which menus can't show.

Orbit declares folders as a document type it can open (Viewer, Alternate
rank: never the default for folders; `App/Info.plist`, merged into the
generated one), so a folder dropped on the Dock icon or opened with Orbit
in Finder reaches `application(_:open:)` and opens as Open Recent does
(its window, else a new one). The window group ignores external events, so
SwiftUI doesn't add a window per folder itself. Folders that arrive while
Orbit is launching go first, before the ones open at the last quit.

### D103. Tab rows measure their width outside the scroll view

Orbit crashed on launch with the Agents panel open (AppKit's "more Update
Constraints in Window passes than there are views", after SwiftUI's
"Geometry action is cycling between duplicate values"). The editor's and
the chat's tab rows filled their scroll view (`minWidth` of the content =
the scroll view's width, so free space drags the window) and measured that
width with `onGeometryChange` on the scroll view itself: the content's min
width fed back into its size, and in a tight window the two never settled.
Each row now reads its width from a `GeometryReader` around the scroll
view, which takes what it's offered whatever is inside.

It showed after D101 because the new window group had no default size:
every window opened at its minimum (960 × 632), saved that, and came back
at it. `.defaultSize(1280 × 800)`, and the minimum frames saved by those
builds are forgotten once.

### D104. The editor column cancels the sidebar's inherited safe-area inset

Shrinking the window with both the sidebar and the Agents inspector open
crashed (the same update-constraints loop, from
`SplitViewChildController.hostingView(_:didUpdateMinSize:)`). The detail
column runs under the floating sidebar, and so does the inspector's split
view nested in it: the editor column inherited the sidebar's inset, SwiftUI
counted it (plus the inspector's) into its min width, and the outer column
added the sidebar's inset again. Min width = 2 × sidebar + inspector (988 at
the defaults), so any window narrower than that looped. Reproduced every
time by resizing from 1280 to 960 wide; only with both panels open.

`SidebarInsetCanceller` sets a negative `additionalSafeAreaInsets.left` on
the inspector's split view, so the editor column no longer inherits the
sidebar's inset, and `EditorArea` pads itself by the same amount (read as
the detail column's leading safe area) inside its zero-min frame. The min
width is now sidebar + inspector, which always fits. Tried and not enough:
ignoring the safe area in SwiftUI (the inset comes from AppKit),
`NSSplitViewItem.automaticallyAdjustsSafeAreaInsets = false` (no effect),
`.inspector` on the whole `NavigationSplitView` (then the inspector is
counted twice).

The cancel is written a run loop late (window changes go async). Opening
the sidebar, the editor column kept the whole inherited inset for a frame on
top of its own padding: logged per frame, the tabs and code jumped to twice
the sidebar's width, then back. `EditorArea` now ignores its leading safe
area (outside its padding, or it has no effect), so the padding alone clears
the sidebar and the content follows it frame by frame; the cancel only keeps
the min width right.

The tab row's room for the traffic lights switched between 76 and 6 pt on the
visibility flag: it jumped when the slide began and animated on its own
clock, so the tabs went one way, then the other. It is now
`76 − sidebar inset` (at least 6), so it shrinks exactly as the sidebar
covers the traffic lights; logged per frame, the tabs move one way only.

### D105. Text editing basics: line moves, multiple carets, Go to Line, bracket match, zoom

What any editor has and Orbit didn't (bracket autoclose was already there, D73):

- **Keys from VS Code / Cursor** where the author's hands are: ⌥↑ ⌥↓ move
  lines, ⇧⌥↑ ⇧⌥↓ copy them, ⌘D adds the next match, ⇧⌘L selects all
  matches, ⌥-click adds or removes a caret, Esc goes back to one. Where
  VS Code's key is taken here, Xcode's: ⌃⇧↑ ⌃⇧↓ add a caret above / below
  (⌥⌘↑ ↓ walk agent changes, D45), ⌃⇧-click adds one too, ⌃G is Go to Line
  (⌘L attaches the selection to the agent chat), and the menu's Move Line
  Up / Down are ⌥⌘[ ⌥⌘].
- **`OrbitCommand.editorShortcut`**: a key only the focused editor answers,
  matched in `OrbitTextView.keyDown`. ⌥↑, ⌃⇧↑ or ⌘D as menu shortcuts would
  fire from any text field (the agent composer) and edit the editor behind
  it. Lists, tooltips and hints show `displayShortcut` (the menu one first);
  the menu bar can't show an editor-only key.
- **Multiple carets** are STTextView's (`textLayoutManager.textSelections`):
  typing, deleting and moving already apply to each. Our single-caret rules
  (indentation on Return/Tab/Backspace, bracket pairs, completion) step aside
  while there are several: Return is a plain newline, Tab inserts one indent,
  completion closes.
  > **D202: the rules and completion now work at every caret; bracket match skips strings and comments.**
- **Bracket match**: the bracket after the caret (else before it) and its
  partner get a thin outline in the text color. Plain text scan of the
  language's single-character pairs within 50k characters; brackets inside
  strings and comments count too (no syntax tree lookup, as Zed's).
- **Zoom** ⌘= ⌘- ⌘0 change the shared code font (editor, terminal, diffs),
  the same setting as Settings → Editor.

Logic in `LineEditing` (pure, `LineEditingTests`); commands in `LineCommands.swift`.

### D106. Files keep their encoding and line endings; binary and huge files aren't opened

Every file was read and written as UTF-8: a Windows-1251 or UTF-16 file
couldn't open, and nothing protected a 500 MB log or a binary from the editor.

- **Inside Orbit text is a Swift string with `\n` breaks**; `TextFileFormat`
  (encoding, BOM, line ending) is kept per document and applied on save
  (`TextFile.decode` / `encode`). Normalizing at the edge, not in the editor,
  keeps everything that counts lines (inline diffs, LSP, folding, search)
  as it was. Where text comes in some other way it's normalized too: review
  baselines from the shadow git, isolated copies, formatter output.
- **Detection**: a BOM, else strict UTF-8, else Foundation's detector with
  Cyrillic, Western, Japanese and Mac encodings suggested; NUL bytes in the
  first 8 KB and no BOM mean binary. The line ending is the majority one; in
  a mostly-LF file a stray CRLF line stays as it is.
- **Writing a file that isn't open** (`DocumentStore.write`: agents' reverts,
  replace in files) keeps the format of the file already on disk.
- Files over 50 MB, binary files and undecodable ones show "Can't Open File";
  binary and undecodable offer **Reopen with Encoding** (UTF-16 without a BOM
  looks binary).
- The status bar shows the format only when it isn't UTF-8 + LF, as a menu:
  line endings, Save with Encoding, Remove BOM, Reopen with Encoding.
  Characters the encoding can't store fail the save with a message instead
  of being dropped.

### D107. Shortcuts can be reassigned in Settings → Keyboard Shortcuts

Each row's key caps are a recorder: click, press the new keys (⌫ removes
the shortcut, Esc or a click elsewhere cancels); a reset arrow shows on
changed rows, Reset All in the header.

- **Only changes are stored**, app-wide in `orbit.keyBindings` as readable
  names (`"shift+cmd+k"`, `""` for removed); `KeyBindings.shared` is read by
  `OrbitCommand.shortcut` / `editorShortcut`, so every window's menus,
  palette, tooltips and editor keys follow at once. Plugins keep declaring
  defaults (`defaultShortcut`).
- **A user's key** replaces the menu shortcut, or the editor-only one when
  that's all the command had (D105); a command without any gets a menu one.
- **Taking a key another command has** moves it: the other loses it and a
  note under the row says so (Xcode's way of not leaving two commands on
  one key). ⇧⌘P and ⌘, belong to the shell and can't be taken.
- A recorded key needs ⌘, ⌃ or ⌥: without one it would stop typing that
  character. Keys are recorded as the layout types them when it types Latin
  letters (QWERTY, Dvorak), else by ANSI key position (Russian: ⌘В is ⌘D),
  and editor keys are matched the same way (`KeyPositions`).
- The editor's own ⌃⇧I by key position (format, menus can't see it in a
  Russian layout) only applies while Format Document keeps its default.

### D108. Editor and agent options in `.orbit/settings.json`

The settings files held only plugin sections (formatters, language servers,
companions, MCP servers). Now simple options too, so a project can say how
it's edited and which agent works on it:

    {
      "editor": { "wordWrap": true, "formatOnSave": true },
      "agents": { "default": "codex", "isolated": true }
    }

- Editor: `wordWrap`, `highlightCurrentLine`, `formatOnSave`, `inlayHints`,
  `stickyScroll`, `pathBar`. Agents: `default` (an installed agent's id or
  name, a prefix is enough), `isolated`. `"editor.wordWrap": true` at the
  top level works too, as in VS Code.
- **Order**: the project's file, then `~/.orbit/settings.json`, then what's
  picked in Settings. Settings shows a decided option disabled with "Set by
  .orbit/settings.json" instead of a toggle that does nothing. Font size
  stays app-wide (shared with the terminal), indentation stays
  `.editorconfig`'s (D83).
- `ProjectSettings` (on `Workspace`, one per window) reads both files'
  top-level values and those one object down; plugins keep parsing their own
  sections. It reloads when the folder opens, a settings file is saved in
  Orbit, files change (`fileSystemDidChange`) and Orbit becomes active.
- File → Open Project Settings creates the file with empty sections (a
  template with values would pin Orbit's defaults over the user's).

### D109. The isolated-copy sweep leaves this run's copies and other processes alone

Each `AgentStore` deletes isolated copies no saved chat tab uses (leftovers
of earlier runs). Since D101 that runs whenever a window opens, so a copy
made since launch whose chat tab wasn't saved yet could go. And `make test`
(`WindowLifetimeTests` starts every plugin) swept the app's folder with the
test process's empty settings: it deleted the copies of the running Orbit's
chats, and the isolated-copy tests' own copies mid-run (their flaky
"git init failed" / missing `a.txt`).

The sweep now only deletes folders created before the process started, and
only the app (`dev.orbit.app`) uses `Application Support/Orbit/isolated`;
any other process gets its own temporary folder.

### D110. Indent guides, Find in Folder, Compare Files, terminal find and font

The roadmap's smaller "desirable" items:

- **Indent guides**: 1-pt lines at each indentation level of the visible
  lines (`IndentGuidesController`, a view under the text redrawn per
  viewport layout). The level is the indent ÷ the file's indent size; blank
  lines take the shallower neighbor, looking up to 100 lines past the
  viewport. Theme color `editor.indent_guide` (Zed), else the ink at 10–12%.
  On by default; `"editor.indentGuides"` (D108) and Settings → Editor.
- **Find in Folder** in a folder's context menu: Find in Project with the
  folder in "files to include" (filters shown), through `ProjectSearching`
  (the explorer can't import the search plugin).
- **Select for Compare / Compare with “…”** in a file's context menu, as in
  VS Code: a read-only unified diff tab (`explorer.compare`), unsaved edits
  included, redone as either buffer or the disk changes. The gap row moved
  to OrbitUI (`DiffGapRow`) for the git tabs and this one.
- **Terminal**: SwiftTerm 1.20 has its own find bar (⌘F through Edit →
  Find while the terminal has focus); Terminal → Find in Terminal opens it
  from the menu or palette. A terminal font size of its own in Settings →
  Editor → Font (`Preferences.terminalFontSize`, nil follows the code font).

### D111. Side-by-side diffs, replace undo, explorer multiple selection, Peek References

The roadmap's bigger "desirable" items:

- **Side-by-side diffs**: every diff tab (working tree, staged, commit,
  Compare) has a Unified / Side by Side switch in its header; one app-wide
  choice (`orbit.diffSplit`). Split rows pair each run of removed lines
  with the added lines after it (`DiffLayout.rows`), a missing side shaded.
  Agent tool cards stay unified (too narrow).
- **Replace in Files undo**: the panel keeps what the last replace changed
  (each file's text before and after) and shows "Replaced N matches · Undo".
  Undo puts files back only where the text is still what the replace left;
  a file edited since keeps its edits and is named. Files are now read
  through `DocumentStore.currentText` (their encoding, D106).
- **Explorer multiple selection** is the list's own (⌘-click, ⇧-click):
  the binding is a set, and one row in it takes the single-selection path
  unchanged (previews, folder toggling, D94–D98). The extra rows are drawn
  with our highlight; Cut, Copy, Copy Paths, Trash (⌘⌫), Reveal in Finder,
  Add to Agent Chat act on all of them (nested items go with their folder),
  Rename only on one; two selected files offer Compare Selected.
- **Peek References** (⌥⇧⌘R): the uses as a quick pick (line with the name
  in bold, file, line number), starting on the use at the caret; Return
  jumps. Not VS Code's inline editor, and no live preview while arrowing:
  revealing a line focuses the editor, which would take the keys from the
  pick. Find References (⇧⌘R) still fills the panel.

### D112. Performance and memory pass: review cache, git refresh coalescing, streaming Markdown

An audit of hot paths during agent turns and multi-window use:

- **Change review**: `ChangeTracker` read every changed file from disk two
  or three times per redraw (changes list, status item, commands, gutters).
  Files that aren't open are cached and revalidated by `stat` (size, inode,
  mtime in ns); each file's last diff is reused while both sides are the
  same, and `stats` comes from those hunks (one per change block).
- **Git**: a status refresh is five git processes; cancelling its task never
  stopped them, so an agent's burst of edits stacked runs. Now one runs at a
  time and requests meanwhile become one more run. The 3 s polls (panel,
  diff tab) skip while Orbit is in the background; activation refreshes.
- **Agent chat**: a reply without code fences is one prose segment, re-parsed
  as Markdown on every streamed chunk (quadratic). Prose is parsed a
  paragraph at a time with an `NSCache`, so only the last paragraph is new.
  Tool output trims with hysteresis on `utf8.count` (O(1)), not `count`.
- **Language edits** to files that aren't open (a project-wide rename) are
  written through `DocumentStore.write` instead of opening a buffer per
  file that was never closed (kept in memory and re-read on every disk sync).
- **Notifications**: the notification center has one delegate, and each
  window's `AgentNotifier` took it (D101): clicks went to the last window and
  the Dock badge showed one window's count. A shared router hands clicks to
  every notifier (the owner of the chat acts) and sums the badge.
- **Explorer**: a reload keeps a folder's children array when nothing in it
  changed, so a disk change no longer redraws the whole tree.

### D113. Second performance pass: shadow-git queue, cancelled searches and diagnostics pulls

The modules D112 didn't read (editor internals, LSP and JSON-RPC, shadow
git, terminal, preview, window shell), plus its leftovers:

- **Shadow git** (`ChangeTracker`): snapshot, refresh and restore run one
  at a time through a queue. Parallel sessions and per-tool-call refreshes
  ran `git add` on one index together; the loser failed on `index.lock`,
  and a turn's final refresh failing left its last edits out of review.
  A refresh also ran `git show` for every changed file on every tool call;
  files with a recorded baseline are now skipped (`changes(skipping:)`).
- **Find in Files**: a disk change re-runs the search 400 ms after the
  burst, and a newer search cancels the running one's file reads (the
  detached task never got the cancellation before).
- **Language servers**: a newer `textDocument/diagnostic` pull for a file
  cancels the previous one (`$/cancelRequest`), instead of the server
  computing problems for every typed version.
- **Git diff tab**: the 3 s reload skips diffing and coloring when both
  sides are the same as last time.
- JSON-RPC stderr tail trims with hysteresis on `utf8.count`.

Checked and left as they are: the editor's controllers hold the
coordinator `unowned` and remove their observers; `ActiveEditor` holds
editors weakly; terminal transcripts are byte arrays; `ToolContent.id`
hashes only when its own card redraws.

### D114. Third performance pass: media reloads, tool-card diffs, line starts

- **Image and PDF tabs** reloaded the file on every `fileSystemGeneration`
  bump (an agent bumps it constantly), and a reload refits the image and
  sends a PDF back to page 1: zoom and scroll were lost while an agent
  worked. They reload only when the file's modification date or size
  changes (`FileStamp`, from `FileManager` attributes; `URL.resourceValues`
  caches on the URL and would keep the old date).
- **Tool-card diffs** (`CompactDiffView`) diffed in `init`, which runs on
  every update of the call (status, streamed output) and as the chat
  scrolls; results are cached per pair of texts (32 pairs).
- **`SourcePosition.lineStarts`** (diagnostics, folding, completion, LSP
  ranges; once per keystroke) called `range(of: "\n")` once per line; it now
  scans buffered UTF-16 chunks like the highlighter's `LineStarts`.

Checked and left as they are: completion filtering (narrows the previous
pool, UTF-16 scoring), Open Quickly ranking, git change markers (debounced,
off the main actor), plugin teardown on window close (agents, language
servers, terminals stop in `deactivate`).

### D115. Slash commands in the composer; a live working line and a turn summary

The agent's commands (ACP `available_commands_update`) were stored and
never shown; a working agent said only "Working…", and a finished turn
said nothing, so it took a look at the changes bar to know what it did.

- **Slash commands**: `/` at the start of the draft lists the agent's
  commands above the composer, like `@` lists files (prefix matches first,
  then names containing the query; ↑↓, Tab / Return picks, Escape hides).
  Picking writes `/name ` into the draft, nothing is sent: commands go to
  the agent as text, the way ACP defines them, and most take input.
  Only the first word counts — agents read a command nowhere else.
- **Working line**: the running tool's title (else Thinking / Writing) and
  the turn's timer (`Text(timerInterval:)`, redrawn by the system, not by
  a timer of ours).
- **Turn summary**: a transcript row "Worked for 2m 5s · 3 files changed
  +40 −12 · Review" after a turn that changed files or took 30 s or more
  (short Q&A turns stay quiet). Its files are the ones whose unreviewed
  changes appeared or changed during the turn (stats compared before and
  after, so shell edits count too); the counts and Review follow what is
  still unreviewed, "Reviewed" when nothing is. Review opens the first
  change, inline as always (D7). Summaries aren't saved: a reloaded
  conversation has none. Isolated sessions show only the time (their
  changes come through Apply).

### D116. Reads and searches in a row fold into one transcript line

A turn that explores the code left a card per file read and per search,
pushing the agent's answer and its edits out of sight. Two or more
consecutive read / search / fetch calls now show as one card — "Read 4
files · 2 searches", the last call's title while folded, a spinner while
any runs — that expands into the usual cards. Grouping happens in the
view (`TranscriptRow.rows`), the transcript keeps every call; the group
takes its first call's id, so a card growing into a group keeps its place.
Edits, commands, failed calls and calls asking for permission are never
folded: those are what the user reviews or acts on.
→ D122: every kind folds now; only calls asking for permission stay out.

### D117. One type scale for the UI (`Font.orbit`)

About 150 places set their own point size: 15 values, half sizes (10.5,
11.5, 12.5) among them, so panels from different plugins were slightly off
from each other. Every UI text size now comes from `TypeScale` in OrbitUI
through `.font(.orbit(.caption, weight: .medium))`:

| Token | pt | For |
|---|---|---|
| micro | 10 | badges, key caps, counters, hunk buttons |
| caption | 11 | details, section headers, status bar, bars over the composer |
| code | 11.5 mono | code in the UI: diffs, search results, Markdown code |
| body | 12 | list rows, cards, tool calls, tabs |
| control | 13 | text fields, menus, primary rows |
| title | 15 | page titles, the palette's query |
| display | 28 | the welcome screens' name |

Mapping: 10.5 → 10, 11.5 → 11 (monospaced 11.5 is `code`, the one half
size kept: monospaced glyphs look larger, so 11.5 sits with 12 text),
12.5 → 13, 16 → 15, 30 → 28. Symbols next to text use the same tokens
(SF Symbols are sized like text); glyph-only sizes (7–9 pt chevrons, an
18 pt card icon) stay literal. The editor and terminal follow the user's
font size, not the scale. The unused `Theme.codeFont` is gone.
(Glyph sizes got a token in D157: `.glyph`, 8 pt. The palette's query moved to `.large`, 20 pt, in D161.)
(The ~90 SwiftUI text styles left over (`.callout`, `.caption`, `.headline`…)
moved to the scale at their macOS sizes, so nothing changed on screen:
caption / caption2 → micro, callout → body, headline → control bold,
title3 → title.)

### D118. Tool cards open their files; permissions by keyboard; other chats' approvals shown

- **Edit cards → editor**: the file name over a tool card's diff opens the
  file at its first unreviewed change (`openReview`), else just the file;
  the review stays inline (D7). The card's header shows the call's +/−,
  from the same cached diff it draws (D114). Line numbers from the ACP
  diff aren't used: agents send the edited snippet, not the whole file.
- **Permission keys**: ⌘↩ allow once, ⌃⌘↩ always allow, ⌃⌘⌫ deny, with
  the keys in each button's tooltip. Only the oldest pending request of
  the chat in view takes them (`keyedPermission`); ⌘↩ used to be bound on
  every pending card at once. Escape and ⌘⌫ were rejected: key equivalents
  run before the focused view, so Escape closing completion or ⌘⌫ moving a
  file to the Trash would have denied the request; ⌥⌘ / ⇧⌘ with ↩ / ⌫ are
  the inline review's keys.
- **Another chat waiting**: when a chat other than the one shown waits for
  a permission, a bar over the composer says so, with Show.

### D119. Changed files name their chat; an empty chat lists what the composer takes

- **Whose change**: review is per project (one `ChangeTracking`), so with
  parallel chats the changed-files list didn't say which chat made a
  change. The store remembers the chat whose turn last changed each file
  (the turn's files from D115) and the row shows that agent's icon, with
  the chat's title in the tooltip; a click switches to that chat. Only
  with more than one chat open; nothing for files changed before launch.
  The editor's banner doesn't name the chat: that would need the Agents
  plugin's sessions in `OrbitAPI`, not worth it for a tooltip.
- **Composer hints**: a new chat with no earlier conversations shows
  `@` / `/` / ⌘L / ⌘V and what each does under its greeting. With
  earlier conversations the list of them stays as it was; the
  placeholder names `@` and `/`.
- Not done from the same list: review progress ("2 of 5 viewed"). Files
  already leave the list as they're reviewed, so the count left is the
  progress.

### D120. The chat catches up with Claude Code: pinned plan, timed thoughts, Esc / ↑ / ⇧Tab, mode in view

The author measures the chat against Claude Code (CLI and desktop). What
it had that Orbit lacked, now in the Agents plugin:

- **Pinned plan**: the turn's plan sits above the composer (folds to the
  step in progress, "3 of 7 done") while the turn runs and until every
  step is done; in the transcript the plan is one line that expands. A new
  message starts without it (the agent sends a new one).
- **Timed thoughts**: "Thinking…" while it streams, "Thought for 8s" once
  the next entry arrives or the turn ends; replayed history says
  "Thought" (no times in it).
- **Keys in the composer**: Esc stops the turn (after closing the `@` / `/`
  list; ⌘. still works); ↑ / ↓ walk the sent messages from an empty draft
  or one recalled, as in a shell; ⇧Tab cycles the agent's mode.
- **Mode in view**: a button beside the options shows the mode (icon and
  name, tinted when it isn't the asking default) and picks one from a
  menu. It stays in the options popover too.
  → D122: removed; the options popover alone sets the mode (⇧Tab still cycles it).
- **Deny, then say why**: denying a permission focuses the composer with
  "Tell <agent> what to do instead…" — Claude Code's "No, and tell Claude
  what to do differently" without a separate field.
- **Jump to latest**: a round ↓ button over the transcript's bottom when
  it's scrolled up (`onScrollGeometryChange` reads the offset; nothing
  measured feeds back into the content, D103).
- **Copy a reply**: on hover under the agent's message (its Markdown).

Addendum: the jump button first bound `.scrollPosition($position)` on the
chat's view. The scroll view writes that binding on every frame, so the
whole chat (every row, the changed-files check of each file) re-ran while
scrolling and long chats lagged. The transcript is now its own view
(`TranscriptView`, rows in `TranscriptRows`) with no binding: the button
scrolls through a `ScrollViewReader` to an anchor under the last row, and
`changedFiles` is read in a slot view of its own. The tool cards' diff
cache went from 32 pairs (cleared when full, so scrolling a long chat
re-diffed every card) to 512.

### D121. Output follows only from the bottom of the transcript

Scrolling up a long chat made the content jump and the scroller resize.
Measured first (Time Profiler and Animation Hitches while scrolling): the
window held ~120 fps and the main thread stayed under 20%, so it wasn't
dropped frames. Two causes: `LazyVStack` guesses the height of rows it
hasn't made yet, and the scroll view was anchored to the bottom for every
size change, so output arriving while you read above moved what you read.

- `defaultScrollAnchor(.bottom)` only for the initial offset; for size
  changes the bottom only while you're at the bottom, the top otherwise.
- The rows stay in a `LazyVStack` (the author's call). A plain `VStack`
  of the last 150 rows with "Show Earlier" was tried: no guessed heights,
  but the author preferred the lazy stack, so the guessed heights stay
  as a known gap.

### D122. Tool calls fold like Claude Code: quiet lines, runs as "Ran 4 commands"

Even with reads folded (D116) a turn was a stack of framed cards — every
command, edit and thought its own box — and the answer got lost among
them. Now as in Claude Code's desktop chat:

- A tool call is one secondary line ("Read Transcript.swift ›"), no frame,
  no icon, no check mark when it succeeds (only a spinner, a red ✕, the
  diff counts). It opens into its details; diffs no longer open by
  default — changes are reviewed inline in the editor (D7).
- Two or more calls in a row, with the thoughts between them, fold into
  one line: "Read 3 files, ran 2 commands ›" (kinds in the order they
  came, "N failed" in red, the running call and a spinner while folded).
  It opens into a framed list of the calls, a line each.
- Only a call asking for permission keeps a frame and stays out of the
  fold, so the question is never hidden; answered, it folds with the rest.
- A call opens only when there's something to see: no chevron for a
  command that printed nothing and succeeded, or whose command is its
  title (`TranscriptEntry.hasDetails`); fenced output ("```console") is
  taken apart, an empty fence counts as nothing.
- Color where it carries meaning: code in a title's backticks ("Run
  `make build`") in code type and full color on the gray line; the
  command (as bash), fenced output and the code blocks of replies are
  colored by the editor's highlighter, now also reachable by a fence's
  language (`SyntaxHighlighting.highlight(_:language:)`, `HighlightedCode`).
- Your messages are a tinted bubble on the right, so a turn's start is
  easy to find among the agent's lines.
- Replies may carry HTML `<details><summary>…</summary>…</details>` (Codex
  folds its screenshots so) and images alone on a line (`![alt](path)`):
  `MarkdownText` folds the first like GitHub and shows local images (a
  click opens them); remote or missing ones show their alt text.
- The separate mode button by the composer (D120) is gone: the options
  button already sets the mode, two controls for one setting was clutter.

### D123. Explorer folders open and close without animation

Sometimes a copy of the previously selected file's row stayed drawn over
the tree, highlight and all, overlapping the rows that moved under it
(seen right after clicking a folder). A click on a folder both toggles it
— animated, so the outline view slides rows in and out — and moves the
highlight (`listRowBackground`) from the file's row to the folder's; the
row reconfigured mid-animation was left behind as a stale view.

Expanding and collapsing are now instant (`FileTreeModel.setExpanded`,
animations disabled), on a row click and on the chevron alike — as in
VS Code and Cursor. Unverified that this was the only trigger: it showed
up only now and then.

### D124. The usage popover: context first, plan limits for Claude and Codex, remembered

The ring's popover was a plain list, and plan limits showed only after
Claude happened to report one in that chat. Now:

- **Layout**: the agent and model with the plan's name; the context as a
  large ring with its percentage, tokens used and left, and **Compact**
  (`/compact`, when the agent offers it and is idle); then plan limits —
  a bar each, "Resets in 2h 14m · 18:40", a note ("Using extra usage",
  "Close to the limit"), "Updated 3 minutes ago"; then this chat's cost and
  tokens. A window whose reset time passed shows as empty again.
- **The ring** shows its percentage from half full, and a dot (orange,
  red when reached) when a plan limit is at 90% or reached.
- **Claude**: the adapter forwards Claude Code's `rate_limit_event`s
  (`_claude/rateLimit` in `usage_update`), one window at a time. The full
  picture only comes from `/usage`, an experimental SDK call that prints
  Markdown into the chat — not used.
- **Codex**: codex-acp reads the limits from the app server but gives
  them only to `/status` as text. Codex itself writes them into its
  session logs with every turn (`token_count` → `rate_limits`: windows,
  plan, credits), so `CodexLimits` reads the newest log's tail
  (`$CODEX_HOME` or `~/.codex/sessions`): no network, no credentials.
  Read when a chat opens, after each turn and when the popover opens;
  **Full Status** sends `/status` for the rest.
- **Remembered** (`LimitsMemory`, UserDefaults per agent): a new chat
  shows the last limits before its first reply; a newer report wins.
  Replayed history never updates them.
- Other agents report no limits; the popover says so.

### D125. Review comments: notes on agent changes in the editor, sent to the chat together

Reviewing had only Keep and Undo; "this is wrong, redo it" meant switching
to the chat and describing the place by hand. Now, like a GitHub review:

- **Writing**: each change block's bar gets a comment button left of
  Undo; ⌥⌘/ (Review menu, the editor's menu) comments the block at the
  caret, else the selected lines of any code. A popover takes the note:
  Return adds, ⌥↩ breaks the line, Cancel / Esc drop the edit, clicking
  away keeps it (Xcode's notes do the same). A block with a note shows it
  in its bar; a note off any block (kept since, or on plain code) hangs at
  the end of its first line. Clicking either reopens it (Save / Delete).
- **Sending**: the notes wait above the composer ("3 comments for the
  agent", expandable, click a row to open its place) with Discard and
  Send. Send makes **one message** to the open chat: each note under its
  file, current lines and code, and the lines the agent removed there.
  A working chat queues it (D88); a chat whose agent isn't up yet gets it
  in the composer. "Send Review Comments to Agent" is a command too.
- **Anchoring**: a note keeps the code it was written on and finds it
  again nearest its old line after edits above (`ReviewComment.located`);
  code that's gone falls back to the old line.
- **Model**: `ReviewComments` in OrbitAPI, implemented by the Agents
  plugin (one store per window); the editor reads and writes notes
  through it and shows no comment button without it.

Not kept across launches, and one store per window rather than per chat:
the chat that's open when Send is pressed gets them all.

### D126. The open folder is watched: changes made outside Orbit show up by themselves; the window title is the project's name

`Workspace.fileSystemGeneration` was bumped only by Orbit's own actions
(agent tool calls, git, explorer and search operations, Refresh Explorer):
a file added in Finder or a terminal never appeared in the tree.

`FolderWatcher` (Explorer plugin, one per window) runs an FSEvents stream
on the open folder and calls `workspace.fileSystemDidChange()` — the tree's
open folders reload, git badges and open files (D33's disk sync) follow.
Ignored: `.git/` internals (our own `git status` rewrites the index: it
would loop), the insides of `node_modules/` and `.build/` (thousands of
events per install or build; the folder itself appearing is seen), and
`.DS_Store`. At most one refresh a second while Orbit is in front, one
every three seconds behind it (a build in a terminal shouldn't keep git
busy), and a pending one runs at once when Orbit comes back to the front.

The window's title is just the project's name: the active file's path in
the subtitle made the Dock's window list (and the Window menu) unreadably
long, and the title bar is hidden anyway (D42).

### D127. ⌘K edits the selection with a hidden agent; the result is an inline agent change

Cursor's most used feature after the chat: select code, say what to do,
see the change in place. **Edit with Agent… (⌘K**, the editor's menu,
Agents menu):

- A popover over the selection takes the instruction (Return runs, Esc /
  Cancel stops). Without a selection it writes code at the caret: into a
  blank caret line, else on a new line after it.
- It runs on `AgentCompletion` (the hidden, read-only session that writes
  commit messages): the default agent, low effort, read-only mode, kept
  warm (prewarmed when the popover opens). The prompt gives the file's
  path, the lines (or 8 lines around the insertion point) and asks for
  only the code in one fenced block; the agent may read the project.
- The reply's first fenced block replaces the lines **in the buffer**
  (unsaved, like typing), after `recordBaseline` of the buffer: it shows
  as an agent change with Keep / Undo and a comment button (D7, D125), so
  nothing new had to be built for reviewing it.
- If those lines changed while the agent worked, nothing is applied and
  the popover says so. Clicking away hides the popover; the agent keeps
  going and its edit still lands.

Not a chat: no follow-ups ("make it shorter") yet — run ⌘K again on the
result. Uses the default agent's model, not a picker of its own.

### D128. Tasks: the project's scripts run from a picker, each in its own terminal tab

Running `npm run dev` or `make test` meant opening a terminal and typing it.
Now **Run Task… (⌃⌘R)** lists what the project defines, and **Run Last
Task (⌘R**, Xcode's Run key) repeats the last one (the picker when there's
none yet).

- **Found, not configured** (`ProjectTasks`, read when the picker opens):
  package.json scripts with the lockfile's tool (bun, pnpm, yarn, else
  `packageManager`, else npm), Makefile targets (with `## description`;
  no variables, patterns or file targets), deno.json tasks, composer.json
  scripts, and the usual commands of Package.swift, Cargo.toml and go.mod.
  Anything else goes in `.orbit/settings.json`: `"tasks": {"name":
  "command"}` or a list of `{"name", "command"}`; the empty picker points
  there.
- **Run in a terminal tab of its own**, titled with the command and
  marked with a play icon: a login shell in the project with the command
  typed in, so its output stays, ↑ brings it back and the shell's
  environment (nvm, PATH) is the user's. Running the task again restarts
  it in the same tab: ⌃C first when something is still running there
  (the pty's foreground group isn't the shell), then the command.
- It lives in the Terminal plugin: tasks are terminal tabs, no service
  needed.

Not done: problem matchers (errors in the output → Problems), a status
bar indicator of running tasks, tasks of nested packages in a monorepo.

### D129. Releases: Sparkle updates from GitHub Releases; ad hoc signing until a Developer ID

The author ran Debug builds from the repo. Now a release is three commands
(`scripts/release.sh`, wrapped by the Makefile):

- `make release-setup` (once): Sparkle's `generate_keys` makes the EdDSA
  key pair — the private half stays in the login keychain, the public one
  is written into `App/Info.plist` (`SUPublicEDKey`) to commit.
- `make release VERSION=0.2.0`: a Release build with that version and the
  commit count as build number, zipped with `ditto`, and an `appcast.xml`
  from Sparkle's `generate_appcast` (signs the zip with the keychain key;
  only the newest release is listed — Sparkle needs nothing more).
- `make release-publish VERSION=0.2.0`: `gh release create v0.2.0` with
  the zip and the appcast, notes generated from the commits.

**Hosting**: the repo is public, so GitHub Releases serve both files;
`SUFeedURL` points at `releases/latest/download/appcast.xml`, so the
newest release's appcast is always the one read. Automatic daily checks
are on (`SUEnableAutomaticChecks`, no first-launch question); **Check for
Updates…** sits in the app menu.

**Signing**: the author has no Developer ID yet (only someone else's
certificates on this Mac), so builds are signed ad hoc without the
hardened runtime: Gatekeeper asks once on the first launch (right click →
Open); Sparkle checks updates by their EdDSA signature, which doesn't need
a Developer ID. With one, `DEVELOPER_ID` and `TEAM_ID` in the environment
switch the same script to a hardened build with `App/Orbit.entitlements`
(`disable-library-validation`: grammar dylibs compiled on the Mac, D71),
notarization through the `orbit-notary` keychain profile and stapling.

The updater doesn't start in Debug builds or while `SUPublicEDKey` is
empty, so a development build never replaces itself. Sparkle is pinned
exactly (2.10.0): the generated project's Package.resolved isn't in git.

### D130. All agents at a glance: an overview of every window's chats; Allow / Deny in notifications

With a window per project (D101) and parallel chats in each, finding the
agent that waits for an approval meant visiting every window.

- **Overview**: the status bar's agents item counts every window's working
  and waiting chats and opens a popover (also **Show All Agents ⌃⌘A**):
  each started chat with its agent, title, project (when there are
  several), and what it's doing — waiting for a permission (with Deny /
  Allow right there), working with a live timer, stopped with the error,
  done with the last turn's time and changed files, or idle. Waiting
  first, then working. A click brings that chat's window to the front and
  selects it.
- `AgentDirectory` (OrbitAgents) holds every window's `AgentStore`
  weakly and drops one on shutdown, like the notification router (D87):
  a closed window still frees everything (D101). Windows come forward
  through `Workspace.bringWindowToFront`, set by the app.
- **Notifications**: a permission's notification has **Allow**, **Always
  Allow** and **Deny** buttons (a notification category). The answer goes
  to that exact request (its id travels in the notification), without
  bringing Orbit forward; a request already answered in the app is left
  alone. Clicking a notification now also brings its window forward.

### D131. Queued messages and review notes survive a relaunch

Messages queued while the agent works (D88) are saved with the chat's tab
(`SavedSession.queued`: text and attached files; images and editor
selections aren't kept) and come back paused — "Send Now" goes on. Review
notes (D125) are saved per project folder in the Agents plugin's settings
and come back with the folder.

### D132. Rewind: the chat goes back with the files

D85 restored only files. The ↺ on a message now offers **Rewind Chat and
Files** beside **Restore Files Only**: the files go back as before, and the
message and everything after it leave the transcript; the message (with
its attachments) returns to the composer to edit and send again, like
Claude Code's `/rewind`.

ACP has no way to cut an agent's own history, so the agent still remembers;
its next prompt starts with a note to disregard that message and all that
followed (and whether the files were restored). Restore points of removed
messages are dropped. A reloaded conversation (`session/load`) replays the
agent's full history, the rewound part included.

### D133. Isolated sessions become pull requests

An isolated session's work could only be applied to the project. Its bar
now also has **Create PR**: a sheet with the title (the chat's), a branch
(`orbit/<words of the title>`) and a description (the agent's last reply),
then:

- In the **copy** (an APFS clone with its own `.git`, D35): a new branch
  from the branch the copy was on, a commit of **only the files the agent
  changed** (the shadow snapshot's diff: the user's uncommitted work copied
  along stays out), `git push -u origin`, and `gh pr create` against that
  base. The project's checkout is never touched.
- `gh` runs with the login shell's environment (PATH); it must be installed
  and logged in — checked first, with a hint when it isn't.
- The pull request's URL is kept with the copy (`IsolatedCopy.pullRequest`)
  and the bar shows **PR #12** with its state and checks from
  `gh pr view --json number,state,statusCheckRollup` (refreshed every
  minute while Orbit is in front); a click opens it on GitHub.
- Implemented in the Review plugin beside the rest of the copies
  (`AgentIsolation.publish / pullRequestStatus / baseBranch`).

Not done: updating the pull request after more agent turns (push again),
non-GitHub remotes, a commit message from the agent.

### D134. Merge conflicts are resolved in the editor

A conflicted file opened as raw `<<<<<<<` text. Now the editor finds the
blocks itself (`MergeConflicts`, any file with markers, from a merge,
rebase, cherry-pick or stash pop; diff3's `|||||||` base too):

- The current side is tinted with the theme's added color, the incoming
  side blue, the base grey, the marker lines faint; each block's marker
  line carries **Accept Current · Accept Incoming · Accept Both** (one
  undoable edit each, through the text view).
- A banner counts the conflicts, steps through them and has **Accept All**
  (current / incoming / both). Once no markers are left in a file git
  still lists as conflicted, it offers **Mark as Resolved** — `git add`
  through `ConflictResolving`, implemented by the Git plugin.
- No three-pane merge editor: the inline blocks are the same idea as the
  inline agent review (D7) and cover the common cases.

### D135. Blame for every line, beside the line numbers

*Replaced by D187: the column is gone; blame is shown after the caret's line.*

The status bar named the caret line's author only. **Toggle Blame (⌥⌘B**,
Git menu; also Settings → Editor) adds a column left of the line numbers,
like Xcode's Authors: each run of lines from one commit shows the author
and a short age ("3mo"), with an age bar (strong for this week, faint for
last year) on every line; uncommitted lines say so. A click opens what that
commit changed in the file. Blame runs on the editor's text (unsaved edits
don't shift it), again after a pause in typing and after commits;
`LineBlaming` is implemented by the Git plugin. It no longer requires the
gutter's change markers to be on.

### D136. History of any branch, searchable, with a graph

History showed the current branch's last 200 commits. Now:

- **Scope**: Current, All branches (`--all`, 400 commits) or any local
  branch, from a menu at the top of the section.
- **Search** (after a pause): commit messages and authors, any case, plus a
  hash prefix; up to 300 results, newest first.
- **Graph**: commits are listed in topological order with their parents
  (`%P`); `GitGraph` gives each a lane and each row the lines crossing
  it, drawn in a narrow column (up to 8 lanes, colored by lane). Hidden
  while searching (the results aren't a connected history).
- Branch and tag names (`%D`) show as small badges on their commits.
  (Rows changed in D156: two lines, merged badges.)
- Commits expand in place (the row's chevron) into their files; the file
  rows carry the graph's passing lines, so it doesn't break. Rows are
  exactly as tall as their graph cell.

### D137. Tasks' errors go to Problems and the editor

A task's tab reads what it prints (`TaskOutputParser`, Terminal plugin):
`tsc` (both forms), `file:line:col: error|warning: …` (clang, Swift, Go
without a severity, `tsc --pretty`), Rust's `error[E…]` + `--> file:line:col`
and ESLint's stylish blocks (a file path line, then `line:col  error  …  rule`).
Colors and cursor moves are stripped; a lone `\r` (a progress bar) replaces
the line. A line counts only when its file exists (relative to the task's
folder, then the project), so log lines that look like errors don't.
`note:` / `help:` lines are skipped; at most 1000 per task.

Problems are per tab and from its last run: running the task again, a
cleared screen (watch modes) or closing the tab drops them. They reach the
Languages plugin through a new `TaskProblems` service (plugins don't import
each other): the Problems panel and `diagnostics(for:)` (so the editor's
squiggles) merge them with the servers', minus those a server reports too
(same line and message: `tsc` and tsserver).

### D138. Running tasks in the status bar; tasks of monorepo packages

Whether a task still runs is the terminal's foreground process group
(not observable), so the store looks every second while there are task
tabs, and stops when there are none or the window closed. The status bar
shows "▶ dev" (or "▶ 2 tasks") with a menu per task: Show Output, Restart,
Stop (⌃C); a running task's tab icon is a green ▶.

Run Task… also lists each workspace package's scripts: patterns from
`workspaces` in package.json (a list or `{packages: […]}`) and from
pnpm-workspace.yaml's `packages:`; `*` is one folder, `**` any depth up to
four, `!` excludes, `node_modules` and hidden folders never count. Such a task
starts its tab in the package's folder with the root's package manager; its
source reads `apps/web/package.json`.

### D139. Box selection by ⌥-drag

⌥-click still adds or removes a caret (D105); dragging from it selects the
same columns (by pointer position, so tabs and wide characters line up as
drawn) on every line between: a caret per line when the drag is straight
down, else a piece of each line, clamped to short lines' ends. It's the
multiple selections STTextView already edits; the line starts are taken
once at the press.

### D140. Format Selection: the whole file formatted, only the selection's changes kept

Prettier, Ruff, gofmt and the servers format whole files the same way;
range formatting is spotty. So with text selected, ⌃⇧I (and Format Selection
in the editor menu) formats the whole text as usual, then keeps only the
changed lines touching the selected ones (`LineDiff.changes(from:to:within:)`;
a block the same size on both sides is taken line by line). The result goes
in as one edit over just the differing span, so the caret and scroll outside
it stay. The toast says "Formatted selection · Prettier".

### D141. Large files open in a light mode

A file over 2 MB, over 50,000 lines or with a line over 20,000 characters
(minified code) is a `LargeFile`, checked once at load. The editor then has
no syntax highlighting, language server (it isn't even opened there), inlay
hints, sticky scroll, indent guides, git markers or blame, and format on save
is skipped; a minified file wraps lines, so layout stays with the visible
part. A banner says why, with Turn On for everything (the document's
`usesAllFeatures`, for as long as it's open). Agent changes still show inline:
reviewing them is the point (D7). The 50 MB limit (D106) stays for opening at all.

### D142. `orbit` in the terminal opens folders and files

Orbit → Install 'orbit' Command… writes a small shell script to
/usr/local/bin/orbit (asking for the password when the folder is root's). The
script checks its paths exist and runs `open -b dev.orbit.app "$@"`: by bundle
id rather than a symlink into the app, so it keeps working when Orbit moves or
updates. No argument means `.`. Folders open as before (D102). A file opens in
the window whose project contains it; otherwise its project opens first (the
git repository around it, else its folder) and then the file. No `file:line`
yet: `open` can't pass it.

### D143. A built-in browser for dev servers, in editor tabs

A page is an editor tab (kind `browser`, one per host and port), so it splits,
sits beside code and comes back with the window like any tab, from the Preview
plugin (`WebPreviewing` service). The tab's WKWebView lives as long as the tab
(state and scroll survive tab switches) and stops when the tab closes. A slim
bar has back, forward, reload / stop, the address and Open in Default
Browser; right-click → Inspect Element opens Safari's Web Inspector. A local
page that can't connect (a dev server still starting) retries every 2 s for a
minute. `target=_blank` stays in the tab.

Tasks remember the first local address they print (Vite's "Local:",
Next's, `0.0.0.0` becomes localhost; `LocalServers` service): the running-task
menu has "Open localhost:5173 in Orbit", and Open Browser… (View) lists those
first, then this window's recent pages. Not a general browser: no tabs inside
it, no find, no device sizes.

### D144. Later agent turns are pushed to the pull request

After Create PR (D133), each turn's end (and the badge's minute refresh)
counts the agent's files whose changes aren't committed in the copy; the bar
then shows Push N. It commits them on the pull request's branch, with the
last request's first line as the subject, and pushes (`git push`), which
updates the PR. Hidden once the PR is merged or closed.

### D145. SVG opens as its picture; Show Source flips the tab to the code

Clicking an SVG shows the picture, in the file's own tab (a provider above
the text editor, like images). Show Source (top right), ⇧⌘V or the eye
button flips that same tab to the code editor and back: the tab stays one
per file, only how it's drawn changes (`SVGSourceMode`, per window). The
command, still `preview.markdown` for set shortcuts, is now "Toggle Preview";
for Markdown it still opens the preview to the side (D89).

AppKit draws SVG itself (`NSImage(data:)`, no WebKit), from the open buffer,
so the picture follows unsaved edits and an agent's; while the text doesn't
parse, the last good picture stays with a note. It fits the view, upscaled
(vector), keeps its zoom across redraws of the same size, and sits on a
checkerboard, light or dark backdrop for its transparent parts. An agent's
changes to an SVG are reviewed inline in the source view (D7).

### D146. Image thumbnails beside the line numbers

As in JetBrains IDEs: a line that names an image file that exists
(`./logo.png`, `@/assets/icon.svg`, `/hero.webp` from `public/`, `url(bg.png)`)
gets a 16-pt thumbnail in a gutter column after the change bars. Paths are
looked up relative to the file, then the project and `public`, `static`,
`src`, `assets`; `@/` and `~/` mean `src`; web addresses are never fetched.
Found off the main actor after a pause in typing (first 20,000 lines, one image
per line); bitmaps are shrunk with ImageIO off the main actor. Hover shows it
bigger with its name, click opens it. The column only exists while the file has
any. Settings → Editor → Show image thumbnails; off in large files (D141).

### D147. Fix with Agent from the Problems panel

A problem row has a sparkles button on hover and a context menu: Fix with
Agent, Fix All in “file”, Fix All Errors, Copy Message. It drafts a new chat
(`AgentTasks.draftTask`, so the user reads it before sending) with each
problem as `path:line:col severity (source): message` and the code around it
(three lines each side, the line marked `>`), at most 30 per file. Task
errors (D137) included: a failed build is one click from a fix.

### D148. ⌘-click a path in the terminal opens it in the editor

SwiftTerm already finds paths under the pointer (Ghostty's rules: with a
slash or `./`, `~/`, `/`) and hands a ⌘-click to `requestOpenLink`. Orbit's
terminal view takes it first: `file:line:col`, `file:line`, `file(line,col)`
and `file://` resolve against the tab's folder, then the project's, and open
at that line; web links and paths that don't exist go on to the default
handling (the browser). A bare name without a slash (`main.swift:3`) isn't a
link to SwiftTerm, so it isn't one here.

### D149. Color swatches beside the line numbers, edited with the color panel

As JetBrains does, in the gutter column of D146 (an image wins when a line
has both): `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`, `rgb()/rgba()` and
`hsl()/hsla()` with commas or spaces and `/ alpha`; the first per line. In
Markdown and plain text a digits-only `#123` is an issue number, not a color;
`&#123;` never is. Transparent colors sit on a checkered half. A click opens
the system color panel; each change rewrites the literal in its own notation
(case of hex digits, commas, rgb vs rgba kept; alpha added only when below 1).
One object is the panel's target (AppKit doesn't retain it) and points at the
literal being edited. Not inline in the text: that would need space the
layout doesn't have (inline diff gaps are paragraph styles, D14).

### D150. Copy GitHub Link and Open on GitHub

In the editor's right-click menu and Git menu: a permalink to the selected
lines (or the caret's) at the commit the host has: HEAD when a remote branch
contains it, else the upstream's commit, since unpushed commits 404. The
remote is `origin` or the first one; ssh, scp-like and https forms become
`https://host/owner/repo`. GitLab (`/-/blob/…#L1-5`) and Bitbucket
(`/src/…#lines-1:5`) get their own shapes, everything else GitHub's.

### D151. Text transforms: sort, dedupe, reverse lines; change case and naming style

Code menu and palette (not the right-click menu, which would grow too long):
Sort Lines Ascending / Descending (natural order, `a2` before `a10`), Remove
Duplicate Lines, Reverse Lines on the selected lines, or the whole file
without a selection (its final newline stays last); Transform to UPPERCASE,
lowercase, Title Case, camelCase, PascalCase, snake_case, kebab-case,
CONSTANT_CASE on each selection or the word at each caret. Words split at
separators and case changes, acronyms kept (`HTTPServer` → HTTP, Server).

### D152. Images pasted into Markdown are saved in assets/

⌘V in a Markdown file with an image on the pasteboard (a screenshot) writes
`assets/image-<date-time>.png` beside the file and inserts `![](assets/…)`.
Image files copied in Finder are linked where they are when inside the
file's folder, else copied into `assets/` (a name taken gets `-2`); paths with
spaces go in angle brackets. Text on the pasteboard pastes as usual, and
other files aren't touched.

### D153. The Mac stays awake while an agent works; a sound when one finishes

While any window's agent is working, Orbit holds a PreventUserIdleSystemSleep
power assertion (`AgentWakeLock`, app-wide like the agents directory, D130),
released when none is; closing the lid still sleeps, which apps can't stop.
When an agent finishes or fails in the background and no notification can say
so (turned off, or not allowed), the Mac plays Glass / Basso; the Dock badge
counts as before. Both are on by default, in Settings → Agents.

### D154. A stash's files and diffs in the Source Control panel

Stashes were listed with Pop, Apply and Delete. Now a row expands (its chevron,
a double-click, or Show Files) into its files, and a file opens its diff:
a stash is a commit on top of HEAD, so its files and sides are the commit's
against the first parent (`%H` added to `git stash list`). Untracked files
stashed with `-u` live in a third parent and aren't listed.

### D155. The terminal's editing keys, as in Terminal.app and iTerm

With ⌥ typing characters (accented letters, `@` on some layouts), SwiftTerm
dropped ⌥←/→, ⌥⌫, ⌘⌫ and gave ⇧↩ no meaning. Orbit's terminal now sends what
readline, zsh, Claude Code and Codex bind: ⌥←/→ ESC b / ESC f (word), ⌘←/→
⌃A / ⌃E (line start / end), ⌥⌫ ESC DEL and ⌥⌦ ESC d (delete a word), ⌘⌫ ⌃U
and ⌘⌦ ⌃K (to line start / end), ⇧↩ and ⌥↩ ESC CR (a new line in an agent's
prompt). ⌘K clears the scrollback and sends ⌃L so the shell redraws;
⌘↑/⌘↓ scroll to the top / bottom of the scrollback. Matched by key code
(any layout), only while the terminal has focus, through a local key monitor:
SwiftTerm's `keyDown` isn't open, and ⌘K would otherwise reach the editor's
Edit with Agent in the menu first.

### D156. History rows on two lines; one badge per branch; a calmer graph

In a narrow sidebar a one-line row showed "feat: add cls-…", and a commit
with branches showed only its badges, its message pushed out. Now a row is
two lines, 38 pt: the message across the whole width, then the badges,
author and a short age ("3d", "2w"); the full date, hash and message stay in
the tooltip. The chevron is gone: a click (or Show Files) lists the files,
and the row is shaded while open or hovered.

Badges: a local branch and its `origin/` (or `upstream/`) copy are one
badge with a cloud-check; `origin/HEAD` and `HEAD` are dropped; the checked-out
branch comes first, filled; remote-only branches are grey with a cloud, tags
orange; at most two, then "+N".

Graph: lanes 12 pt apart (were 10), 1.6-pt round-capped lines; bends have
vertical ends over a taller half row, so a lane change reads as one S, not a
hook; merge commits are rings, the checked-out commit has a halo.

### D157. Corner, fill and badge tokens in `Theme`

After D117 the type was one system, but shapes and states weren't: 11
corner radii (3–18), selected rows tinted at 0.12, 0.15 or 0.18 of the accent
(some through `.tint`, which sheets and popovers don't always inherit),
hovers at 0.027, 0.045 or 0.09 of the text color (`subtleFill.opacity(2)`),
seven hand-made capsule badges, chevrons at 7, 8 or 9 pt. Each panel was
slightly its own. Now `Theme` has one set:

| Token | Value | For |
|---|---|---|
| tinyCorner | 4 | key caps, inline buttons, thumbnails, the rename field |
| smallCorner | 6 | rows, tabs, toggles, fields, code blocks, the editor's bars |
| corner | 10 | cards, tool calls, rows in floating panels |
| largeCorner | 14 | big cards, popovers, chat bubbles |
| panelCorner | 18 | floating glass: palette, tab switcher, composer |
| subtleFill | text 4.5% | resting cards, fields, quiet badges |
| hoverFill | text 6.5% | a row or button under the pointer |
| activeFill | text 9% | the current tab, a pressed button, a key cap |
| selectedFill | accent 16% | the keyboard's row in a list, a toggle that's on |
| matchFill | accent 25% | matched text in results |
| dropFill / dropBorder | accent 10% / 60% | drop targets |

Radii were rounded to the nearest step (3–4 → 4, 5–7 → 6, 8–9 → 10, 12–14 →
14, 16–18 → 18), so the composer went 16 → 18 and popovers 12 → 14. Every
tab (editor, bottom panel, terminal) is `activeFill` when current; every
keyboard selection is `selectedFill`, always `Theme.accent`. `Badge` (count,
text or any label; gray, or tinted, `prominent` for the current one) replaces
the capsule counters, the hash, "Staged", the plan name and the branch
badges; `DisclosureChevron` is the one rotating "›" (8 pt bold) and other
small symbols use `TypeScale.glyph`. Chat bubbles and editor banners keep their own
tints: they aren't states.

### D158. Settings laid out like System Settings: groups, tiles, header cards, pages

Settings had eight panes in one flat list with grey icons; Agents and
Languages were long sheets (defaults, installed, the whole registry, custom
agents, MCP servers in one form), the project and About hid in General. Now it
follows macOS 26/27 System Settings, still inside the window (D36):

- **Sidebar**: the open project on top, like the Apple Account row (its pane
  lists what `.orbit/settings.json` overrides, with Open / Create). Then
  groups (`SettingsGroup`): app — General, Appearance, Notifications; code —
  Editor, Languages, Formatting, Source Control; agents — Agents, MCP Servers;
  customization — Keyboard Shortcuts, Extensions, Plugins. Each pane has a
  colored tile (`SettingsPane.tint`, `SettingsTile`: white symbol on a
  gradient squircle).
- **Pane**: a top bar with back / forward in a glass capsule (⌘[ ⌘], a
  history of panes and pages) and the title; the page scrolls under it
  (`safeAreaBar`, so it fades out there). The form is at most 720 pt wide,
  centered. Its first card is the pane's tile, name and one-line summary
  (`SettingsForm` reads `settingsPaneInfo` from the shell).
- **Split up**: Appearance left General (mode as three window thumbnails in
  the picked themes' colors, then themes and icons); Notifications left
  Agents; MCP Servers and Formatting got their own panes; General is about
  Orbit itself (version and updates, the `orbit` command, the global
  settings file and folder).
- **Pages instead of sheets**: rows with "›" (`SettingsLink`) open a page
  in the same pane — Get More Agents (the registry, with search), Add a
  Custom Agent, Not Installed language servers, the extension catalog (from
  Extensions and from Appearance → Browse Themes). The Installed / Catalog
  tabs are gone; the try-on bar's Catalog opens the catalog page.
- Editor's options are grouped by where they show: Font (size, preview,
  terminal size), Text, Beside the Line Numbers, Reading Code, Saving.
  Language rows show at most six file types (+N, all in the tooltip) and one
  status line; agents and extensions get icons on tiles too.

Plugins build panes from `SettingsForm`, `SettingsLink`, `SettingsLabel` and
`SettingsSearchField` in OrbitUI, so a plugin's pane looks like the rest.

### D159. System empty states; numbers and symbols animate like Apple's apps

`EmptyStateView` drew its own icon, title and message in 25 places; it now
wraps SwiftUI's `ContentUnavailableView`, so empty panels have the system's
type and spacing, and buttons go into its actions (Initialize Repository,
Browse Agents, Try Again) instead of floating below. Settings search shows
`ContentUnavailableView.search`.

Nothing animated before. Now counts roll their digits (`numericText`): badges
(`Badge(count:)`, the Problems count), `DiffStatBadge`'s +a −r, "N files
changed", "N to review", the branch's ↑↓. The hand of a chat waiting for
permission wiggles every few seconds; copy buttons and the terminal tab's
play / terminal icon swap with the symbol replace effect. The References
panel got the link icon: it shared Source Control's branch.

### D160. The welcome screen laid out like Xcode 26's welcome window

A window without a folder (D101) showed a column: the icon and name, two
cards, then recent folders as hover rows. It's now laid out as Xcode 26's
welcome window, filling the window itself (a card in the middle left a
pointless frame of window around it — Xcode's is a window of its own, ours
can't be smaller than 960 × 600): on the left the app icon, Orbit, its
version and the actions (Open Folder… ⌘O, Clone Repository…, each with a
tile and a line on what it does); on the right, in a full-height column
like a sidebar, the recent projects as a list with Finder's folder icon, the name, the checked-out branch (read from
`.git/HEAD`, no git process) and where it lives. As in Xcode, a click selects
a project and a double-click or Return opens it; right-click opens, shows in
Finder or removes it from the list.

### D161. Command palette and Open Quickly look like Spotlight

The quick pick (⇧⌘P, ⌘P, the theme selector and every plugin's picks) was
a 580-pt panel with a 15-pt query and one-line rows: "Category  Title"
for commands, the shortcut as plain text. It now reads like macOS 26's
Spotlight: a 640-pt glass panel with a 20-pt query and magnifier
(`TypeScale.large`), rows 44 pt high with the icon on a tile (files keep
their own icon), the title over a dimmed detail line — a command's
category, a file's folder — and shortcuts as key caps. The result list is
as tall as its rows, up to 400 pt, instead of always taking the maximum.

### D162. Alerts and open panels are sheets on the window

28 places ran `NSAlert.runModal()` / `NSOpenPanel.runModal()`: a separate
dialog in the middle of the screen that blocks the whole app. macOS puts
these on the document window as sheets (Pages' "Save changes?"). Every call
now goes through `runSheetModal()` (OrbitAPI/SheetModal.swift): the alert or
panel slides down from the key window, and the caller still waits for the
answer — `beginSheetModal` stops a modal session run for the sheet — so code
written for `runModal()` (confirmations inside window closing, quitting,
discarding) works unchanged. With no window to hang it on, or a sheet
already showing, it falls back to a plain dialog. New alerts and panels
should use `runSheetModal()` too.

### D163. The chat: Claude Code's flow, Apple's look

The chat keeps everything D120–D122 took from Claude Code (folded runs of
calls, the pinned plan, timed thoughts, Esc / ↑ / ⇧Tab, "Worked for … ·
N files changed · Review") and looks more like a Mac app:

- Every tool call has its kind's symbol in front (ACP's kinds: a page for
  reads, a pencil for edits, a terminal for commands, a magnifier for
  searches…), red when it failed.
- An expanded run of calls is one filled card with divided rows; a row's
  details (a diff, a command's output) sit in that card instead of a second
  box inside it. A lone call still gets its own box.
- A command that exited cleanly says nothing under its output (no "Done");
  Show in Terminal is a small icon button, Stop stays a button while it runs.
- The turn summary starts with a filled green check.
- The composer's attach button is a round glass "+", like Messages'; the
  context indicator is a small filled pie, since an empty ring at rest read
  as a spinner that never stopped (the popover keeps the ring).

- Inline `code` in replies is a soft red on a quiet fill (`Theme.inlineCode`),
  as in Claude Code, so names and paths stand out of the prose.
- Text for work in progress ("Thinking…", the "Working…" line, a running
  call's title) shimmers (`.shimmer()` in OrbitUI), still under Reduce Motion.
- The changed-files bar sits close to the composer: the composer's margin is
  the only gap between them.
- The "Working…" line no longer repeats a live row: while a thought streams
  or a call runs, that row shimmers and the line just says "Working…" with
  the timer (it used to show "Thinking…" twice). This changes D121's line,
  which named the running call.

### D164. Editor overlays are kept between layouts, not rebuilt

With an agent change on screen Orbit sat at 100% CPU doing nothing, and
scrolling stuttered in the whole window (editor and chat alike). The inline
diff, squiggles, bracket and symbol highlights, inlay hints and fold
placeholders all removed and re-added their views on every viewport layout;
that re-dirtied the text view, which laid itself out again on the next frame,
forever (the Keep/Undo bars were new `NSHostingView`s each time).

- Overlays go through `OverlaySet` (OrbitEditor): each pass places views by a
  key covering what the view was made with; a known key reuses the view and
  only moves it when its frame changed, and `commit()` removes the rest.
- A pass that changes nothing touches no view, so layout settles: idle CPU
  went from ~100% to 0 on the same file.
- New overlays use it too; never remove-and-re-add on `onDidLayoutViewport`.

### D165. The everyday build is optimized

The author uses the app `make run` builds (Debug), and Debug compiled every
Swift module at `-Onone`: STTextView, the editor plugins and the chat views
ran several times slower than in Release. A profile of scrolling a long file
after D164 showed no wasted work left, only text, gutter and overlay drawing
in unoptimized code.

- `make build` / `make run` pass `SWIFT_OPTIMIZATION_LEVEL=-O` and
  `GCC_OPTIMIZATION_LEVEL=s` (tree-sitter grammars are C): Release speed,
  still `DEBUG` with its debug commands. A full build takes ~1.5 min, an
  incremental one ~10 s.
- Xcode's own builds (previews, the debugger, the Xcode MCP) keep the
  project's `-Onone`; `project.yml` is unchanged.

### D166. The empty editor: quiet, like Xcode's "No Editor"

With no tab open the editor area showed a big icon, "Orbit", the project's
name, a card of rows with key caps and the version: a launcher in the middle
of the window. Apple's apps keep that space quiet (Xcode's "No Editor",
Finder's empty folder), so it now shows a small icon, the project's name, one
line on what to do, and four shortcuts as plain text in a grid centered
on its own width, names on the left and their keys on the right in menu glyphs, both brightening
under the pointer. No card, no key caps, no version (it's in About). The
same view without a folder offers Open Folder first.

### D167. Terminal sessions are a list beside the output

The bottom area's header held the panel tabs (Problems, References,
Terminal) and, after a divider, every terminal's tab: two kinds of tab in one
row, and with a few terminals it ran out of room. Now the header has only
the panel tabs, with New Terminal (+) beside Hide on the trailing side, and
the sessions are a list on the right of the terminal, like VS Code's, shown
once there are two or more (one terminal needs no list). A panel's
`accessory` now sits on the header's trailing side for every panel.

### D168. Tabs like Xcode 26 and Safari 26

`TabChip` (editor and chat tabs) now looks like Apple's:
- The current tab is a raised piece of Liquid Glass; others get a hover fill.
- The icon turns into the close button under the pointer, as in Xcode, so
  the trailing edge stays still; unsaved edits are a dot after the title.
- Tabs fade and scale in and out and slide into place when the order
  changes.

The drag (D91) is untouched: it stays our own gesture with the window held
still over a tab, and only the tab order is animated, never the drag
itself. `TabDrag` draws its own chip and line from the frames the tabs
report, so an animated row under a live drag would put the line in the
wrong place.

### D169. The sidebar switcher is Xcode's navigator bar

The Explorer / Search / Source Control buttons above the sidebar were
symbols on a tinted rounded fill. They are now bare symbols as in Xcode 26's
navigator bar: the selected one filled and in the accent color (the text
color when the theme has none, D97), the others secondary and brightening
under the pointer. They're read out by the panel's name (VoiceOver used to
guess from the symbol: "Move", "Divide"). The tree itself was already the
system's sidebar list and stays as it is.

### D170. A quieter status bar

The status bar's leading end had a button per bottom panel (Problems,
References, Terminal, each with its count) — the same tabs the bottom area
shows above it. Like Xcode's, it now has one button that shows or hides the
bottom area, plus the errors or warnings a panel reports (a red octagon or
yellow triangle with the count), which open that panel. Plain counts
(references found) stay on the panel's tab, and the divider after the
toggles is gone.

### D171. Source Control looks like Xcode's navigator

The panel was already the system's sidebar list with Staged / Changes
sections. Two pieces now match Xcode and the rest of Orbit:
- A file's status letter (M, A, D, U…) sits on a small square tinted with
  its color, as in Xcode's source control navigator, in the changes and in a
  commit's files.
- The commit message field is glass like the chat's composer (D163) instead
  of a filled box with a hairline. Commit stays the prominent button under it.
- Everything sits on one leading and one trailing edge, the sidebar list's
  own 16-pt margin (`GitRowInsets.edge`): the branch row, the commit box,
  section headers, file rows and the history controls. Rows get zero insets,
  and the views above use that margin minus the padding menus and icon
  buttons put around their symbols, so the glyphs line up, not the frames.

### D172. Problems and References read like Xcode's issue navigator

Both panels group their rows by file under one header (`FileGroupHeader`):
a chevron, the file's icon, name and folder, and a count badge tinted by
the file's worst problem (red, yellow, blue). A click anywhere on the header
folds the file. Rows start under the file's icon and have no lines between
them. Warnings are yellow, as in Xcode and the status bar (D170); the rows
had them orange.

### D173. Editor popups are Liquid Glass

Hover, completion and signature help (`FloatingPanel`) sat on the popover
material with an 8-pt corner and a separator-colored border. They now have
an `NSGlassEffectView` behind their content with `Theme.corner`, like
macOS 26's own menus, and no border: the glass draws its own edge. The
content still lives in a plain container on top, so the panels' views are
unchanged. The current line, its number and the ruler already follow the
color theme and stay as they are.

### D174. Quieter details: plain output, empty panels, a lone chat, VoiceOver names

- A code block in a reply names its language only when it has a real one:
  plain output ("text", no fence language) has no header line, and Copy
  shows over its corner on hover, as in Xcode.
- Empty bottom panels (Problems, References) use `PanelEmptyState`: the
  title in gray and one short line, no symbol, like Xcode's "No Issues".
  `EmptyStateView` took a third of the window in the short bottom area.
- A single chat shows as a title (status, name) instead of a lone tab;
  tabs start with the second chat. Close is in its context menu.
- Icon-only buttons (`IconButton`, `TopBarButton`) are read by VoiceOver as
  their tooltip without the shortcut (`spokenName`); file icons and path-bar
  symbols are hidden from it, since a name always follows. VoiceOver read
  the symbols' names before ("Split View Horizontally Left", "Go Down",
  "Plain Text Document").

### D175. The shortcuts popover is a searchable list you can rebind from

The keyboard button's popover (D67) was a 900-pt grid of every category
with key caps and a lot of empty space. It is now a 360 × 460 list: a
search field (focused on open), the commands with keys by category, and the
shell's own keys and the mouse under "More". A click on a key records a new
one right there, with the same rules as Settings (⌫ removes, Esc cancels, a
key taken from another command says so); searching also lists commands
without a key, so one can be given. "Keyboard Settings…" at the bottom opens
the full pane. The assignment rules live in `ShortcutsSettings.assign`, used
by both.

### D176. The menu bar is laid out like Xcode's

Menus were made straight from command categories: Code held 40 items in
registration order (navigation, folding, eight case transforms, line
edits, carets…), Review and Git were menus of their own, View mixed
everything else, and the system's window tabs added Show Tab Bar. Now
`App/MenuLayout.swift` places every built-in command:

- **File**: new, open (Open Recent, Open Quickly), close, save, Finder and
  paths, project settings.
- **View**: Command Palette; sidebar and its panels; agents; problems and
  terminal; split editors; preview and browser; inlay hints and blame;
  font size; theme.
- **Find**: Find in Project; references; find in terminal.
- **Navigate**: back / forward; tabs; definition, symbols, line; next problem.
- **Editor**: code actions, rename, imports; formatting; Toggle Comment and
  the Lines, Transform, Selection and Folding submenus; language servers.
- **Agent**: new sessions (other agents in a submenu); focus, inline edit,
  stop; then the review: accept / reject all, step through changes, comment.
- **Source Control**: commit; pull, push, fetch; stash; GitHub.
- **Terminal**: new, kill; tasks.
- **Help**: Keyboard Shortcuts (and Debug builds' tools).

Each menu is split into sections with dividers. A command the layout doesn't
list still gets an item at the end of the menu its category maps to, and a
category of its own goes to Plugins, which only shows when it has items.
The system's window tabbing is off (`allowsAutomaticWindowTabbing`): Orbit
has its own tabs. The plugin API is unchanged.

### D177. Settings search finds options, not just panes

Search in Settings filtered the sidebar to panes whose title or keywords
matched: "wrap" left Editor, and the option still had to be found by eye.
Now it works like System Settings: while there's a query, the sidebar lists
each pane that matches with the options it found indented under it, the
matched words in bold, best matches first (title starts with the query, then
words starting with its words, then anywhere in the title, then keywords
only). Every word of the query must match ("wrap line" finds "Wrap long
lines"). A pane shows its first four options and "N More". Clicking an
option, or Return for the best one, opens the pane, scrolls the row to the
middle and lights it up — two pulses of `Theme.matchFill`, then a fade.
Typing doesn't switch the page (it used to jump to the first matching pane
and build it on every keystroke, e.g. all of Keyboard Shortcuts' rows):
only picking a result does, and "No Results" shows in the sidebar. The
text is lowercased into a `SettingsSearch.Index` once per search.

Panes declare their options as `SettingsItem`s (`SettingsPane.items`, asked
on each search, so installed agents, ready language servers, plugins and
every command's shortcut are in it); the row marks itself with
`.settingsItem(id)` and `SettingsForm` scrolls to it. A new option in a pane
should get both. Items inside a pushed page aren't indexed; the row that
opens the page is.

### D178. Settings → Terminal and Settings → Files

The terminal had no options besides a font size tucked into Editor, and
what the file tree and search leave out was hard-coded.

- **Terminal** (Terminal plugin, `TerminalOptions`): the shell new tabs
  start (`/etc/shells`, default `$SHELL`; agents' commands keep the login
  shell), the font size (moved here from Editor: "Same size as the editor" or
  its own), cursor shape (segmented Block / Bar / Underline) and blinking,
  Option as Meta (off by default, as in Terminal.app), scrollback (1,000 –
  100,000 lines, default 10,000; SwiftTerm's own default of 500 lost long
  build logs). Changes apply to open tabs at once and reach other windows
  through a notification; the shell only applies to new tabs.
- **Files** (Explorer plugin): show hidden (dot) files, show git-ignored
  files (dimmed), and excluded files — globs in `Preferences.excludedFiles`,
  the same syntax as Find in Project's exclude field (`PathFilter`, moved to
  OrbitAPI so Explorer and Search share it). Excluded files leave the tree,
  Open Quickly and Find in Project; `.git` and `.DS_Store` stay hidden
  regardless. The list is edited System Settings style: a row per pattern
  with a red minus, an add field at the bottom.

### D179. A page per agent; options a project sets carry a Project badge

Installed agents were rows with an update button and a "…" menu; what a new
chat starts with (model, effort, mode) could only be seen by starting one.
Now each row is a link ("›", its defaults or version under the name, an
Update badge) to the agent's page: a header with its icon and description;
**New Chats** — Model, Reasoning effort and Permissions pickers, each with
"<agent>'s default" first; **About** — version, command, sign-in hint;
then Update, Show in Finder (custom agents) and Uninstall…, which now asks
first (a sheet, D162).

The choices come from what the agent last reported (`knownOptions`, saved
per agent whenever a session sends its config options), so an agent that
never ran says "After the first chat". Model and effort work as
before: picking one in a chat also makes it the default (`lastValues`).
The mode doesn't: it's set only on this page (`defaultModes`) and applies
to new chats, not resumed ones, so one "bypass permissions" chat doesn't
leak into the next; a mode that skips asking says so in orange.

Options `.orbit/settings.json` decides (D108) said "Set by … (\"key\")" in
orange, which read like an error. They now show a `ProjectOverrideNote`: an
orange "Project" badge and the key, with a tooltip on where to change it.
Setting a value for the project from Settings (writing the JSON) is still
left out: it would have to keep the file's comments and layout.

### D180. Code font family, default indentation, auto save

Settings → Editor gets the three editor options people look for first:

- **Font family**: SF Mono or any installed fixed-pitch family
  (`Preferences.codeFontFamily`, `Preferences.codeFont(size:weight:)`). The
  editor, inlay hints, fold placeholders and the terminal follow it; bold
  and italic tokens take the family's nearest weight (NSFontManager), SF
  Mono keeps its exact weights. Ligatures aren't turned on.
- **Indentation** for files nothing decides — no `.editorconfig`, no
  indented lines to guess from: spaces or tabs, 2 / 3 / 4 / 8 columns
  (`Preferences.defaultIndentation`, passed to `Indentation.of` as the
  fallback). It used to be fixed at 4 spaces.
- **Auto save** (`AutoSaver`): Off (default), a second after typing stops,
  or when Orbit goes to the background or the tab changes. Plain saves, no
  formatting (it would move text under the caret; ⌘S still formats). A
  file also changed on disk isn't saved over: its banner decides.

Line height stays fixed: the line-number ruler, folding and inline diff
gaps (paragraph styles) all depend on it. Auto-closing brackets isn't a
setting because the editor doesn't do it yet.

### D181. Text sizes: interface, chat, code, terminal

Other editors size text per area (Zed's ui / buffer / agent font sizes,
VS Code's zoom and terminal size); Orbit had the code size and the
terminal's. Settings → Appearance → Text Size now has all four together:
**Interface** (10–15 pt for a list row, default 12), **Chat** (matches the
interface unless given its own), **Code** and **Terminal** (the same
settings Editor and Terminal show).

The type scale (D117) stays the single list of sizes; it's multiplied by
`orbitTextScale` from the environment: the window sets the interface's, a
chat (`SessionView`) its own. Views write `.orbitFont(.body)` (all 307
`.font(.orbit(…))` uses were switched); `Font.orbit` alone, as in attributed
strings, stays unscaled. Fixed heights (tabs, bars) don't grow, which is
why the interface stops at 15 pt. AppKit text (the editor's popups,
completion) isn't scaled.

### D182. A JSON Schema for settings.json; the JSON server validates

An unknown or misspelled key in `.orbit/settings.json` was ignored
silently (D108's gap). `SettingsSchema` (OrbitLanguages) describes every
section Orbit reads — `editor` (and dotted `editor.*` keys), `agents`,
`mcpServers`, `formatters` (the presets offered as completions),
`languageServers`, `companions`, `codeActionsOnSave`, `tasks` — with a line
on each, and refuses other keys. It goes to the JSON server inline, matched
to `**/.orbit/settings.json`, so the project's and the global file get
completion, hover and "Property … is not allowed" without a schema file on
disk or a URL to fetch. A new settings key needs a line there too.

Testing it on the real server showed the JSON server validated nothing at
all — not even a trailing comma in any JSON file — because it waits for
`json.validate.enable`, which VS Code sends and Orbit didn't. Orbit now
sends it.

### D183. Setting an option for the project from Settings

Options `.orbit/settings.json` decides (D108, D179) could only be changed by
editing the file. Now a right-click on such an option in Settings offers
"Turn On / Turn Off for This Project" (a switch) or "Use <agent> for This
Project" (the default agent), and "Remove from This Project" once the file
sets it; the project pane's overrides each get a red minus. Editor options
keep their row enabled and disable only the switch, so the row takes the
right-click.

`Workspace.setProjectSetting` writes through `JSONTextEdit` (OrbitAPI), a
small scanner that finds the member in the text and replaces, inserts or
removes just it — in the section's own indentation, on one line for
`{ "a": 1 }`, as a top-level `"editor.wordWrap"` when the file spells it that
way — so the file keeps its order and layout; JSONSerialization would
rewrite all of it. Settings files are strict JSON (no comments), so there is
nothing else to keep. An open copy of the file is edited and saved with it.

### D184. Plugins: steady tiles, a way to their settings, Restart Now

Settings → Plugins colored tiles by a hash of the plugin's id and offered
"Quit Orbit" after a change. Now a plugin names its tint
(`PluginManifest.tint`, the same as its settings pane's) and its symbol is
shown filled where SF Symbols has a fill. A plugin that adds settings panes
gets a gear before its switch that opens them: `UIRegistry` records which
plugin is activating, so each `SettingsPane` knows its `pluginID`. "Restart
Now" quits and opens Orbit again (a shell waits up to 20 s for this copy to
exit, so a quit cancelled at a save prompt doesn't reopen it later); open
folders come back as on any launch (D101).

### D185. Settings → Checkpoints: disk use and keeping snapshots

The shadow repositories (one per project, Application Support) keep every
snapshot (`gc.auto` is off: chats rewind to them), so they only grow. The
Checkpoints pane (agents group) shows their size and the isolated copies',
and **Keep snapshots**: Forever (the default, as before), 3 months, 1 month,
1 week. With a limit, `git prune --expire=<n>.days.ago` runs in each shadow
repository at most once a day (and on Clean Up Now): it drops objects
nothing references any more that are older than that, so the snapshots of a
running turn and the index's own files stay; a chat older than the limit
can't rewind.

### D186. Automatic updates; a switch per language server

Agents, language servers and catalog extensions only updated from their
"Update" buttons. Settings → General now has **Keep Up to Date**: agents
(the ACP registry), language servers Orbit installed (Mason; ones found on
the Mac are left alone) and themes / icon sets from the catalog — each on
by default, checked in the background once a day (`Preferences.claimDailyCheck`,
so the first window does it), 20–40 s after launch. An updated server
restarts; open chats keep their agent's old version until they restart.
Software Update gets Sparkle's own two switches: check automatically, and
download and install (off in development builds).

Settings → Languages: every server that's installed or found gets a switch.
Off, it doesn't start in any project (`LanguageManager.disabledServers`,
app-wide; other windows follow through a notification); the status bar says
"<server> off" and opens Settings → Languages. Turning a server off per
file type in `.orbit/settings.json` ("languageServers": { "py": "off" })
still works beside it.

### D187. Blame after the caret's line, as GitLens; the column is gone

D135's column of authors left of the line numbers took 210 pt and the
author didn't like it. Blame is now GitLens's current-line annotation:
after the end of the caret's line, faded (the theme's hint color), in the
UI font a little smaller than the code — "Author, 3 days ago · summary",
"Not committed yet" for new lines. It follows the caret, hides while typing
until the text is blamed again (after a pause, as before), and isn't drawn
with a selection or several carets, or when the line leaves too little room.
Hovering it opens the editor's hover card (`BlameCard`, the same panel as a
symbol's): author, relative and exact date, the summary, Show Changes and
the short hash to copy.

Editor → Blame (now under Reading Code) and ⌥⌘B turn it on and off; it's on
by default (a new defaults key, so the column's "off" doesn't carry over).
The status bar's blame (Source Control) stays.

### D188. Line height, ligatures, a switch for closing brackets

Settings → Editor → Font gets **Line height** (Single, 1.1–1.5; a multiple
on the editor's default paragraph style) and, for a picked family,
**Ligatures** (on; off sets the font's common-ligature and
contextual-alternate features off, which is where Fira Code and JetBrains
Mono keep theirs). D180 left line height out because the ruler, folding and
the inline diff's gaps depend on it; they all measure laid-out lines, and
the gaps and tab stops copy the default paragraph style (`CodeEditor.apply(lineHeight:)`),
so they follow. Bold and italic tokens keep the base font's features.

Bracket and quote closing has existed since D73 (it was wrongly listed as
missing); it now has a switch, Editor → Text → Close brackets and quotes
(`editor.autoClose`), on by default. Off, typing and backspace are plain.

### D189. File history, line history, comparing with a branch or commit

The rest of GitLens's everyday features, in Source Control:

- **Show File History** (Git menu): History's scope menu gets "This File",
  `git log --follow` of the active file; a commit opens what it changed in
  that file (no graph: one file's commits aren't a connected history).
  Search filters them by message, author or hash.
- **Show Line History**: the selected lines, else the caret's
  (`git log -L <a>,<b>:<file>`, as committed — unsaved edits shift lines).
  The scope reads "File.swift:10–20".
- **Compare File with…**: a quick pick of branches and the file's last 30
  commits; the choice opens a read-only diff tab (`git.compare`) of the file
  at that revision against the editor's text, with GitCommitDiffView.

### D190. Clickable things are in the text color, not the theme's accent

With a theme whose accent is blue (GitHub), D97's window `.tint` made every
borderless button, link, menu, switch and "on" icon blue: the window read
like a web page of links. The window (and the editor's hosted popovers) now
tint with `Theme.controlTint`, the text color, which is how Orbit's own
themes always looked. `Theme.accent` stays the theme's for what isn't
clicked: selected rows and cards, match highlights, drop marks, the caret.

### D191. The terminal has the editor's background

Themes give `terminal.background` the panels' color, which is darker than
the editor (GitHub Dark: #010409 against #0d1117). Orbit's panels are glass
over the editor's background, so the terminal (and, since D167, the session
list beside it) stood out as a painted black block. The terminal and the
panel behind it now take the editor's background; its foreground and ANSI
colors still come from the theme's terminal keys.

### D192. One Extensions page for everything that can be installed

Things to add were in four places: themes and icons in Extensions, agents
behind Agents → Get More Agents, language servers behind Languages → Not
Installed, built-in plugins in Plugins. Settings → Extensions now lists them
all, as VS Code's and Zed's extension views do: one search field, a
segmented filter (All · Agents · Languages · Themes · Features), installed
things grouped by kind, and under them the catalogs.

- Each kind is an `ExtensionSource` (OrbitAPI): what's installed, what its
  catalog has, loading state, refresh. Plugins register theirs
  (`ui.addExtensionSource`): Agents (ACP registry), Languages (Mason; a query
  also searches the hundreds imported from nvim-lspconfig). The shell adds
  themes (Zed's catalog keeps its own page, where a theme is tried on
  before installing) and built-in features (the old Plugins pane, merged).
- A row is an `ExtensionItem`; the shell draws it the same way for every kind:
  Install, Update, a gear to its settings pane, a switch when it can be off
  without uninstalling (servers, features), Show in Finder / Uninstall,
  or a page of its own (an agent's defaults, D179).
- All with no query offers "Get More …" per kind (switches the filter);
  with a query, each catalog's first five matches and Show All.
- The Agents and Languages panes keep configuring; their "Get More" rows
  jump to Extensions filtered to that kind (`ui.showExtensions(_:)`).
- Settings search finds installed things by name ("codex" → its row).

Splitting the built-in plugins finer (Git Lens apart from Source Control)
and plugin requirements come next, on top of this page.

### D193. npx agents start outside the project; exits say why

Claude Agent failed with only "The process exited" in a pnpm monorepo: npm 11
ran `npx` in the project, read its package.json `devEngines` (pnpm) and
quit with EBADDEVENGINES. Agents launched through npx, uvx, bunx or pnpx now
start in ~/.orbit/agents (chats, commit messages, the Recent list:
`AgentProvider.launchDirectory`); ACP hands them the project in session/new, and
their terminals and edits use that. Other agents still start in the project.

The message lost the reason because requests failed before the exit handler
stored stderr; the exit error now carries the exit code and stderr's last
lines itself.

### D194. Plugins turn on and off live, require each other; Git Lens and Browser split out

Built-in features (Settings → Extensions → Built-in Features, D192) used to
need a restart, and some were too coarse to turn off on their own.

**Live.** Each plugin gets its own `UIRegistry`, `CommandRegistry` and
`ServiceRegistry` over the window's shared contents; everything it adds —
panels, tabs' providers, status items, commands, Settings panes, extension
sources, services — carries its id (`pluginID`), even what it adds long
after activating (an agent's commands). Turning it off ends its
`PluginLifetime` (registries then drop what it still tries to add), calls
`deactivate()` (processes, timers, observers), removes all it added and
closes its tabs (a diff, a preview, a page). Re-arming observers check
`context.isActive` as they checked `workspace.isClosed`. Services are
observable, so what looked one up updates; a text editor is rebuilt when
the services it was wired to change (`EditorWiring`). A switch applies to
every window (a notification each host follows). Work in progress — agents
working, running tasks, open terminals — is named in a confirmation first
(`deactivationWarning()`). Restart Now is gone.

**Requirements.** `PluginManifest.requires` lists plugins it can't work
without: while one is off, it's off too, its switch greyed with "Needs …
on" and the user's choice kept, so it comes back with that one (as System
Settings greys dependent options). It's listed indented under it.
`isRequired` marks Orbit's core — Explorer, Code Editor, Search, Change
Review (agents' edits go through it, D7) — shown as Required, no switch.
`tools` names programs it runs ("git"): a missing one is said in the row.

**Split out**, each its own plugin in its parent's module (sharing the
model through a service; plugins still never import each other):
- **Git Lens** (requires Source Control): blame after the line and in the
  status bar (it registers `LineBlaming`; Editor's Blame option shows only
  then), Show File / Line History, Compare File with…, GitHub links.
- **Browser**: web pages in tabs (`WebPreviewing`), out of Preview.

Kept whole: Terminal with Tasks (tasks run in its sessions), Languages
with Formatting, Agents with usage and pull requests (they're about the
agents' work, from isolated copies). Checks: `PluginTogglingTests` turns
every optional plugin off and on and expects all it added gone, it and the
models it registered freed, dependents to follow, and no duplicates after.

### D195. Extensions bring snippets, agents, language servers and tasks; the Extensions page lists packages

An extension folder used to bring only themes and icons; agents, language
servers and tasks were each set up their own way, and Orbit had no
snippets. Now one folder can bring any of them (docs/extensions.md):

- **Snippets** (new): VS Code's and Zed's format, `snippets/<language>.json`
  or `snippets.json` (Zed's `extension.toml` `snippets = …` is read).
  `SnippetLibrary` merges the project's `.orbit/snippets`, the user's
  `~/.orbit/snippets` (watched) and extensions'. They show among completions
  as you type their prefix — with or without a language server, after the
  server's items, never after `.` — and in Editor → Insert Snippet… (a quick
  pick by name or prefix). Tabs in a body become the file's indentation and
  following lines keep the caret line's. Zed's catalog gains a Snippets tab:
  80 extensions, installed without a try-on.
- **Agents**: `agents/*.json`, the `~/.orbit/agents` manifest; the user's
  win on the same id. Shown "From the … extension"; no Uninstall of their own.
- **Language servers**: `language_servers.json` (file types, roots,
  command, a Mason package to install from, settings). They come first for
  their file types (`ExtensionServers`, process-wide behind a lock: the
  server table is static); servers restart when the list changes.
- **Tasks**: `tasks.json`, offered by Run Task… where a `when` file is at
  the project's top.

The Extensions page (D192) gets the polish System Settings has:
- "Themes & Icons" becomes **Packages**: every extension folder, its tile by
  what it mostly is, its contents said plainly ("2 themes · 14 snippets").
  A package opens its own page: color themes and file icons with Use / In
  Use, its snippets (prefix, name, languages), **Runs on Your Mac** with
  every program it can start, its problems, folder, repository, Uninstall.
- Each group ends with its way to more, as System Settings' lists end with
  "Add…": Get More Agents… / Language Servers… (switch the filter);
  Packages end with the catalog, Your Snippets (its own page: the list,
  New File…, the project's folder) and **New Extension…** (a folder with
  extension.json, an example snippet and a README of every part).
- Group headers carry their counts; a search with nothing found shows the
  system's search empty state; Show All rows; installed language servers get
  colored tiles.

Not yet: a catalog of Orbit's own for agents, servers and tasks (Zed's can't
carry them), and asking before a downloaded package runs a program — nothing
downloadable can bring one until that catalog exists.

### D196. Blank chats stay out of Recent, even when the agent lists them

Every window opens a new chat, and its agent session starts right away
(`session/new`, so the model and mode pickers fill in). Claude Code keeps
that session on disk and lists it in `session/list` as "New session -
<date>", so Recent filled with one empty entry per window opened.

Orbit remembers the session ids of chats it opened that nothing was sent in
(`blank` in the saved history; sending a message takes the id off) and
leaves them out of Recent, and drops listed sessions still carrying Claude
Code's placeholder title (it renames a session on its first prompt), which
also clears the ones from before this. Starting the agent lazily on the
first message was the alternative: no session to hide, but empty pickers
and a slower first reply.

### D197. A click anywhere on the selected folder's row toggles it

The list selects a folder on the first click, and the selection binding
toggles it. A click on a row that's already selected changes nothing in the
list, so it was left to a tap gesture on the row's label, which doesn't
cover the edges of the highlight: there a second click did nothing.

The explorer now watches mouse clicks on its outline view (a local event
monitor, `ReclickMonitor`): a plain click that starts and ends on the row
already selected alone toggles that folder, wherever in the row it lands.
The disclosure triangle and the rename field are left alone; a drag isn't a click.

### D198. Problems also check the files that use what the agent changed

D75 checked the files an agent changed; an importer it broke without
touching (a renamed export, a changed signature) stayed silent until opened.
LSP's workspace diagnostics would cover it but almost no server has them
(tsserver none, Pyright only in a slow mode), so Orbit finds the users itself,
2 s after the agent's edits settle:

- **References**: for each changed file (up to 20), the server's outline gives
  the top-level symbols and their members whose lines changed; their
  references (up to 8 symbols a file) name the files using them. Works in
  every language whose server answers references, Swift included.
- **Imports by name**: the Search plugin's file list, filtered to files the
  changed file's server serves, is scanned off the main actor for a line that
  names the module (its stem, or its folder for `index`, `__init__`, `mod`)
  beside an import word, or as a path's last part (Go's import blocks). This
  finds users of an export that's gone, which references can't.

At most 40 such files; they're opened on their servers in the background like
D75's and leave once nothing is left to review, except the ones still
reporting problems. Without the Search plugin only references are used.

### D199. Server edits create, rename and delete files; rename can be previewed

Edits from servers came as text only: a `documentChanges` entry with a
`kind` was dropped, so rust-analyzer's module rename or TypeScript's "Move to
a new file" left the project half changed. And a rename across the project
went through with no way to see what it touched.

- **`WorkspaceEdit` is an ordered list of steps** (edit, create, rename,
  delete), as the server sent them; the client advertises
  `resourceOperations`. Renames go through `Workspace.moveItem` (tabs and
  buffers follow; an editor finds its file by its document after that),
  deletes go to the Trash (`trashItems`), not gone for good. `overwrite` /
  `ignoreIfExists` are honored; a step that can't run marks the edit as
  partly failed and the rest still runs, like VS Code.
- **Rename preview**: the rename field has Preview Changes (⇧↩, VS Code's
  key). A sheet lists each changed file with its line count, expandable to
  the diff (`CompactDiffView`, colored), and each file created, renamed or
  deleted; unchecking a row leaves those steps out. Texts are simulated in
  step order, so an edit after a rename previews against the moved file.
- A rename that moves files opens the preview even on Return: moving files
  is worth a look. Code actions still apply directly (the user picked them).

### D200. Call and type hierarchies in a bottom panel

"Who calls this?" took Find References and reading each hit; following
calls up two levels meant doing it again per caller.

- **Show Call Hierarchy** (⌃⇧⌘H, Xcode's Find Call Hierarchy) and **Show Type
  Hierarchy** (no key) in Find and the editor's menu put the symbol at the
  caret into a **Hierarchy** bottom panel beside References: a tree rooted
  at it, a segmented switch for Callers / Callees (Supertypes / Subtypes).
  Rows open a level at a time (`callHierarchy/incomingCalls` and friends,
  asked on expand); a row without children loses its chevron once asked.
- A caller opens at its call; more than one call shows a count, and the
  row's menu lists each. Callees, types and the root open at their name.
- The server's items go back to it verbatim (they carry `data`), so the
  server keeps them by token; a new hierarchy starts the store over.
  Only the language server is asked (companions have none).
- Tested against sourcekit-lsp (callers with both call sites, a caller's
  caller, callees, a struct's protocol).

### D201. Semantic tokens over tree-sitter's colors; code lenses after the line

Tree-sitter sees syntax only: `x.name` is "a property" or "a method"
by its shape, a type used as a value is a variable, `String` looks like any
other type name. The language server knows. And servers' code lenses
("3 references", rust-analyzer's "▶ Run") weren't shown at all.

- **Semantic tokens** (`textDocument/semanticTokens/full`, or `/range` over
  the whole file) are asked after a 400 ms pause in typing, when new
  problems arrive (the server caught up) and on `semanticTokens/refresh`.
  They only override where they add something (`SemanticColors`): types,
  parameters, properties, enum cases, functions and methods, macros,
  decorators, and the standard library's variables. Variables, keywords,
  strings and comments stay tree-sitter's. A token recolors only when the
  theme styles its capture (`variable.parameter` falls back to `variable`,
  the theme's own way). They're a second layer of rendering attributes,
  painted like D78's faded code: no relayout; they move with edits and the
  ones an edit touched go until the next answer. The client says
  `augmentsSyntaxTokens`. Settings → Editor → Semantic highlighting.
- **Code lenses** sit after the end of their line in the hint color, like
  the blame (which moves after them): no room is made above the line, so
  nothing shifts and the inline diff's paragraph gaps stay alone. Lenses
  are resolved (`codeLens/resolve`) and only shown when Orbit can do what
  they say: a server command (`executeCommandProvider`), a references lens
  (`editor.action.showReferences` and rust-analyzer's) that opens the
  References panel, rust-analyzer's `runSingle` that runs `cargo …` in a
  terminal tab, or a lens with no command (only a note). Others (VS Code's
  own debug commands, sourcekit-lsp's `swift.run`) would be dead buttons and
  are left out. Clickable lenses take the text color and an underline on
  hover. Lenses below an edit hide until the server answers again (800 ms).
  Settings → Editor → Code lens.
- Tested: token decoding and the mapping, lens actions; sourcekit-lsp's
  tokens (the standard library's `String`, a property in an interpolation).

### D202. Every caret gets the typing rules; linked tags, Expand Selection, squiggles that move

D105 let the indentation and bracket rules step aside with several carets,
so ⌘D-then-type lost autoindent, pairs and completion exactly where many
carets are used. And a few things editors do were missing.

- **Rules per caret** (`CaretEditing`): Return's indentation, Tab to the next
  stop, Backspace to the previous one, bracket close / wrap / step over, and
  the empty pair's Backspace are pure functions of the text and one
  selection. `combine` makes one replacement of every caret's change (one
  undo step; a change overlapping an earlier one is dropped with its
  caret); a caret a rule doesn't apply to gets plain typing. One caret is
  the same path. Tab over lines and ⇧Tab shift every line any selection
  touches, once. Tested without a text view.
- **Completion at every caret**: each caret's edit reaches the editor on its
  own, the bottom one first, so the list follows the top caret (its place no
  later edit moves). Accepting puts the item at each caret over the same
  span before and after it as at the list's caret, within the line; a
  snippet selects its first placeholder at each and has no Tab walk.
- **Bracket match** skips strings and comments, from the highlighter's
  cache: `")"` in a string no longer closes code's `(`; brackets inside one
  pair among themselves.
- **Linked editing** (`textDocument/linkedEditingRange`): with the caret in
  a tag name (HTML, JSX via vtsls), its pair is asked for after 100 ms;
  typing or deleting inside goes to every range as one edit, and anything
  that isn't part of a name (a space, `>`), an edit elsewhere or the caret
  leaving ends it. Keys are untouched: it's typing, not a mode.
- **Expand / Shrink Selection** (⌃⇧⌘→ / ⌃⇧⌘←, VS Code's; Edit ▸ Selection):
  the narrowest `textDocument/selectionRange` holding more than each
  selection; without a server, its word, its line, everything. Shrink goes
  back through the selections Expand came from while nothing else moved them.
- **Squiggles follow edits**: the problems shown move with the text (one the
  edit was inside stretches or shrinks) until the server publishes again;
  the same set arriving again doesn't put them back where they were. Faded
  unused code moves with them.
- **Snippet placeholders are tokens**: a soft box behind each placeholder
  still to fill, so it's clear what Tab walks through.

### D203. Formatters in a row from settings; format on type

A file type had one formatter: a repo running Prettier and then ESLint's
fixes (or the server, then a linter) got only one of them from ⌃⇧I. On save
D81's code actions already ran ESLint's fixes before the formatter.

- **A list in `"formatters"`** runs its tools in order, each on the one
  before's text: `"ts, tsx": ["prettier", "eslint"]`, presets and commands
  mixed. `"server"` may come only first (it formats the text it has, the
  document as typed); `"off"` can't be in a list. One edit at the end, so
  ⌘Z takes it all back and Format Selection keeps only the selection's
  lines of the final result. A failing step stops the chain and says which.
  The toast and Settings → Formatting name them with arrows ("Prettier →
  ESLint"). Detection doesn't chain on its own: ESLint is slow, and running
  it on every ⌃⇧I unasked would surprise; save already runs its fixes.
- **Format on type** (`textDocument/onTypeFormatting`), off by default as
  in VS Code (Settings → Editor, `editor.formatOnType`): after a character
  the language server lists (`;`, `}`, Return) its edits go in as their own
  undo step, unless more was typed meanwhile. One caret only; never while
  completion inserts. Tested against vtsls (`const a=1;` → `const a = 1;`).

### D204. Remote branches in History; a file at a commit, with its blame

History's scope menu had only local branches (a colleague's branch, or what
a pull would bring, needed All), and blame was only of the working file.

- **Remote-tracking branches** (`refs/remotes`, newest first, no `HEAD`)
  follow the local ones in the scope menu (up to 30) and in Compare File
  with… ("Remote branch").
- **A file at a commit** (`git.revision` tab, GitLens's revision view): Open
  File at This Commit in a commit's file menu and in File History's commit
  menu. The file as that commit left it, syntax-colored, each run of lines
  from one commit with its author and age (`git blame <rev>`), separated by
  a hairline. A run's menu shows its commit's changes or opens the file
  **before** that commit (`<hash>^`), walking a line's history back one
  change at a time. Read-only; Open File goes to the working copy.

### D205. A first-launch tour: a short film, four setup steps, one closing line

A new user landed on the welcome window with no agent installed and no idea
that agent changes are reviewed in the editor, the one thing Orbit is about.
Dia's onboarding (a cinematic intro, then a card of steps) showed how much a
first minute can say; ours borrows the shape, not the look.

- **The film** (~16 s, Skip Intro / Esc): night and stars; Orbit's mark
  comes out of a blur, the agents themselves (their icons on dark tiles,
  installed or from the registry) circle it on nested orbits in one plane; it settles above "Agents write the code. / You decide what
  stays."; then a
  small editor where Claude rewrites a line, the change shows inline (red
  ghost, green lines, the banner) and Keep is pressed. The demo uses the
  real color theme, so it looks like the editor it advertises.
- **Setup**, a Liquid Glass card over a planet's faint horizon, a segmented
  white rail on top, each step with a live picture on the right:
  1. *Agents*: Claude, Codex, Gemini, Cursor, Copilot, OpenCode from the
     agents' `ExtensionSource` (D192) with Get buttons; installed agents
     circle Orbit's mark in the picture, joining it as they install.
  2. *Look*: System / Light / Dark tiles, then installed themes and the most
     downloaded of Zed's catalog (installed on click); hover tries one on
     the demo editor.
  3. *Review*: the keys of reviewing, read from the commands so rebound keys
     show (D107), beside the demo playing on a loop.
  4. *Terminal*: installs the `orbit` command (D142), with `orbit .` typed
     in a little terminal.
- **The close**: "Your agents are in orbit." with a glint of light passing
  over it, then the window underneath.

No glossy 3D planet, crossing "atom" rings, glowing colored dots or rainbow
gradients: the first version had them and read as generic AI art. Night,
white, and the agents' real icons. The step area takes exactly the size the
card gives it (min 0, clipped): content taller than that pushed the rail and
the buttons up and down.

It's shell UI (`App/Onboarding.swift`), an overlay over the whole window
including the top bar, forced dark: the film is night whatever the
appearance. Shown once (`orbit.onboardingDone`), in the first window that
appears; Help → Welcome to Orbit plays it again in the active window.

### D206. GPL-3.0, and the files an open-source repo is expected to have

The repo was public with no license (so legally nobody could use or
contribute to it), no README and no CI.

- **License: GPL-3.0.** Not a free pick: the editor is built on STTextView,
  which is GPL-3.0 unless you buy a commercial license, and a distributed
  app linking it has to be GPL-compatible. A permissive license (MIT) would
  only become possible by paying for STTextView or replacing it.
- **Community files** in the root: `README.md` (what Orbit is, install,
  build), `CONTRIBUTING.md` (the codebase's rules in short: plugins, one
  host per window, strict concurrency, `Theme`), `CODE_OF_CONDUCT.md`
  (adopts the Contributor Covenant 2.1 by reference), `SECURITY.md`
  (private advisories; Orbit isn't sandboxed and updates itself, so this
  matters). Issue forms ask for the macOS / Orbit version and the `.ips`.
- **CI** (`.github/workflows/ci.yml`): on macOS 26, `make test` and
  `make build`; on Linux, the language-server client (D55), whose server
  tests skip without servers. Dependabot watches Actions and SwiftPM pins
  monthly; Sparkle's exact pin in `project.yml` stays manual.
- `.editorconfig` states what the code already does: 4 spaces, LF, tabs
  only in the Makefile.

### D207. Dependencies' licenses in About Orbit

MIT and BSD ask for their copyright notice in every copy handed out, GPL for
its text; Orbit.app shipped none of them.

- **Where**: the standard About panel's credits (Orbit → About Orbit), as
  most Mac apps do it, not a window or Settings page of our own. The menu
  item is ours only to pass the credits.
- **What**: `App/Acknowledgements.txt`, generated by
  `scripts/acknowledgements.py` (`make acknowledgements`) from
  `Package.resolved` and the checked-out packages' own license files, so a
  license is never retyped. Packages nothing in the app uses (SwiftTerm's
  demo's argument parser) are left out; GPL's text appears once, at the end.
- **How it's drawn**: an attributed string in label colors, not a
  `Credits.rtf` / `Credits.html`: those come out black on the dark About panel.
- Rerun it when a dependency changes; nothing checks that it's current.
