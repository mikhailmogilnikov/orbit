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
  ⌘S over such a change asks first
- Isolated agent sessions (opt-in: checkbox on the start screen, + ▸ Isolated
  Copy, ⌥⇧⌘N): the agent works in an APFS clone of the project; Apply brings
  its changes back as inline-reviewed agent changes, merging with project
  edits on other lines and reporting same-line conflicts; closing the session
  deletes the copy (asks when changes weren't applied)
- App icon (Icon Composer) and brand mark in the UI; welcome screen with clickable actions

## Next (rough priority)
1. Minimal LSP: diagnostics, go to definition, hover
2. External plugins in TypeScript via JavaScriptCore
3. Release build, notarization, Sparkle updates

## Known gaps / to verify
- Manual typing inside a highlighted diff block is implemented but not yet
  verified by hand.
- Disk conflicts: merging an agent's edit into unsaved edits makes those edits
  count as agent changes in the inline review (its baseline is the disk before
  the turn); a file deleted on disk under unsaved edits isn't flagged.
- Terminal: no find-in-terminal, font size follows the editor only, panel
  hides when the last shell exits.
- Agent terminals: the `terminal/*` (PTY) path is untested with a real agent
  (Claude Code and Codex use display terminals); check how many tabs a busy
  turn leaves.
- Isolated sessions: copies of sessions closed while Orbit wasn't running (or
  crashed) stay in `~/Library/Application Support/Orbit/isolated` — no cleanup
  yet; a project on a non-APFS volume gets a full (slow) copy; Apply is
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
