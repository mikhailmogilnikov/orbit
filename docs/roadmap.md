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
- Git stash (stash with untracked files, pop/apply/delete), History (last 200
  commits; expand for files, click for a read-only diff tab), blame of the
  caret's line in the status bar (`EditorSelectionProviding.cursor`)
- Git change markers in the editor gutter (green added, blue modified, red
  wedge for deletions) against the index, via `VersionControlBaseline`
- Prompt attachments: `@` in the composer picks project files (⌘P ranking via
  `ProjectFileIndex`), ⌘L attaches the editor selection (`EditorSelectionProviding`),
  files and images by drop, the paperclip menu or "Paste Image"; chips show on
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
- App icon (Icon Composer) and brand mark in the UI; welcome screen with clickable actions

## Next (rough priority)
1. Git worktree per agent session, opt-in ("Isolated" toggle on a new session);
   "Apply" brings the changes into the project as regular inline-reviewed agent
   changes (see D21)
2. Minimal LSP: diagnostics, go to definition, hover
3. External plugins in TypeScript via JavaScriptCore
4. Release build, notarization, Sparkle updates

## Known gaps / to verify
- Manual typing inside a highlighted diff block is implemented but not yet
  verified by hand.
- Dirty buffers vs agent writing the same file on disk: no conflict UI yet
  (clean buffers reload automatically).
- Terminal: no find-in-terminal, font size follows the editor only, panel
  hides when the last shell exits.
- Agent terminals: the `terminal/*` (PTY) path is untested with a real agent
  (Claude Code and Codex use display terminals); check how many tabs a busy
  turn leaves.
- Agent sessions: listing an agent's conversations spawns that agent once per
  folder per launch.
- Attachments: ⌘V can't paste an image into the composer (the text field eats
  the paste); use the paperclip menu's "Paste Image". @-mentions only work at
  the end of the draft.
- Replace in files has no undo beyond the editor's own (files that weren't
  open are written straight to disk); written while unverified in the UI.
- Git: diff tabs are unified and not syntax-highlighted; History shows only the
  current branch, without search or a graph; blame is only the caret's line
  (no per-line annotations).
- Claude Code requires the standalone `claude` CLI to be logged in (`claude` → `/login`).
