#!/usr/bin/env python3
# The stress run's gallery (D248): every state the copies shot (each panel,
# Settings pane and editor as it first showed), one row each, every copy's
# window side by side with its mode: a look at the whole app in a minute.
#   stress-gallery.py <run folder> <mode name>...
import glob, html, os, sys

out, names = sys.argv[1], sys.argv[2:]
shots = {}
for path in sorted(glob.glob(f"{out}/*/shots/*.jpg")):
    copy = os.path.relpath(path, out).split(os.sep)[0]
    shots.setdefault(os.path.basename(path)[:-4], []).append((copy, os.path.relpath(path, out)))
if not shots:
    sys.exit(1)


def mode(copy):
    try:
        return names[int(open(f"{out}/{copy}/mode.txt").read())]
    except (OSError, ValueError, IndexError):
        return copy


rows = "".join(
    f'<section><h2>{html.escape(key.replace("_", " "))}</h2><div class="row">'
    + "".join(f'<figure><a href="{src}"><img loading="lazy" src="{src}"></a><figcaption>{html.escape(mode(copy))}</figcaption></figure>'
              for copy, src in items)
    + "</div></section>"
    for key, items in sorted(shots.items()))
style = """body{font:13px -apple-system,sans-serif;margin:16px;background:#f5f5f7;color:#1d1d1f}
@media(prefers-color-scheme:dark){body{background:#1d1d1f;color:#f5f5f7}}
h2{font-size:14px;margin:24px 0 8px}.row{display:flex;gap:12px;overflow-x:auto}figure{margin:0}
img{height:260px;border-radius:8px;box-shadow:0 1px 4px #0004}figcaption{opacity:.6;margin-top:4px}"""
with open(f"{out}/gallery.html", "w") as file:
    file.write(f'<!doctype html><meta charset="utf-8"><title>Stress run gallery</title><style>{style}</style>'
               f'<h1>Stress run gallery</h1><p>{len(shots)} states, each copy\'s window as it showed them.</p>{rows}')
print(f"gallery: {out}/gallery.html")
