# Writing Orbit extensions

An extension is a folder. Orbit loads every folder in `~/.orbit/extensions/`
at launch and again whenever a file in there changes — save a theme file and
the editor repaints. Settings → Extensions → Packages lists what loaded, what
each one brings and any errors; **New Extension…** there makes a folder to
start from.

An extension can bring **color themes**, **file icon themes**, **snippets**,
**agents**, **language servers** and **tasks** — any of them, together.
Themes, icons and snippets use [Zed's](https://zed.dev/docs/extensions/themes)
formats (snippets are VS Code's), so Zed's theme, icon and snippet
extensions work in Orbit unchanged.

## Layout

```
my-extension/
  extension.json          # or Zed's extension.toml
  themes/*.json           # color themes (all files are loaded)
  icon_themes/*.json      # icon themes
  icons/…                 # SVG/PNG files icon themes point to
  snippets/*.json         # snippets: <language>.json, or snippets.json for all
  agents/*.json           # ACP agents
  language_servers.json   # language servers
  tasks.json              # tasks for Run Task…
```

`extension.json`:

```json
{
  "id": "my-theme",
  "name": "My Theme",
  "version": "1.0.0",
  "description": "One line about it.",
  "authors": ["You <you@example.com>"],
  "repository": "https://github.com/you/my-theme"
}
```

`id` must be unique (lowercase, dashes). Optional `"themes"` /
`"iconThemes"` arrays list files explicitly instead of scanning the folders.

## Color themes

A file holds a theme family; each theme says whether it is light or dark.
Users pick a light and a dark theme separately, so ship both when you can.

```json
{
  "name": "My Theme",
  "author": "You",
  "themes": [
    {
      "name": "My Theme Dark",
      "appearance": "dark",
      "style": {
        "editor.background": "#1e1f22",
        "editor.foreground": "#d6d6dd",
        "editor.active_line.background": "#2a2c30",
        "editor.line_number": "#5c6066",
        "editor.active_line_number": "#d6d6dd",
        "players": [{ "cursor": "#7aa2f7", "selection": "#7aa2f740" }],
        "version_control.added": "#9ece6a",
        "version_control.modified": "#e0af68",
        "version_control.deleted": "#f7768e",
        "terminal.background": "#1e1f22",
        "terminal.ansi.red": "#f7768e",
        "syntax": {
          "keyword": { "color": "#bb9af7", "font_weight": 600 },
          "comment": { "color": "#565f89", "font_style": "italic" },
          "string": { "color": "#9ece6a" }
        }
      }
    }
  ]
}
```

Colors are `#rgb`, `#rrggbb` or `#rrggbbaa`. Every key is optional; what you
leave out uses the system color. Orbit reads:

| Key | Used for |
| --- | --- |
| `editor.background` | editor and gutter; also lies under the window, tinting the glass sidebar, inspector and toolbar |
| `editor.foreground` | editor text (and terminal, unless `terminal.*` is set) |
| `editor.active_line.background` | current line highlight |
| `editor.line_number`, `editor.active_line_number` | gutter numbers |
| `players[0].cursor`, `players[0].selection` | caret, terminal selection |
| `version_control.added` / `modified` / `deleted` / `renamed` / `conflict` | gutter markers, file status colors, diff counters (`created`, `modified`, `deleted`, `renamed`, `conflict` also work) |
| `terminal.background`, `terminal.foreground` | integrated terminal |
| `terminal.ansi.<color>`, `terminal.ansi.bright_<color>` | the 16 ANSI colors (`black red green yellow blue magenta cyan white`) |
| `syntax.<name>` | `color`, `font_weight` (100–900), `font_style` (`italic`) |

Other Zed keys are ignored: the sidebar and Settings stay native macOS glass
and only follow light/dark.

**Syntax names.** Use Zed's names: `keyword`, `function`, `function.method`,
`type`, `constructor`, `property`, `variable`, `variable.parameter`,
`variable.special`, `constant`, `boolean`, `number`, `string`,
`string.escape`, `string.regex`, `comment`, `operator`, `punctuation`,
`punctuation.bracket`, `punctuation.delimiter`, `attribute`, `tag`, `title`,
`emphasis`, `link_uri`. A more specific name falls back to a shorter one
(`keyword.return` → `keyword`), so a handful of keys colors most code.

## Icon themes

```json
{
  "name": "My Icons",
  "themes": [
    {
      "name": "My Icons",
      "appearance": "dark",
      "directory_icons": { "collapsed": "./icons/folder.svg", "expanded": "./icons/folder-open.svg" },
      "named_directory_icons": { "src": { "collapsed": "./icons/src.svg", "expanded": "./icons/src-open.svg" } },
      "file_stems": { "Makefile": "make", "Dockerfile": "docker" },
      "file_suffixes": { "ts": "typescript", "d.ts": "typescript-def", "json": "json" },
      "file_icons": {
        "typescript": { "path": "./icons/typescript.svg" },
        "default": { "path": "./icons/file.svg" }
      }
    }
  ]
}
```

Users pick icons for light and dark mode separately; `appearance` only
decides which picker lists the theme first. Paths are relative to the extension folder. `file_stems` match whole file
names (or the part before the first dot), `file_suffixes` the longest
matching extension (`index.d.ts` tries `d.ts`, then `ts`), and `default` is
used for everything else. Icons are drawn in their own colors at about 15 pt;
SVG works best.

## Snippets

VS Code's format: an object of snippets by name. `body` is a string or a list
of lines, with `$1`, `${1:default}`, `${1|one,two|}` for the places Tab goes
through and `$0` where it ends. Comments and trailing commas are fine.

```json
{
  "Test": {
    "prefix": ["test", "it"],
    "body": ["test(\"${1:does something}\", () => {", "\t$0", "});"],
    "description": "A test case"
  }
}
```

A file named after a language (`swift.json`, `typescript.json`, `tsx.json`;
VS Code's ids like `typescriptreact` work too) is for that language;
`snippets.json`, `global.json` or a `.code-snippets` file is for every
language unless a snippet has `"scope": "javascript,typescript"`. A tab at the
start of a line is one level of the file's indentation, and lines after the
first keep the indentation of where the snippet goes.

Snippets show among the completions as you type their prefix, and in
Editor → Insert Snippet…. Besides extensions, they come from
`~/.orbit/snippets/` (yours) and `.orbit/snippets/` in a project (shared with
everyone working on it) — the project's first.

## Agents

`agents/<id>.json` is the manifest Orbit keeps for an agent in
`~/.orbit/agents` — a program speaking the
[Agent Client Protocol](https://agentclientprotocol.com):

```json
{ "id": "my-agent", "name": "My Agent", "command": { "executable": "my-agent", "arguments": ["--acp"], "environment": {} } }
```

`executable` is looked up on the PATH, or is relative to the extension folder
when it starts with `./` or `bin/`. An agent of the same id in
`~/.orbit/agents` wins. It's listed under Agents, "From the … extension", and
goes when the extension is uninstalled.

## Language servers

```json
{
  "servers": [
    {
      "id": "kotlin-lsp",
      "name": "Kotlin",
      "fileTypes": { "kt": "kotlin", "kts": "kotlin" },
      "fileNames": { "build.gradle.kts": "kotlin" },
      "roots": [["settings.gradle.kts", "settings.gradle"], ["build.gradle.kts"]],
      "command": "kotlin-lsp",
      "arguments": ["--stdio"],
      "install": { "mason": "kotlin-lsp", "needs": "Java" },
      "settings": {},
      "initializationOptions": {}
    }
  ]
}
```

`fileTypes` maps file extensions to the LSP language id. `roots` are marker
files in groups: the first group found on the way up from a file decides
where the server runs. `command` is found on the PATH (`./…` is in the
extension); with `install`, Orbit installs it from the
[Mason registry](https://mason-registry.dev) itself, as it does its own. An
extension's server comes before Orbit's own for its file types: installing it
is asking for it. `.orbit/settings.json`'s `"languageServers"` still win.

## Tasks

```json
{ "tasks": [ { "name": "deploy", "command": "fly deploy", "when": "fly.toml", "detail": "Fly.io" } ] }
```

Run Task… (⌃⌘R) offers a task in projects with one of the `when` files at
their top (a name, or a list of names); without `when`, in every project.
Tasks run in a terminal tab at the project's root, after the project's own.

## What runs

Agents, language servers and tasks run programs on the Mac; themes, icons and
snippets don't. A package's page in Settings → Extensions lists every program
it can start.

## Examples

`examples/extensions/` in the Orbit repository has full themes (`github-theme`,
`nord`) and a small icon theme (`simple-icons`). Copy one into `~/.orbit/extensions/` to
try it.

## Publishing

Orbit's registry, [orbit-extensions](https://github.com/mikhailmogilnikov/orbit-extensions),
lists packages of every kind: Settings → Extensions → Get More Packages….
To publish, put the extension in a public repository, tag its version and
open a pull request there with its entry — `scripts/registry.py add <archive
URL>` writes it (the hash, what it provides). Its README has the details.
A package with agents, language servers or tasks shows every program it
starts and asks before it's installed, and again when an update changes them.

Themes, icon themes and snippets published for Zed (see Zed's docs on
publishing extensions) show up in Orbit too, through Settings → Extensions →
Browse Themes, Icons & Snippets — themes ready to try on and install, and in
the theme selector (⌃⌘T). Name a family's light and dark themes alike
("Name Dark" / "Name Light"): picking one also picks its partner for the
other mode. From Zed's catalog Orbit keeps only the themes, icon themes,
icons and snippets.
