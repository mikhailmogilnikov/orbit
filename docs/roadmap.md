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
- Editor: STTextView, line numbers, tree-sitter highlighting (~20 languages), save
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

## Next (rough priority)
1. LSP, next steps (D54): inlay hints; injections for embedded languages
2. Own extension registry (GitHub repo with `index.json`, PR to publish) for
   extensions Zed's catalog can't carry (languages, agents, code plugins)
3. Code plugins in TypeScript via JavaScriptCore, same package format
4. Release build, notarization, Sparkle updates

## Not implemented yet
Everything below is known to be missing; nothing here is in progress.

**Language features (LSP)**
- An outline panel (symbols are only in the ⇧⌘O picker); a peek view for
  references (they go to the References panel)
- Inlay hints, code lens, semantic tokens, folding and selection ranges
- Call / type hierarchy, linked editing (renaming an HTML tag's pair)
- Other companions (Stylelint, Biome's server, Prettier's lint); companions
  and project roots are picked per file when it opens (a dependency or
  lockfile added later needs Restart Language Servers)
- Companions (ESLint, Tailwind) can't be turned off or configured in
  `.orbit/settings.json` (only "Not Now" on their install offer)
- Diagnostics for files that aren't open (workspace / pull diagnostics for
  the whole project); the Problems panel lists open files only
- File operations in workspace edits (create / rename / delete files from a
  rename or a code action); rename has no preview of the files it touches
- Code actions on save (organize imports, ESLint fixes after Prettier formats)
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
- `.orbit/settings.json` holds `formatters` and `languageServers` only (no
  editor or agent options yet)

**Editor**
- Tree-sitter injections (CSS / JS inside HTML, Svelte, Vue, Markdown code blocks)
- Completion placeholders drawn as tokens (they're only selected)
- Squiggles that follow edits before the server republishes

**Git and terminal**
- Side-by-side diffs, branch graph and history search, other branches'
  history, per-line blame annotations
- Find in terminal, a terminal font size of its own

## Known gaps / to verify
- Companions (D64): ESLint and Tailwind run for real in the install tests;
  in the app (status bar names, merged completion with Tailwind's long
  class lists, the install banner) unverified on a Mac. Vue and Astro files
  get ESLint/Tailwind only (no language server of their own).
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
- Grammars (D58): compiling needs Xcode's command line tools and network on
  first open; a failed build isn't retried until restart. No injections
  (CSS/JS inside Svelte/HTML stay plain). Release builds with hardened
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
- Terminal: no find-in-terminal, font size follows the editor only, panel
  hides when the last shell exits.
- Agent terminals: the `terminal/*` (PTY) path is untested with a real agent
  (Claude Code and Codex use display terminals); check how many tabs a busy
  turn leaves.
- Isolated sessions: a project on a non-APFS volume gets a full (slow) copy; Apply is
  all-or-nothing per file (no picking files); undoing an applied change in
  the project counts it as not applied again; untested by hand.
- Agent sessions: listing an agent's conversations spawns that agent once per
  folder per launch.
- Replace in files has no undo beyond the editor's own (files that weren't
  open are written straight to disk); written while unverified in the UI.
- Git: diff tabs are unified (no side-by-side); History shows only the
  current branch, without search or a graph; blame is only the caret's line
  (no per-line annotations).
- Claude Code requires the standalone `claude` CLI to be logged in (`claude` → `/login`).
