# Roadmap

## Done
- The stress run checks that closed tabs, windows, terminals, chats and plugins turned off are freed, plays git conflicts (merge, rebase, cherry-pick, stash pop), shrinks a failed run to its fewest steps (`SHRINK=`), runs on macOS 26 in the VM (`make stress-vm`), and `make stress-full` (longer, with `leaks`) gates `make release` (D246); fixed what it found: a hang on macOS 26 and 1x screens with a zoomed font in a narrow split, every closed tab kept its text view and the file's layout, Settings kept every pane's models each time it opened, and the Explorer, the editor and the inline edit prompt kept plugins that were turned off
- The stress run in four parallel copies, each in a mode (scrollers that take room, text sizes, themes, a big project), with external chaos, a pretend ACP agent and a pretend language server (D245); fixed what it found: two layout hangs (agents' chat, split tabs), a freeze typing in minified files, the Problems list crash
- Every feature is in the stress run (D244): plugins bring steps, checks and project files, Orbit runs every command, panel, Settings pane, plugin switch and step, then random ones; uncovered features fail it and `StressCoverageTests`
- `make stress` drives a debug build through awkward files, window sizes, full screen, edits and agent edits, in order and at random, and stops on a crash, a hang or a busy CPU, in the background beside the Orbit in use (D243); overlapping selections merge, Join Editors right after Split no longer crashes
- A crash at launch is followed by a safe start (welcome window, Check for Updates, Reopen Projects); a release build must survive opening a project before it's zipped (D242)
- Symlinks: folder links expand in the explorer and the path bar and are in Open Quickly and Find in Project (no loops), saves go through to the target, links get an arrow and a tooltip (D238); a file and a link to it share one buffer, linked folders are indexed by git (D239)
- The editor scrolls past the last line; a click under the text goes to the last line (D237)
- App shell: navigator / tabs / inspector / status bar, command palette, menus from commands, settings
- Open-source basics (D206): GPL-3.0, README, contributing / security / conduct, issue forms, CI on macOS and Linux;
  dependencies' licenses in About Orbit (D207)
- The agent's working shimmer runs in Core Animation: no per-frame redraw of the window while an agent works (D208)
- Website in `site/` (D216): a working Orbit window, measured numbers against Zed / VS Code / Cursor, shortcuts, extensions guide, changelog and roadmap read from the repo; on GitHub Pages; GoatCounter counts visits and Download clicks, no cookies (D223)
- First-launch tour (D205): an intro film, setup of agents / look / review keys / `orbit` command, Help → Welcome to Orbit
- Orbit's own extension registry (D224): `mikhailmogilnikov/orbit-extensions`, a pull request to publish,
  checked archives, a question listing the programs before a package that starts them is installed
- Extension packages bring snippets, agents, language servers and tasks besides themes and icons (D195):
  snippets in completion and Insert Snippet…, Zed's snippet extensions, a page per package, New Extension…
- Plugin kernel (UI, commands, services registries); plugins turn on and off live, in every window,
  and require each other (D194): Git Lens under Source Control, Browser apart from Preview
- Settings screen inside the window (⌘,), laid out like System Settings (D158):
  the project on top (its .orbit/settings.json overrides), then groups —
  General, Appearance, Notifications · Editor, Files, Languages, Formatting, Source Control, Terminal ·
  Agents, MCP Servers · Keyboard Shortcuts, Extensions; colored tiles,
  a header card per pane, rows that open pages (an agent's page, the theme catalog),
  back / forward (⌘[ ⌘]), search that finds single options and lights up their row (D177);
  plugins add panes (`SettingsPane`, `SettingsForm`, `SettingsItem` + `.settingsItem`)
- One Extensions page for everything installable (D192): agents (ACP registry), language
  servers (Mason), themes and icons (Zed), built-in features; one search, a filter by kind,
  Install / Update / switch / Uninstall per row; plugins add kinds with `ExtensionSource`
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
- Find in File ⌘F as a Liquid Glass panel over the editor: counter, case / word / regex,
  replace and Replace All in one undo, matches on the overview ruler, ⌘G / ⇧⌘G / ⌘E (D227)
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
  Browse the Catalog (search, try on, install, update, uninstall); try-on bar over the editor
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
- Rename preview (⇧↩, a sheet of every file's diff, rows can be left out); server edits that
  create, rename and delete files (D199)
- Call and type hierarchies (⌃⇧⌘H) in a Hierarchy bottom panel, a level at a time (D200)
- Semantic highlighting over tree-sitter (types, parameters, properties…) and code lenses after the
  line, clickable when Orbit can run them (D201)
- Remote branches in History's scope menu; a file at any commit with its blame, walking back (D204)
- Formatter chains in `.orbit/settings.json` (`["prettier", "eslint"]`) and format on type (D203)
- Typing rules and completion at every caret, bracket match outside strings and comments, linked
  tag editing, Expand / Shrink Selection ⌃⇧⌘→ ⌃⇧⌘←, squiggles that move with edits, snippet
  placeholders drawn as tokens (D202)
- Problems for every file the agent changed, open or not; kept after review
  until fixed (D75); and for the files using them, found by references and
  imports (D198)
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
- A window per project: Open Folder in a project's window opens a new one, New Window ⌃⌘N, the open folders come back on launch; Cursor-style welcome window with Open Folder, Clone Repository and recent projects (D101)
- File → Close Folder back to the welcome window; folders dropped on the Dock icon or opened with Orbit from Finder (D102)
- Go Back ⌃- / Go Forward ⌃⇧- through caret locations across files, ⌃Tab recent-tab switcher (D99)
- Output follows only from the bottom of the chat; scrolled up, what you read stays put (D121)
- Merge conflicts in the editor (D134): Accept Current / Incoming / Both per block, Accept All, Mark as Resolved
- Blame after the caret's line, as GitLens (D187, ⌥⌘B; replaced D135's column): author, age, summary; hover for the commit
- History of any branch with search and a graph, ref badges (D136)
- Task errors in Problems and as squiggles (D137): tsc, clang / Swift / Go, Rust, ESLint; Python, pytest, Jest, Vitest, esbuild, Vite (D220)
- Offers to move itself to Applications when launched elsewhere, where updates can't install (D221)
- Running tasks in the status bar with Show / Restart / Stop; monorepo packages' scripts in Run Task… (D138)
- Box selection by ⌥-drag (D139); Format Selection keeps only the selection's changes (D140)
- Large files open light (D141): no highlighting, LSP, git markers or blame, with Turn On
- `orbit .` from a terminal (D142): Orbit → Install 'orbit' Command…; files open in their project's window
- Built-in browser (D143): Open Browser… and a running task's "Open localhost:5173 in Orbit", back / forward / reload, Web Inspector
- Push later agent turns to the pull request (D144)
- History rows on two lines with merged branch badges and a calmer graph (D156)
- One set of corner radii, hover / selection fills, badges and chevrons in `Theme` (D157)
- Terminal editing keys (D155): ⌥←/→, ⌘←/→, ⌥⌫, ⌘⌫, ⇧↩ new line, ⌘K clear, ⌘↑/↓ scroll
- ⌃C in any keyboard layout and after a program left the kitty keyboard protocol on; ⇧↩ new line in the agent chat; ⌘⌫ at a line's start joins it to the line above (D217)
- Code-editor keys (D218): ⌥←/→ and ⌥⌫ stop at punctuation and line ends, ⌘← to the code first, ⌘⌦ / ⌃K at a line's end, ⌃↩ / ⌥↩ as Return, ⌘C / ⌘X without a selection take the line, Delete Line ⇧⌘K, Indent / Outdent ⌘] / ⌘[
- Terminal: files dropped in type their paths, ⌥-click moves the cursor, a right-click menu; the chat's ↑/↓ recall only from the first / last line (D219)
- Fix with Agent from Problems (D147); ⌘-click `file:line` in the terminal (D148)
- Color swatches in the gutter with the color panel (D149); Copy GitHub Link / Open on GitHub (D150)
- Sort / dedupe / reverse lines and case conversions (D151); pasted images in Markdown saved to assets/ (D152)
- Keep awake while agents work, a sound when one finishes (D153); a stash's files and diffs (D154)
- SVG opens as a live picture, Show Source / ⇧⌘V flips to the code (D145); image thumbnails in the gutter with hover and click (D146)
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
0. Two failures the stress run saw once and couldn't replay (D246): a copy
   quit with no crash report while its project folder was renamed and back,
   and in the big project an editor showed 28 of a 31-character file's
   characters after switching tabs
1. Code plugins in TypeScript via JavaScriptCore, same package format
2. Developer ID signing and notarization: the script is ready (D222); waits for
   an Apple Developer Program membership and its certificate

## Not implemented yet
Everything below is known to be missing; nothing here is in progress.

**Beyond an editor (non-goals for now, [product.md](product.md))**
- No debugger (no breakpoints, no Debug Adapter Protocol)
- No refactoring tools of Orbit's own: refactorings are what the language
  server offers as code actions and rename

**Language features (LSP)**
- An inline peek editor for references (Peek References is a jump list, D111);
  no outline panel on purpose (D82)
- Inlay hints
  can't be clicked, double-clicked to insert or hovered for their tooltip
- Other companions (Stylelint, Biome's server, Prettier's lint); companions
  and project roots are picked per file when it opens (a dependency or
  lockfile added later needs Restart Language Servers)
- Diagnostics for the whole project (workspace diagnostics): Problems lists
  open files, the agent's changed files (D75), the files using them (D198)
  and what servers push on their own; nothing else is checked
- Imported servers (D65) aren't tested one by one (only Prisma's install
  runs in `make test-language-installs`); 93 of nvim-lspconfig's need code
  and are missing (Angular, Flow, Julia, PowerShell, Roslyn…); choosing
  another server for a language than the ranked one needs it installed and
  the first one not; RubyGems / NuGet / opam packages can't be installed (D57)

**Formatting**
- Format Selection (D140) formats the whole file and keeps only the selection's changes
- Formatter chains (D203) come only from settings; detection picks one tool, ESLint only when
  nothing else formats the file
- Presets for languages Orbit has no server for (ktfmt / ktlint,
  google-java-format, `mix format`, `dart format`, CSharpier, nixfmt,
  sqlfluff); they work only as custom commands in `.orbit/settings.json`
- Global formatter installs for Node tools (only the repo's `node_modules`
  copy is used, on purpose); Pint and PHP CS Fixer don't use their cache
- Rules can't be edited in Settings, only in the JSON file (simple options can, D183); the Formatting
  section refreshes when Settings opens, not when the files change
- `.orbit/settings.json` (D108) has no font, indentation, terminal or per-agent model options; keys are checked by the JSON server's schema (D182), not by Orbit itself

**Editor**
- Combined injections (PHP's HTML as one document, `injection.combined`):
  each piece is parsed on its own; embedded languages in read-only views
  (diffs, agent transcripts) aren't colored
- Multiple carets (D202): a snippet accepted at several carets has no Tab walk; linked editing
  with several carets isn't linked

**Git and terminal**
- A three-pane merge editor (conflicts are resolved inline, D134)

## Known limitations
What works differently than you'd expect today. Things built but not yet
tried by hand are in [manual-checks.md](manual-checks.md).

- An agent turn in a project of 20 000 files takes about 11 s before it
  starts: the checkpoint snapshots the whole tree (D245). The UI stays
  responsive.
- A plugin turned off can stay in memory until the views that showed it draw
  again (a hidden inspector, a list's reused cells, the menu bar): one
  instance, not one per switch (D246).

**Agents and review**
- Claude Code needs the standalone `claude` CLI logged in (`claude` → `/login`).
- Merging an agent's edit into unsaved edits makes those edits count as agent
  changes in the inline review (its baseline is the disk before the turn).
- An agent's unreviewed changes in a file moved or renamed in the explorer
  lose their inline review. A review note follows its code only while the
  code is unchanged.
- Isolated sessions: a project on a non-APFS volume gets a full (slow) copy;
  Apply is all-or-nothing per file; undoing an applied change in the project
  counts it as not applied again. Restore points aren't available there.
- Listing an agent's conversations spawns that agent once per folder per
  launch. Agents installed while Orbit runs find Node.js / uv only on the
  PATH resolved at launch.
- Usage: Codex reports its subagents' context without saying so, so the ring
  can briefly show a subagent's; Claude's limits arrive only with its events
  (one window each), Codex's are as fresh as its last logged turn.
- The transcript's rows are lazy, so scrolling up a long chat can shift as
  rows come in. Turn summaries aren't restored with a reloaded conversation.
- No per-agent status of which MCP servers connected.

**Language features**
- sourcekit-lsp understands SwiftPM packages fully; Xcode projects get
  single-file results only (no build server).
- Squiggles move with edits until the server republishes. A server that
  fails stays off until Restart Language Servers or reopening the folder.
  Go to Symbol in Project only asks servers already running.
- Renaming a file in the explorer doesn't ask servers to update imports
  (`workspace/willRenameFiles`).
- One server per file type. RubyGems / NuGet / opam packages can't be
  installed (Ruby is found on PATH only).
- Vue: `.ts` files importing components don't see their props (their
  TypeScript server has no Vue plugin; a TypeScript 7 project can't load one).
  `sqlls` crashes on start, so `.sql` gets `sqls` first.
- Grammars compile on first open and need Xcode's command line tools and
  network; a failed build isn't retried until restart.
- The Swift cross-file rename in `make test-languages` fails now and then
  (sourcekit-lsp's index not ready yet); it passes on a rerun.

**Editor and workspace**
- A Mac without the Command Line Tools has no git and no compiler: Source
  Control says the folder isn't under version control, no grammar compiles
  (no highlighting), and macOS keeps asking to install the tools (D235).
- The split editor has two sides, side by side. Tabs can't be dragged out of
  the window; dragging in the explorer moves one item.
- Undoing a new file in the explorer drops its unsaved edits.
- Changes inside a symlinked folder pointing outside the project are seen
  only while it's loaded in the explorer or holds an open file (D239). A file
  opened by two paths is one buffer, under the path it was first opened by.
- Location history: moving a tab between sides records passing through the
  tab left behind; no mouse back / forward buttons. Open Quickly doesn't
  open preview tabs.
- Markdown preview: no side-by-side view; preview tabs aren't restored on
  launch; code colors follow a theme change only after the next edit.
- Replace in files: the panel's Undo puts back the last replace only and
  skips files edited since; ⌘Z doesn't reach it.
- Shortcuts: function keys and keys without ⌘⌃⌥ can't be recorded; a command
  has one user key (Move Line keeps ⌥↑ beside a reassigned menu key).
- No keyboard focus for sidebar panels other than the explorer; focused
  native lists outside it select in the system accent.
- Cloning shows only a spinner and has no sign-in prompt (a private
  repository needs git credentials already set up).
- Registry packages (D224): only the newest version is offered; packages
  from it have no page of their own before they're installed (no screenshots,
  no README), and there's no download count or sorting by it.

**Terminal, tasks and browser**
- The terminal panel hides when the last shell exits.
- Problem matchers cover tsc, clang / Swift / Go, Rust, ESLint, Python,
  pytest, Jest, Vitest, esbuild and Vite (not Mocha, Playwright, mypy, Ruff…);
  a fixed error stays listed until the task reruns.
- The browser has no tabs of its own, no find in page and no device sizes.
