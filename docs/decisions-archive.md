# Decision log — archive

Entries superseded as a whole, kept for their reasons and what was tried.
Each names its successor; numbers are the same as in [decisions.md](decisions.md).

### D11. Built-in agent adapters via unpinned npx
> **Superseded by D52.**

`npx -y @agentclientprotocol/{claude-agent,codex}-acp` — auto-updates, no
bundling. Cost: ~1–2 s startup. Revisit (cache/bundle) if startup annoys.

### D17. Keep the system window toolbar as is
> **Superseded by D42.**

Tried moving editor tabs into the toolbar (Safari/Zed style) and hiding its
items when no file is open. Toolbar items can't stretch, so it needed a
hand-computed strip width per sidebar/inspector state, and hiding the toolbar
also removes the traffic lights. Too fragile for little gain: the toolbar stays
system-managed (title + file path, buttons always visible), tabs are a row
below it. Don't fight AppKit chrome. **Superseded by D42.**

### D39. Themed middle, native edges (like Xcode)
> **Superseded by D40.**

Amends D38. With only the editor themed, a dark theme with its own background
(GitHub Dark `#0D1117`) sat in grey chrome like a window inside a window. Now
the theme's `editor.background` also paints the middle of the window — the
tab bar, the toolbar area above the editor, the bottom panel and the
inspector (agent chat) — through `View.editorBackground(fallback:)`. The
sidebar stays native glass and frames the content, as in Xcode and Nova;
Settings stay fully native. Themes without a background (the built-in Orbit
ones) look exactly as before. Zed's per-surface keys (`tab_bar.background`,
`panel.background`, …) are still ignored: one surface color keeps the middle
calm and works with any Zed theme.
**Superseded by D40.**

### D44. Cursor, Grok Build and OpenCode built in
> **Superseded by D52.**

Their own CLIs speak ACP over stdio, no adapter needed: `cursor-agent acp`,
`grok agent stdio`, `opencode acp` (all report models through
`configOptions`). Unlike the npx-launched Claude/Codex adapters they must be
installed by the user, so agents whose executable isn't on the login-shell
PATH are hidden from the picker, menus and the default-agent setting
(Settings lists them as "Not installed") and their `session/list` isn't asked.
Logos of Cursor, Grok and OpenCode come from lobe-icons (MIT), drawn even-odd.
A model option with a single choice is kept (Grok Build offers one model), so
the composer button still names the model.
