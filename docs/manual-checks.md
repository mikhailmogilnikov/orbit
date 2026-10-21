# Manual checks

What is built, and usually covered by tests, but hasn't been looked at or
tried by hand on a Mac yet. Remove a line once it's checked; a problem it
turns up goes to an issue or, if it stays, to the roadmap's known
limitations. Debug builds have **Plugins → Debug: Simulate Agent Edit** for
inline diffs without spending agent requests.

Already checked by hand (2026-10-13, TypeScript and Python): server install
and the status-bar menu, Problems and References, navigation, completion,
code actions, rename, formatting and its corner note, the agent registry
(fixes in D66–D68). Chat look (D163) with Codex.

## Agents and chat

- Agent registry (D52): installing npx and binary agents, the first-launch
  migration of Claude Code / Codex, icons.
- Chat like Claude Code (D120): ⇧Tab reaching the field as backtab, Esc and ↑
  beside the text field's own keys, the pinned plan's height, the copy
  button's place, the jump button while streaming.
- Chat look (D163): a permission prompt, a running command's Stop, a failed call.
- Chat attribution and hints (D119): the agent icon beside the stats and the
  hover buttons, the hints grid under the greeting.
- Tool card links and permission keys (D118): the link's hover, keys reaching
  the buttons from the editor and the composer, the waiting bar.
- Tool call folding (D122) and folded reads (D116), with a real agent: line
  spacing, a running command folded away while its output streams, expanding
  while calls stream in.
- Slash commands and turn summary (D115): the command list's look and
  scrolling, Return picking vs. sending, the timer, the summary row and its Review.
- Transcript (D121): streaming while scrolled up.
- Message queue (D88): Send Now stopping a turn, the paused state.
- Notifications (D87, D130): the permission prompt for an ad hoc signed build,
  click to open the chat, the badge, Allow from a notification while Orbit is
  behind.
- Agents overview (D130): the popover from the status bar, the window coming forward.
- MCP servers (D86): each adapter accepts the list and starts the servers;
  the Settings section.
- Usage popover (D124).
- Agent pages and the Project badge (D179): per-agent mode for new chats.
- Agent terminals: the `terminal/*` (PTY) path with a real agent (Claude Code
  and Codex use display terminals); how many tabs a busy turn leaves.
- Users of changed files (D198): how many files a big turn pulls in, the
  extra load on tsserver, false matches of common module names like `types`.

## Review

- Typing by hand inside a highlighted diff block.
- Review comments (D125): the popover's place under a block and its keys, the
  note in the block's bar and the chip off blocks, the bar above the composer.
- ⌘K (D127): the popover's place above the selection, how Claude Code's plan
  mode and Codex's read-only mode answer, the time a warm agent takes.
- Rewind (D132): does the agent follow the note to disregard the rewound part?
- Restore points (D85): the hover button, the dialog, the note to the agent.
- Isolated sessions: the whole flow by hand.
- Create PR (D133) and Push N (D144) against GitHub; the sheet and badge.

## Editor

- Text editing basics (D105): keys reaching the editor before STTextView's own
  ⌥↑ / ⌃⇧↑ bindings, the caret for several carets, ⌥-click, the Go to Line
  popover's place, the bracket outline.
- Multiple carets and editing rules (D202): typing with ⌘D carets (Return,
  brackets, completion), a JSX tag rename, the placeholder boxes, squiggles
  while typing above them.
- Editor (D139–D141): ⌥-drag over wrapped lines and folds, autoscroll while
  dragging, the large-file banner, Format Selection with each formatter.
- Highlighting appearing only after a scroll or a keystroke on open (fixed in
  D14's addendum).
- Grammars (D58, D71): the first open's uncolored second, background installs
  when a folder opens, colors of Zed's queries for Swift / TS / Markdown.
- Inlay hints and embedded languages (D69, D70): label placement and the caret
  around them, colors in Markdown, Vue and HTML; the first Markdown file
  installing the inline grammar.
- Semantic tokens (D201): colors in real themes, flicker while typing, a big
  file's token load. Code lenses with a real server (rust-analyzer's Run and
  references; TypeScript's references count needs its preference on).
- Indent guides (D110): crisp 1-pt lines, placement with tabs, inline-diff
  gaps and folds, a theme's `editor.indent_guide`.
- File formats (D106): the status-bar menu, Reopen with Encoding in the Can't
  Open state, a CRLF file's inline agent review.
- Split editor (D90): the tab row's split line with the sidebar shown and
  hidden and in full screen, dragging, focus by click, two editors of one file.
- Drag and drop (D91): tab drags; dropping files on the editor (rests on
  AppKit finding the catcher above the text view although its `hitTest` is nil).
- Preview tabs (D94): a double click on a list row beside the list's own
  selection, the tab's double click beside its drag.
- Location history (D99): caret reports after a reveal, ⌃Tab's panel and ⌃ release.
- SVG preview and gutter thumbnails (D145, D146): an upscaled SVG's
  crispness, the thumbnail column beside folds and blame, the popover's place.
- Preview (D89): zoom and centering, the info capsule, the page in light and
  dark, code colors, links, relative images.
- Glass popups (D173): legibility of hover docs and completion over busy code.
- Completion (D56): popup look, keys, placement near screen edges, IME;
  placeholder tokens (D202).

## Language features

- LSP (D54): squiggles, the hover card, ⌘-click.
- Code actions, rename, formatting (D59): menu placement, the rename field, undo.
- Rename preview (D199): the sheet, ⇧↩ reaching Preview Changes, a real
  rust-analyzer module rename, TypeScript's Move to a new file.
- Formatting (D60, D61, D203): the Formatting section in Settings → Languages,
  the corner note after ⌃⇧I, failure alerts, the toast's arrows, format on
  type while typing fast.
- Language installs (D57): the Settings page and the status-bar button.
- Companions (D64): status-bar names, merged completion with Tailwind's long
  class lists, the install banner.
- Vue (D74): two install offers in a row, "Vue templates" in the status bar.
- Hierarchy panel (D200): row indentation, the segmented switch, the chevron
  turning into a spinner while a level loads.
- Navigation (D62) for Rust (needs cargo), and the other servers by hand:
  Rust, Go, Tailwind / ESLint companions.
- settings.json schema (D182): completion in the editor.

## Explorer, search and windows

- Explorer file operations (D93): the name field's focus and selection, Return /
  ⌘⌫ reaching the list, the header's hover buttons, ⌘Z routing. Multiple
  selection (D111): ⌘- / ⇧-click with our own row highlight, the menu acting
  on all rows.
- Explorer moves (D92), folder clicks (D96): a click on an already selected folder.
- Explorer context menu (D95): ⌘X ⌘C ⌘V through the Edit menu, ⌃↩ / ⌥⌘R / ⌥⌘C,
  app icons in Open With; Compare and Find in Folder (D110).
- Keyboard navigation (D98): the list taking focus on ⇧⌘E, Space / Escape, arrows
  with the key filter.
- Folder watching (D126): latency in the tree, CPU while a terminal build runs.
- Replace in files (D111): the panel's Undo.
- Windows (D101, D102): windows coming back on launch, the close stand-in in
  front of SwiftUI's window delegate, menus following the main window, full
  screen with two windows, Close Folder, folders from Finder / the Dock.

## Git

- Git (D134–D136): conflict blocks and their bar, the graph's lines between
  sidebar rows and its colors in light and dark.
- Blame after the line (D187): position, color, the hover card.
- File and line history, compare (D188, D189).
- Revision tab (D204): the author column, run separators, horizontal scrolling.
- D147–D154: the Fix button's hover, ⌘-click on paths in the terminal, the color
  panel editing a literal while dragging, the permalink against GitHub, pasting
  a screenshot, the power assertion (`pmset -g assertions`), the stash rows.
- Source Control look (D171): light mode, conflicts.

## Terminal, tasks and browser

- Terminal keys (D155): in zsh, Claude Code and Codex; ⇧↩ in each agent's
  prompt; ⌘K while a full-screen program runs.
- ⌃C (D217): stops a dev server in the Russian layout, and in Claude Code /
  Codex run in the terminal (still their own ⌃C); ⇧↩ in the agent chat's composer;
  ⌘⌫ repeated in the editor (with an inline diff on screen too).
- Terminal find (D110): ⌘F reaching SwiftTerm's find bar, its look beside Orbit's glass.
- Tasks (D128, D138): typing into a shell that's still starting, ⌃C then
  restart of a dev server, ⌘R from the terminal and the chat, the running-task
  status item.
- Terminal list (D167): tasks and agent terminals in the list.
- `orbit` command and browser (D142, D143): the password prompt for
  /usr/local/bin, a file opening a new window and then its tab, the browser
  toolbar, retry while a dev server starts, Inspect Element, tabs restored at launch.

## Shell, settings and looks

- Settings (D158): a narrow window, VoiceOver, sidebar selection while the window is key.
- Settings search (D177): sidebar results, scroll to the row, the highlight.
- Settings → Terminal and Files (D178): shell, cursor, Option as Meta, scrollback
  in a live terminal.
- Font family, default indentation, auto save (D180); text sizes (D181), notably
  the interface at 15 pt in tight rows; line height, ligatures, bracket switch (D188).
- Project options (D108, D183): the "Set by" notes and disabled toggles, options
  changing on save, the right-click on the agents' disabled pickers.
- Shortcuts (D107, D175): the recorder taking keys before Settings' own Esc,
  menus updating at once, a reassigned key in a second window, recording from
  the popover.
- Plugins and Checkpoints panes (D184, D185): Restart Now, a real prune.
- Live plugin switches (D194): panels going away, an open editor rebuilt when
  Source Control or Languages toggles, the confirmation listing agents and
  tasks, Git Lens greyed under Source Control.
- Extensions page (D192) and packages (D195): the segmented filter, rows with
  a page and a switch, Show All, "Get More Agents"; snippets in completion and
  their Tab stops, Insert Snippet…, a package's page, New Extension… / New
  Snippet File…, the catalog's Snippets tab.
- Extensions catalog: listing, download and unpack, try-on and the bar over
  the editor against the live Zed API; the theme selector (D49) and thumbnails.
- Automatic updates and server switches (D186): a real daily update.
- Releases (D129): an update from one release to the next through Sparkle.
- Theme accent (D97): prominent glass buttons in the System theme; sheets and
  hover panels outside the window's `.tint`.
- Theme tokens (D157) and type scale (D117): hovers, row heights, popover and
  composer sizes, chevrons, bar text sizes.
- Tabs (D168): the hover close button, unsaved dot, chat tabs.
- Status bar and bottom area (D63, D170): error / warning counts with real
  problems, terminal tabs in the header, badge colors.
- Issue navigator (D172): References.
- Quieter details (D174): a code block with a language, the hover Copy.
- Menu bar layout (D176): dividers and submenus on screen.
- Sheets (D162): delete, discard, unsaved changes and install-failure alerts.
- Palette (D161): the theme selector's rows, plugins' picks with long titles.
- Welcome screen (D160): Return on a selected project, the context menu.
- Empty states and animations (D159): digit rolls, the waiting hand's wiggle.
- Side-by-side diffs (D111): row heights with long wrapped lines, the header toggle.

## Website

- The site (D216) in Safari, light and dark, on a Mac and an iPhone: the
  glass nav and theme switch, the demo window's turn and
  its keys (⌥⌘↩ / ⌥⌘⌫ shouldn't reach Safari's own shortcuts), the FAQ's
  opening animation. Checked only in the Claude browser pane (Chromium).
- Deploying it (Vercel, root `site/`): `../docs` and `../Packages` must be
  readable during the build.
- Once deployed: a link to the site pasted in Telegram / X / Slack shows the
  large picture (`og.jpg`); the home-screen icon on an iPhone
  (`apple-touch-icon.png`); `sitemap-index.xml` submitted in Search Console.
- First launch of a downloaded release on macOS 26: the steps in the FAQ and
  README (Open Anyway in Privacy & Security) are the ones macOS asks for.

