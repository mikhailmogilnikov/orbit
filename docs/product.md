# Orbit — Product

## What it is

A native macOS IDE for working with AI coding agents (Claude Code, Codex and any
other ACP-compatible agent). Think "Cursor in IDE mode", but built with
SwiftUI/AppKit instead of Electron.

## Who it's for

Developers on the Mac who let agents write most of the code and want a fast,
native place to steer and review them. It started as its maintainer's daily
driver and isn't a venture-scale product; the bar is "I prefer this over
Cursor for agent work".

## Product principles

1. **Native and light.** Minimal memory, near-zero idle CPU, low battery impact.
   Apple-native look and feel (Liquid Glass, system controls, SF Symbols).
   Note: the agent CLIs themselves (Node processes) cost hundreds of MB — we can
   only make *our* shell light; be honest about this.
2. **Review-first.** Agents write the code; the human reviews and steers. The
   most important surface is reviewing agent changes, not typing code.
3. **Inline review, no mode switch.** Agent changes appear *directly in the
   editor* like Cursor: green added lines, red "ghost" removed lines, per-block
   Keep / Undo. There is deliberately **no separate review tab** (D7).
4. **Everything is a plugin.** The core knows almost nothing; explorer, editor,
   review, agents are plugins on the same public API future third-party plugins
   will use (inspired by "harness" designs where everything is pluggable).
5. **Agent-agnostic.** Claude Code and Codex are first-class, but any ACP agent
   can be added with a JSON file — no code.
6. **Beautiful by default.** Polish matters as much as features.

## Competitive landscape (as of Oct 2026)

| Product | Notes |
|---|---|
| Cursor / Windsurf | Feature bar to match, but Electron (heavy). |
| Zed | Strongest competitor: Rust, GPU-rendered, ACP support, inline agent review. Not Apple-native in feel. |
| Claude Code desktop, Codex app | Official apps; chat-centric rather than IDE. |
| Conductor, Crystal, Vibe Kanban, Superset | Parallel-agent orchestrators (worktrees), not IDEs. |
| Nova, CodeEdit | Native Mac editors without an agent focus. |

**Positioning:** the most beautiful, fastest native place on the Mac to run
agents and review their work.

## Non-goals (for now)

- Competing with full IDEs on LSP depth, debuggers, refactoring tools.
- Mac App Store distribution (sandbox forbids spawning agent CLIs).
- Windows/Linux.
- Our own model/agent — we host existing agents.

## Key UX decisions

- **First launch:** a short film (agents orbiting a project, an agent change
  kept inline), then four setup steps (agents, look, review keys, `orbit`
  command) and a closing line (D205). Help → Welcome to Orbit replays it.
- **Layout:** left navigator (Explorer, Search, Source Control), center tabs + editor + status
  bar, right inspector with agent sessions. Tabs sit in the title bar next to the traffic lights; the inspector toggle is at the end of that row.
- **Agent chat:** multiple sessions as chips; transcript shows streamed text
  (Markdown), collapsible "Thinking", tool-call cards (with diffs/command
  output), plans, and inline permission prompts. Model / mode / effort pickers
  come from the agent's ACP `configOptions` (not hard-coded).
- **Composer:** Return sends, Esc or ⌘. stops, ↑/↓ recall sent messages, ⇧Tab cycles the mode (also a button beside the options), ⌘L focuses chat, ⇧⌘N new session.
  The turn's plan is pinned above the composer; thoughts say how long they took.
  `/` at the start lists the agent's slash commands, `@` lists files. While
  the agent works the transcript ends with what it's doing and a timer; a
  turn that changed files (or took 30 s+) ends with "Worked for … · N files
  changed · Review".
  Permission prompts: ⌘↩ allow once, ⌃⌘↩ always, ⌃⌘⌫ deny; another chat
  waiting for approval shows a bar over the composer, and its notification
  has Allow / Deny. A tool card's file name opens the file at its change.
  ↺ on a message rewinds the chat and the files to before it (or the files
  only). The status bar's agents item (⌃⌘A) lists every window's chats.
  An isolated chat's changes can become a GitHub pull request (Create PR).
- **Inline diff review:** banner above the file ("N agent changes +a −r",
  prev/next, Undo All / Keep All); per block Undo ⌥⌘⌫ / Keep ⌥⌘↩, navigate
  ⌥⌘↑/↓; accept/reject everything ⇧⌘↩ / ⇧⌘⌫. A block's comment button (or
  ⌥⌘/ on any lines) writes a note for the agent; notes gather above the
  composer and go to the chat as one message (Send). ⌘K asks the agent to
  rewrite the selection (or write code at the caret); the result shows as
  an agent change to Keep or Undo.
- **Changed files** sit above the agent composer as a sidebar-style section
  (D212): count and line totals, previous / next change, Undo All, and Keep
  All as the one prominent button; it expands into the files
  (click opens the file at its first change, hover shows per-file Undo/Keep).
  "N to review" in the status bar opens it. ⌥⌘↑/↓ walks every change,
  moving on to the next file past the last one.
- **Command palette** (⇧⌘P) lists every registered command, fuzzy search.
- **Open Quickly** (⌘P): fuzzy file finder, file-name matches first, matched
  letters highlighted; empty query lists open tabs.
- **Terminal** (⌃\` toggle, ⌃⇧\` new): bottom panel under the editor with
  a draggable top edge; tabs per shell (title from the shell), × or `exit`
  closes one, the panel hides with the last one. Login shell in the project
  folder, editor font, colors follow light/dark, Option types characters.
- **Source Control** (⌃⇧G): branch menu (switch / New Branch…), ↑↓ counts,
  pull / push (publishes a new branch); commit box (⌘↩), "Commit All" when
  nothing is staged; ✨ in the box writes the message with the last used agent
  (~8 s, click again to stop); Merge Conflicts / Staged / Changes sections with hover
  stage, unstage, discard (asks first; new files go to the Trash). Clicking a
  file opens its diff tab ("Working Tree" or "Staged": hunks with collapsed
  unchanged lines, Stage / Unstage / Discard / Open File); right-click for more.
- **Git decorations in the explorer:** changed files are colored with a letter
  (M modified, U untracked, A added, R renamed, ! conflict); folders containing
  changes take the strongest child color and a dot. Errors (hooks, rejected push) show in a dismissible banner.
- **Find in Project** (⇧⌘F): Search panel in the navigator, searches as you
  type; Aa / whole word / regex toggles; results grouped by file, click jumps
  to the line. Re-runs when files change on disk.
- **Settings:** laid out like System Settings, searchable by option; plugin
  switches apply right away (D194).
