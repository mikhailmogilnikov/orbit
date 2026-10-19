# Roadmap

## Done
- App shell: navigator / tabs / inspector / status bar, command palette, menus from commands, settings
- Plugin kernel (UI, commands, services registries; enable/disable)
- Settings screen inside the window (⌘,):
  searchable sections on the left, plugins add their own (`SettingsPane`);
  General (theme), Editor (font size shared with terminal, wrap, current line),
  Agents (default agent, isolated by default, installed / custom agents),
  Source Control (gutter markers, blame), Keyboard Shortcuts, Plugins
- Explorer (lazy file tree)
- Editor: STTextView, line numbers, tree-sitter highlighting, save
- Agents over ACP: Claude Code, Codex, Cursor, Grok Build, OpenCode (D52), custom JSON agents; parallel sessions;
  streaming transcript, thinking, tool cards with diffs/output, plans,
  permission prompts, model/mode/effort pickers from `configOptions`
- Change tracking via shadow-git checkpoints
- Inline Cursor-style diffs in the editor with per-block Keep/Undo + navigation
- Changed files above the agent composer (Undo All / Keep All, per-file keep/undo),
  clickable status bar counter, ⌥⌘↑/↓ walks changes across files (D45)
- Open Quickly ⌘P (fuzzy, git-aware file index) and Find in Project ⇧⌘F
  (in-process parallel search: case / whole word / regex, unsaved buffers included);
  replace in files with a live preview (per file or all, `$1` groups in regex
  mode), files to include / exclude globs; ⌘P lists recent files (per project)
  and nudges them up in results
- Integrated terminal (SwiftTerm) in a resizable bottom panel: multiple tabs,
  login shell in the project folder, follows light/dark
- Source Control panel: staged / changes / conflicts, stage / unstage / discard
  (new files go to the Trash), commit (⌘↩, "Commit All" when nothing staged),
  branch switch / create, pull / push / fetch, ahead/behind; ✨ Generate Commit
  Message via a hidden agent session (`AgentCompletion` service); diff tabs
  for working-tree / staged changes; git colors and badges in the explorer
  (`FileStatusProviding` service)
- Syntax highlighting in git diff and commit tabs and agent tool cards (`SyntaxHighlighting`
  service: a one-shot tree-sitter parse in the editor's theme)
- Git stash (stash with untracked files, pop/apply/delete), History (last 200
  commits; expand for files, click for a read-only diff tab), blame of the
  caret's line in the status bar (`EditorSelectionProviding.cursor`)
- Git change markers in the editor gutter (green added, blue modified, red
  wedge for deletions) against the index, via `VersionControlBaseline`
- Prompt attachments: `@` in the composer picks project files (⌘P ranking via
  `ProjectFileIndex`), ⌘L attaches the editor selection (`EditorSelectionProviding`),
  files and images by drop, ⌘V or the paperclip menu; `@` works anywhere in
  the draft; chips show on
  the composer and on sent messages
- Agent sessions persist: open tabs come back on launch (their agent starts
  and replays the conversation via ACP `session/load` when the tab is shown);
  "Recent" on the start screen and in the + menu lists earlier conversations of
  the folder, Orbit's own and the agents' `session/list` (e.g. CLI sessions)
- Agent commands: the tool card shows their output with Stop / Show in
  Terminal; terminal tabs are display-only for Claude Code / Codex
  (`_meta.terminal_output`, opened on demand), real PTYs for agents using ACP
  `terminal/*`
- Save / Don't Save / Cancel prompt when unsaved edits would be lost: closing
  the last tab of a file, opening another folder, quitting
- Files changed on disk under unsaved edits (agents, git, other apps): edits
  on other lines merge in silently; overlapping ones get a "Changed on disk"
  banner with Compare (take blocks one by one) / Use Disk Version / Keep Mine;
  ⌘S over such a change asks first; a file deleted on disk gets a "Deleted on
  disk" banner (Close / Save)
- Isolated agent sessions (opt-in: checkbox on the start screen, + ▸ Isolated
  Copy, ⌥⇧⌘N): the agent works in an APFS clone of the project; Apply brings
  its changes back as inline-reviewed agent changes, merging with project
  edits on other lines and reporting same-line conflicts; closing the session
  deletes the copy (asks when changes weren't applied); copies no open tab
  uses are deleted at launch
- Extensions, step 1 (D37, D38): folders in `~/.orbit/extensions/` (live
  reload, Settings → Extensions lists them and their errors); color themes and
  file icon themes in Zed's formats (Zed extensions load unchanged); light and
  dark theme and file icons picked separately (Settings → General); themes color
  the editor, gutter, terminal, git colors and code in diffs; the chrome stays
  native glass tinted by the theme background (D41); authoring guide
  in `docs/extensions.md`, samples in `examples/extensions/`
- App icon (Icon Composer) and brand mark in the UI; welcome screen with clickable actions
- Agents panel (D43): tabs always on top, a new chat opens by default (or the
  saved tabs) and lists recent conversations until the first message; one
  composer button with a popover for effort / mode / model, models grouped by
  agent with search, another agent's model switches an empty chat to it
- Explorer dims git-ignored files and folders (from `git ls-files --ignored --directory`); only `.git` and `.DS_Store` are hidden
- Sidebar width enforcement via AppKit split view item (prevents constraint crashes on column resize)
- Settings redesign: theme and icon theme settings moved to General, toolbar removed
- Composer usage ring (D46): context fill; popover with plan limits (Claude), cost and tokens
- Extensions catalog (D48): Zed's themes and icon themes in Settings → Extensions →
  Catalog (search, try on, install, update, uninstall); try-on bar over the editor
- LSP (D54): Languages plugin runs sourcekit-lsp (Swift) and
  typescript-language-server (TS/JS) lazily per project; squiggles, hover
  (rest the pointer), ⌘-click / ⌃⌘J go to definition, ⌘' next problem,
  status-bar problem counts; idle servers stop after 10 min
- Agents from the ACP registry (D52): install / update / uninstall in Settings →
  Agents, downloads checked by sha256, no built-in presets; old Claude Code /
  Codex chats migrate to the registry ids
- Open diffs (git tabs, commit diffs, tool cards) recolor on a theme switch;
  agent inline-diff overlays use the theme's version-control colors
- Theme selector ⌃⌘T with live preview over installed and catalog themes;
  catalog thumbnails; light/dark partner picked together (D49)
- Language servers installed from the Mason registry (D57): Settings →
  Languages and an Install button in the status bar; 20 languages (Python,
  Rust, Go, C/C++/ObjC, JSON, CSS, HTML, YAML, Shell, Markdown, TOML, Lua,
  Dockerfile, PHP, Zig, Svelte, Terraform, Ruby + Swift, TypeScript)
- Code actions ⇧⌘A, rename ⌃⌘E, format ⌃⇧I / on save, Problems panel ⇧⌘M (D59)
- Problems for every file the agent changed, open or not; kept after review
  until fixed (D75)
- Settings pushed to servers on start; Tailwind at-rules not flagged in CSS;
  tsserver 8 GB and function-call completions; names in code type in
  problem messages; crashed servers restart (D76)
- Servers hear about files changed on disk, the agent's shell edits included
  (`didChangeWatchedFiles`, D77)
- Unused code faded, deprecated code struck through (D78)
- Find References ⇧⌘R (was ⇧⌃⌘F, D67) (References panel), Go to Symbol in File ⇧⌘O and in
  Project ⌘T, highlights of the symbol under the caret (D62)
- ESLint and Tailwind CSS beside the file's language server, when the
  project uses them: problems, fixes, class completion and hover (D64)
- Language servers as data (D65): root markers per server (one server per
  project root: Cargo / Go / Python workspaces, one TypeScript per JS
  monorepo), launch from the project / Orbit's copy / the machine, the
  project's `node_modules/.bin` and `.venv` first on the server's PATH; no npx;
  327 more servers imported from nvim-lspconfig (`make import-lspconfig`),
  ranked per extension, the installed one winning; Java and C# entries;
  `"languageServers"` rules in `.orbit/settings.json` and the status bar's
  menu to pick a file type's server; "Ask Agent to Set Up" when one can't run
- Bottom area tabs (Terminal / Problems / References with counts, Hide) and
  status-bar buttons that open each panel (D63)
- Formatting uses the repo's formatter (Prettier, Biome, oxfmt, dprint, Deno, ESLint, Ruff, Black, StyLua, RuboCop, Standard, Pint, PHP CS Fixer, shfmt, or any command in `.orbit/settings.json`), else the server with `.editorconfig` indentation (D60, D61); Settings → Languages → Formatting shows which
- Lazy syntax highlighting (D58): grammars for Lua, Zig, Terraform/HCL,
  Dockerfile, Kotlin, Svelte, SCSS and TSX/JSX compiled on first open from
  pinned commits, colored by Zed's queries
- Completion while typing and signature help (D56): local fuzzy filtering,
  snippets with placeholders, auto-imports, docs for the selected item
- Features made findable (D67): the editor's right-click menu with shortcuts,
  the shortcut shown after a command is run by mouse, a keyboard button in
  the status bar listing every shortcut, tooltips with shortcuts on icon
  buttons (shown after 0.25 s), ⌘-hover underlines a symbol with a
  definition; keys inside the hover card and the completion list; new keys:
  ⌃⌘S sidebar, ⌥⌘I agents, ⇧⌘E explorer, ⇧⌘R references
- Hover card over the line like VS Code's (D68), with the problem's fixes and
  "Quick Fix…" in it (D66); only applicable code actions are listed
- Language-server tests against real servers (D55): Swift, TypeScript 7 / 5 /
  without a project install; `make test-languages`, also on Linux (`scripts/linux-swift.sh`)
- Inlay hints from the language server (D70); embedded languages colored by
  their own grammar: HTML/Vue script and style, Markdown code blocks and
  inline text, CSS in tagged templates (D69)
- Highlighting for ~520 languages imported from Zed and its extension catalog
  (`make import-grammars`, D71); no built-in grammars, every language
  compiled on first use, the open folder's languages ahead of time
- Vue (D74): tsserver with Vue's plugin as `.vue`'s server, Vue's own server
  beside it with its tsserver questions forwarded; a server's crash shows its
  error line, not the tail of the stack
- Code folding (D79): server regions or indentation, gutter chevrons,
  ⌥⌘←/→ and ⌥⇧⌘←/→, animated as in Xcode; folds survive agent edits and
  reopening the file
- The editing session comes back (D80): file tabs per folder, caret and
  scroll per file, expanded folders, window layout
- Code actions on save (ESLint's fixes by default, `codeActionsOnSave`),
  Organize Imports ⌃⌥O; companions off / on / configured in
  `.orbit/settings.json` (D81)
- Sticky scroll and a path bar with the symbols at the caret (D82)
- Typing follows the file's indentation (.editorconfig or detected): Tab/⇧Tab/Return/Backspace, status bar picker (D83)
- Overview ruler by the scroller: git changes, symbol uses, problems, caret (D84)
- Restore files to before any message of an agent chat, reviewable and undoable inline (D85)
- MCP servers for every agent from `"mcpServers"` in `.orbit/settings.json`, Settings → Agents lists them (D86)
- Notifications and a Dock badge when an agent finishes, fails or needs a permission while Orbit is in the background (D87)
- Messages written while the agent works are queued above the composer and sent as turns end (D88)
- Image and PDF viewer; live Markdown preview tab ⇧⌘V or the eye button in the path bar, front matter as a table (D89)
- Split editor: two sides, the tab row split along the same line, ⌘\\ / ⌥⌘\\ / ⌃⌘\\, preview opens beside its source (D90)
- Drag and drop: reorder tabs, move them between sides, drop tabs or explorer / Finder files on an editor edge to split, anywhere on the agent chat to attach (D91)
- Move files between folders by dragging them in the explorer (confirmation, ⌥ copies, open tabs follow) (D92)
- Explorer file operations: inline rename (Return), New File ⌘N / New Folder ⌥⌘N (header buttons, menus, paths create folders), Move to Trash ⌘⌫, ⌘Z / ⇧⌘Z for these and drag-and-drop moves (D93)
- Preview tabs: a click in the explorer reuses one italic tab, a double click or an edit keeps it (D94)
- Explorer context menu after Cursor's: open to the side, Open With, terminal here, add to agent chat, cut / copy / paste files (Finder-compatible), copy paths, with keys (D95)
- Accent color from the color theme (`text.accent`, else the text color) instead of the system blue (D97)
- Keyboard navigation: the explorer keeps the keys while previewing, ⌘1 / ⌘2 editor sides, ⇧⌘[ ⇧⌘] tabs, ⇧⌘T reopen closed tab, Escape from the explorer to the editor, ⌥⌘R / ⌥⌘C anywhere (D98)
- Dock icon menu and File → Open Recent with the last 10 folders (D100)
- A window per project: Open Folder in a project's window opens a new one, New Window ⇧⌘N, the open folders come back on launch; Cursor-style welcome window with Open Folder, Clone Repository and recent projects (D101)
- File → Close Folder back to the welcome window; folders dropped on the Dock icon or opened with Orbit from Finder (D102)
- Go Back ⌃- / Go Forward ⌃⇧- through caret locations across files, ⌃Tab recent-tab switcher (D99)
- Output follows only from the bottom of the chat; scrolled up, what you read stays put (D121)
- Merge conflicts in the editor (D134): Accept Current / Incoming / Both per block, Accept All, Mark as Resolved
- Blame column beside the line numbers (D135, ⌥⌘B): author and age per commit run, click for the commit
- History of any branch with search and a graph, ref badges (D136)
- All agents overview (D130): every window's chats in the status bar's popover (⌃⌘A), Allow / Deny there and in notifications
- Queued messages and review notes kept across launches (D131)
- Rewind Chat and Files (D132): the message and what followed leave the chat, the message returns to the composer, the agent is told to disregard them
- Create PR from an isolated session (D133): branch, commit of the agent's files, push and `gh pr create` in the copy; PR state and checks in the bar
- Releases (D129): `make release-setup` / `make release VERSION=…` / `make release-publish`, Sparkle updates from GitHub Releases, Check for Updates…; ad hoc signed until there's a Developer ID
- Tasks (D128): Run Task… ⌃⌘R lists package.json scripts, Make targets, deno / composer / Swift / Cargo / Go commands and `.orbit/settings.json` tasks; each runs in its own terminal tab, ⌘R reruns the last
- ⌘K Edit with Agent (D127): an instruction for the selection or the caret, the hidden agent's code lands as an inline agent change
- The open folder is watched (D126): files added, removed or changed outside Orbit show up in the tree, git and open files
- Review comments (D125): notes on agent change blocks or any lines (⌥⌘/), listed above the composer, sent to the chat as one message
- Usage popover (D124): context ring with Compact, Claude and Codex plan limits with resets, remembered across chats
- Tool calls fold like Claude Code (D122): quiet lines, runs of calls and thoughts as "Ran 4 commands ›"; your messages as bubbles on the right; commands and reply code blocks highlighted
- Chat like Claude Code (D120): pinned plan, "Thought for 8s", Esc stops, ↑/↓ history, ⇧Tab, focus after Deny, jump to latest, copy a reply
- Changed files show which chat changed them when several are open; key hints in an empty chat (D119)
- Tool cards: file names open the file at its change, +/− in the header; permission keys ⌘↩ / ⌃⌘↩ / ⌃⌘⌫; a bar for another chat waiting for approval (D118)
- One type scale for UI text, `Font.orbit(_:)` in OrbitUI (D117)
- Consecutive reads / searches fold into one transcript card (D116)
- Slash commands in the composer (`/` lists the agent's commands), a working line with the current action and a timer, a turn summary with time, changed files and Review (D115)
- Third performance pass (D114): image and PDF tabs keep zoom and scroll while an agent works, cached tool-card diffs, faster line-start scans
- Second performance pass (D113): queued shadow-git work (no lost refreshes), skipped baseline re-reads, debounced and cancellable Find in Files, cancelled stale diagnostics pulls
- Performance and memory pass (D112): cached review reads and diffs, coalesced git refreshes (no polling in the background), linear streaming Markdown, no leaked buffers from project-wide renames, notifications and Dock badge across windows
- Side-by-side diffs (toggle in every diff tab), Undo for Replace in Files, multiple selection in the explorer, Peek References ⌥⇧⌘R (D111)
- Indent guides, Find in Folder, Select for Compare (two-file diff tab), Find in Terminal and a terminal font size of its own (D110)
- Project options in `.orbit/settings.json` (D108): editor display / format on save, default agent, isolated sessions; Settings shows what the file decides; File → Open Project Settings
- Reassignable shortcuts (D107): recorder in Settings → Keyboard Shortcuts, conflicts move the key, reset per row / all
- Encodings and line endings (D106): file encodings, CRLF, BOM, binary and large-file refusal, status bar menu
- Text editing basics (D105): move / copy lines ⌥↑↓ ⇧⌥↑↓, multiple carets (⌘D, ⇧⌘L, ⌥-click, ⌃⇧↑↓), Go to Line ⌃G, matching bracket outline, font zoom ⌘= ⌘- ⌘0

## Next (rough priority)
1. Own extension registry (GitHub repo with `index.json`, PR to publish) for
   extensions Zed's catalog can't carry (languages, agents, code plugins)
2. Code plugins in TypeScript via JavaScriptCore, same package format
3. Developer ID signing and notarization (the script is ready for it, D129)

## Not implemented yet
Everything below is known to be missing; nothing here is in progress.

**Language features (LSP)**
- An inline peek editor for references (Peek References is a jump list, D111);
  no outline panel on purpose (D82)
- Code lens, semantic tokens and selection ranges; inlay hints
  can't be clicked, double-clicked to insert or hovered for their tooltip
- Call / type hierarchy, linked editing (renaming an HTML tag's pair)
- Other companions (Stylelint, Biome's server, Prettier's lint); companions
  and project roots are picked per file when it opens (a dependency or
  lockfile added later needs Restart Language Servers)
- Diagnostics for the whole project (workspace diagnostics): Problems lists
  open files, the agent's changed files (D75) and what servers push on their
  own; a file the agent broke without touching it (an importer) is missed
- File operations in workspace edits (create / rename / delete files from a
  rename or a code action); rename has no preview of the files it touches
- Imported servers (D65) aren't tested one by one (only Prisma's install
  runs in `make test-language-installs`); 93 of nvim-lspconfig's need code
  and are missing (Angular, Flow, Julia, PowerShell, Roslyn…); choosing
  another server for a language than the ranked one needs it installed and
  the first one not; RubyGems / NuGet / opam packages can't be installed (D57)

**Formatting**
- Format selection / range and format on type
- Running more than one tool in a row (Prettier, then ESLint fixes); ESLint
  is only used when nothing else formats the file
- Presets for languages Orbit has no server for (ktfmt / ktlint,
  google-java-format, `mix format`, `dart format`, CSharpier, nixfmt,
  sqlfluff); they work only as custom commands in `.orbit/settings.json`
- Global formatter installs for Node tools (only the repo's `node_modules`
  copy is used, on purpose); Pint and PHP CS Fixer don't use their cache
- Rules can't be edited in Settings, only in the JSON file; the Formatting
  section refreshes when Settings opens, not when the files change
- `.orbit/settings.json` (D108) has no font, indentation, terminal or per-agent model options; values aren't validated (an unknown key is ignored silently)

**Editor**
- Combined injections (PHP's HTML as one document, `injection.combined`):
  each piece is parsed on its own; embedded languages in read-only views
  (diffs, agent transcripts) aren't colored
- Completion placeholders drawn as tokens (they're only selected)
- Squiggles that follow edits before the server republishes
- Multiple carets: no column (box) selection by ⌥-drag; indentation rules,
  bracket pairs and completion work only with one caret (D105); bracket
  match counts brackets in strings and comments
- Large files (under the 50 MB limit, D106) open without any lighter mode: highlighting and LSP run as usual

**Git and terminal**
- Remote branches in the history's menu (All shows them); a three-pane
  merge editor; blame of a file at an older commit

## Known gaps / to verify
- Windows (D101): unverified on a Mac (windows coming back on launch, the
  close stand-in in front of SwiftUI's window delegate, menus following the
  main window, full screen with two windows; D102's Close Folder and
  folders from Finder / the Dock, at launch too). The clone has no progress beyond a spinner and no sign-in prompt (a
  private repository needs git credentials already set up).
- Inlay hints and embedded languages (D69, D70): unverified on a Mac (label
  placement and caret around them, colors in Markdown, Vue and HTML files;
  the first Markdown file installs the inline grammar).
- Companions (D64): ESLint and Tailwind run for real in the install tests;
  in the app (status bar names, merged completion with Tailwind's long
  class lists, the install banner) unverified on a Mac.
- Vue (D74): runs for real in the install tests; in the app (two install
  offers in a row, "Vue templates" in the status bar) unverified on a Mac.
  `.ts` files importing components don't see their props (their TypeScript
  server has no Vue plugin; a TypeScript 7 project can't load one at all).
  `sqlls` crashes on start (its unpinned protocol dependency); `.sql` gets
  `sqls` first.
- Checked by hand on a Mac on 2026-10-13 (TypeScript, Python): server install
  and the status-bar menu, Problems and References, navigation, completion,
  code actions, rename, formatting and its corner note, agent registry; the
  fixes it led to are in D66–D68. Still unchecked by hand: Rust, Go and the
  other servers, Tailwind/ESLint companions, the theme catalog's install.
- Navigation (D62): the server side runs in `make test-languages` (Swift,
  TypeScript) and `make test-language-installs` (outline for every server,
  references and project symbols for Python, Go, Rust; Rust not yet run, no
  cargo on the author's Mac). Go to Symbol in Project only asks servers
  already running.
- Bottom area header and status-bar panel buttons (D63): unverified on a Mac
  (terminal tabs in the header, badge colors, spacing next to agent items).
- Code actions / rename / formatting (D59): editor side unverified on a Mac
  (menu placement, rename field, undo). File operations in edits (create,
  rename files) are skipped.
- Formatting (D60, D61): the Formatting section in Settings → Languages, the
  corner note after ⌃⇧I and the failure alerts are unverified on a Mac; every
  formatter itself runs for real in the Linux install tests.
- Highlighting appearing only after a scroll or a keystroke on open: fixed by
  redrawing painted lines (D14 addendum), unverified on a Mac.
- The Swift cross-file rename in `make test-languages` fails now and then
  (sourcekit-lsp's index not ready yet); passes on a rerun.
- Grammars (D58, D71): compiling needs Xcode's command line tools and network on
  first open, now for every language (TypeScript too); a failed build isn't
  retried until restart. Unverified on a Mac: the first open's uncolored
  second, the background installs when a folder opens, colors of Zed's
  queries for Swift/TS/Markdown (they replaced the bundled ones). Release builds with hardened
  runtime will need `com.apple.security.cs.disable-library-validation`.
- Language installs (D57): every server installs and reports a problem in
  the Linux tests; the Settings page and status-bar button are unverified on a
  Mac. RubyGems/NuGet/opam packages aren't installable (Ruby is found on PATH
  only). One server per file type.
- Completion (D56): unverified on a Mac (popup look, keys, placement near
  screen edges, IME). Placeholders aren't drawn as tokens, only selected.
- LSP (D54): the client is tested against real servers on Linux (D55); the
  editor side (squiggles, hover card, ⌘-click) only by hand. sourcekit-lsp understands SwiftPM packages
  fully; Xcode projects (App/) get single-file results only (no build server).
  Squiggle positions lag edits until the server republishes. Servers that
  fail stay off until Restart Language Servers or reopening the folder.
- Agent registry (D52): unverified on a Mac (the cloud container can't reach
  the registry CDN): install of npx and binary agents, the first-launch
  migration of Claude Code / Codex, icons. Agents installed while Orbit runs
  find Node.js / uv only on the PATH resolved at launch.
- Extensions catalog: written against Zed's API without a live check (the
  cloud container can't reach api.zed.dev); verify listing, download/unpack,
  try-on and the bar over the editor on a Mac. Theme selector (D49) and
  thumbnails are unverified too.
- Usage ring: Codex also reports its subagents' context through `usage_update`
  without saying so, so the ring can briefly show a subagent's context.
- Manual typing inside a highlighted diff block is implemented but not yet
  verified by hand.
- Disk conflicts: merging an agent's edit into unsaved edits makes those edits
  count as agent changes in the inline review (its baseline is the disk before
  the turn).
- Terminal: the panel hides when the last shell exits. Find (D110) is
  SwiftTerm's own find bar, unverified on a Mac (⌘F reaching it through
  Edit → Find, its look next to Orbit's glass).
- Agent terminals: the `terminal/*` (PTY) path is untested with a real agent
  (Claude Code and Codex use display terminals); check how many tabs a busy
  turn leaves.
- Split editor (D90): unverified on a Mac (the tab row's split line meeting
  the editors' with the sidebar shown and hidden, in full screen; dragging;
  focus by click into the terminal-free area; two editors of one file).
  Only two sides, side by side.
- Explorer moves (D92): unverified on a Mac; an agent's unreviewed changes
  in a moved or renamed file lose their inline review.
- Explorer file operations (D93): unverified on a Mac (the name field's
  focus and selection inside the list, Return / ⌘⌫ reaching the list, the
  header's hover buttons, ⌘Z routing). Undoing a new file drops its unsaved
  edits. Multiple selection (D111) unverified on a Mac (⌘- / ⇧-click in the
  list with our own row highlight, the menu acting on all rows); dragging
  moves one item.
- Explorer folder clicks (D96): unverified on a Mac (the row's tap gesture
  reaching a click on an already selected folder).
- Theme accent (D97): unverified on a Mac (prominent glass buttons tinted
  with the text color in the System theme; sheets and hover panels hosted
  outside the window's `.tint`). Focused native lists outside the explorer
  still select in the system accent.
- Keyboard navigation (D98): unverified on a Mac (the list taking focus on
  ⇧⌘E, Space / Escape reaching it, arrows with the key filter). No
  keyboard focus for the other sidebar panels.
- Location history (D99): unverified on a Mac (the caret reports after a
  reveal, ⌃Tab's panel and ⌃ release). Moving a tab between sides records
  passing through the tab left behind; no mouse back / forward buttons.
- Preview tabs (D94): unverified on a Mac (a double click on a list row
  reaching the gesture beside the list's own selection; the tab's double
  click beside its drag). Open Quickly doesn't preview, unlike VS Code.
- Explorer context menu (D95): unverified on a Mac (⌘X ⌘C ⌘V reaching the
  list through the Edit menu, ⌃↩ / ⌥⌘R / ⌥⌘C keys, app icons in Open With).
  Compare and Find in Folder (D110) unverified on a Mac.
- Drag and drop (D91): tab drags became our own gesture (the system drag
  hung after drops); unverified on a Mac. Dropping files on the editor rests
  on an assumption (AppKit finds the catcher above the text view although
  its `hitTest` is nil). Tabs can't be dragged out of the window.
- Preview (D89): unverified on a Mac (zoom and centering, the info
  capsule, the page's look in light and dark themes, code colors, links,
  relative images); no side-by-side preview (no split editor); preview tabs
  aren't restored on launch; code colors don't change with the theme until
  the next edit.
- Agents overview and notification actions (D130): unverified on a Mac and with real agents (the popover from the status bar, the window coming forward, Allow from a notification while Orbit is behind).
- Rewind (D132): unverified with a real agent (does it follow the note to disregard the rewound part?).
- Create PR (D133): the git and `gh` path runs in the tests against a local remote and a stand-in `gh`; against GitHub, and the sheet and badge, unverified. A later agent turn doesn't update the pull request.
- Releases (D129): no release made yet — the first `make release` (keychain access for the Sparkle key) and an update from one release to the next are unverified; Gatekeeper's first-launch prompt for an ad hoc build.
- Tasks (D128): unverified on a Mac (typing into a shell that's still starting, e.g. with a slow prompt; ⌃C then restart of a dev server; ⌘R reaching the menu from the terminal and the chat). No problem matchers, no running-task indicator, root package only.
- ⌘K (D127): unverified on a Mac and with a real agent (the popover's place above the selection, how Claude Code's plan mode and Codex's read-only mode answer the prompt, the time a warm agent takes).
- Folder watching (D126): unverified on a Mac (latency in the tree, CPU while a terminal build runs in the project).
- Review comments (D125): unverified on a Mac and with a real agent (the popover's place under a block and its keys, the note in the block's bar and the chip off blocks, the bar above the composer). Notes aren't saved across launches; a note follows its code only when the code is unchanged.
- Usage popover (D124): unverified on a Mac; Claude limits only as its events come (one window each), Codex limits only as fresh as its last logged turn.
- Tool call folding (D122): unverified on a Mac and with a real agent (the line spacing, a running command folded away while its output streams).
- Transcript (D121): rows are a `LazyVStack`, so rows not made yet have guessed heights; scrolling up a long chat can still shift as they come in. Streaming while scrolled up is unverified on a Mac.
- Chat like Claude Code (D120): unverified on a Mac and with a real agent (⇧Tab reaching the field as backtab, Esc and ↑ beside the text field's own keys, the pinned plan's height, the copy button's place, the jump button while streaming).
- Chat attribution and hints (D119): unverified on a Mac (the agent icon beside the stats and the hover buttons, the hints grid under the greeting).
- Tool card links and permission keys (D118): unverified on a Mac and with a real agent (the link's hover, keys reaching the buttons from the editor and the composer, the waiting bar).
- Type scale (D117): unverified on a Mac (bars over the composer, bottom panel and terminal tabs went 11.5 → 11, the model popover's rows 12.5 → 13, the palette's query 16 → 15).
- Folded reads (D116): unverified on a Mac and with a real agent (the card's look, expanding while calls stream in).
- Slash commands and turn summary (D115): unverified on a Mac and with a
  real agent (the command list's look and scrolling, Return picking vs.
  sending, the timer, the summary row and its Review). Summaries aren't
  restored with a reloaded conversation.
- Message queue (D88): unverified on a Mac and with a real agent (Send Now
  stopping a turn, the paused state); kept across launches since D131.
- Notifications (D87): unverified on a Mac (the permission prompt for an
  ad-hoc signed debug build, click to open the chat, the badge); Allow /
  Deny in the notification since D130.
- MCP servers (D86): not run with a real agent yet (that each adapter
  accepts the list and starts the servers); the Settings section is
  unverified on a Mac. No per-agent status of which servers connected.
- Restore points (D85): unverified on a Mac (the hover button, the dialog,
  the note to the agent); not available in isolated sessions; the
  conversation isn't rewound with the files.
- Isolated sessions: a project on a non-APFS volume gets a full (slow) copy; Apply is
  all-or-nothing per file (no picking files); undoing an applied change in
  the project counts it as not applied again; untested by hand.
- Agent sessions: listing an agent's conversations spawns that agent once per
  folder per launch.
- Replace in files: Undo in the panel (D111) puts back the last replace
  only, and skips files edited since; ⌘Z doesn't reach it. Unverified in
  the UI.
- Side-by-side diffs (D111): unverified on a Mac (row heights with long
  wrapped lines on one side, the header toggle).
- Git (D134–D136): unverified on a Mac (the conflict blocks and their bar,
  the blame column's width beside wide line numbers and folds, the graph's
  lines meeting between sidebar rows and its colors in light and dark).
- Indent guides (D110): unverified on a Mac (crisp 1-pt lines, placement
  with tabs, inline-diff gaps and folds; a theme's `editor.indent_guide`).
- Project options (D108): unverified on a Mac (the "Set by" notes and
  disabled toggles, options changing on save of the file).
- Shortcuts (D107): unverified on a Mac (the recorder taking keys before
  Settings' own Esc, menus updating at once, a reassigned key in a second
  window). Function keys and keys without ⌘⌃⌥ can't be recorded; a command
  has one user key (Move Line keeps ⌥↑ beside a reassigned menu key).
- File formats (D106): unverified on a Mac (the status-bar menu, "Reopen
  with Encoding" in the Can't Open state, a CRLF file's inline agent review).
- Text editing basics (D105): unverified on a Mac (keys reaching the editor
  before STTextView's own ⌥↑ / ⌃⇧↑ bindings, the caret drawing for several
  carets, ⌥-click, the Go to Line popover's placement, the bracket outline).
- Claude Code requires the standalone `claude` CLI to be logged in (`claude` → `/login`).
