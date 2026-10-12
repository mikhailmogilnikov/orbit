# Writing Orbit extensions

An extension is a folder. Orbit loads every folder in `~/.orbit/extensions/`
at launch and again whenever a file in there changes — save a theme file and
the editor repaints. Settings → Extensions lists what loaded and any errors.

Today extensions contribute **color themes** and **file icon themes**. Both
use [Zed's](https://zed.dev/docs/extensions/themes) file formats, so a Zed
theme or icon-theme extension works in Orbit unchanged.

## Layout

```
my-theme/
  extension.json        # or Zed's extension.toml
  themes/*.json         # color themes (all files are loaded)
  icon_themes/*.json    # icon themes
  icons/…               # SVG/PNG files icon themes point to
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

## Examples

`examples/extensions/` in the Orbit repository has full themes (`github-theme`,
`nord`) and a small icon theme (`simple-icons`). Copy one into `~/.orbit/extensions/` to
try it.

## Publishing

Settings → Extensions → Catalog lists Zed's extension catalog, so a theme or
icon theme published for Zed (see Zed's docs on publishing extensions) shows
up in Orbit too, ready to try on and install. Orbit keeps only the themes,
icon themes and icons from it.
