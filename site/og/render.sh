#!/bin/sh
# Renders public/og.jpg (the link preview, 1200×630 at 2×) from card.html.
# Needs Google Chrome and ImageMagick.
set -e
cd "$(dirname "$0")"
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu --hide-scrollbars \
  --allow-file-access-from-files --force-device-scale-factor=2 --window-size=1200,630 \
  --screenshot="$PWD/card.png" "file://$PWD/card.html" 2>/dev/null
magick card.png -strip -quality 90 ../public/og.jpg
rm card.png
