# Roadmap

## Done
- App shell: navigator / tabs / inspector / status bar, command palette, menus from commands, settings
- Plugin kernel (UI, commands, services registries; enable/disable)
- Explorer (lazy file tree)
- Editor: STTextView, line numbers, tree-sitter highlighting (~20 languages), save
- Agents over ACP: Claude Code, Codex, custom JSON agents; parallel sessions;
  streaming transcript, thinking, tool cards with diffs/output, plans,
  permission prompts, model/mode/effort pickers from `configOptions`
- Change tracking via shadow-git checkpoints
- Inline Cursor-style diffs in the editor with per-block Keep/Undo + navigation
- Changes panel, status bar counters
- Open Quickly ⌘P (fuzzy, git-aware file index) and Find in Project ⇧⌘F
  (in-process parallel search: case / whole word / regex, unsaved buffers included)
- Integrated terminal (SwiftTerm) in a resizable bottom panel: multiple tabs,
  login shell in the project folder, follows light/dark
- Source Control panel: staged / changes / conflicts, stage / unstage / discard
  (new files go to the Trash), commit (⌘↩, "Commit All" when nothing staged),
  branch switch / create, pull / push / fetch, ahead/behind; ✨ Generate Commit
  Message via a hidden agent session (`AgentCompletion` service); diff tabs
  for working-tree / staged changes; git colors and badges in the explorer
  (`FileStatusProviding` service)
- App icon (Icon Composer) and brand mark in the UI; welcome screen with clickable actions

## Next (rough priority)
1. Git worktree per agent session, opt-in ("Isolated" toggle on a new session);
   "Apply" brings the changes into the project as regular inline-reviewed agent
   changes (see D21)
2. ACP terminal capability (show agent commands live, reuse the terminal plugin)
3. @-mentions / attach files and selections to prompts; images (reuse the
   Search plugin's file index via a service)
4. Minimal LSP: diagnostics, go to definition, hover
5. External plugins in TypeScript via JavaScriptCore
6. Session persistence/resume (ACP `loadSession`)
7. Release build, notarization, Sparkle updates
8. Search: replace in files, include/exclude globs, recent files in ⌘P

## Known gaps / to verify
- Manual typing inside a highlighted diff block is implemented but not yet
  verified by hand.
- Dirty buffers vs agent writing the same file on disk: no conflict UI yet
  (clean buffers reload automatically).
- No unsaved-changes prompt on quit.
- Terminal: no find-in-terminal, font size follows the editor only, panel
  hides when the last shell exits.
- Git: diff tabs are unified and not syntax-highlighted; no gutter change
  markers in the editor; no stash, history or blame.
- Claude Code requires the standalone `claude` CLI to be logged in (`claude` → `/login`).
