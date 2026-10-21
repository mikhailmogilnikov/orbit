#!/bin/zsh
# Measures Orbit, Zed, VS Code and Cursor on this Mac; see the site's /numbers page.
# Opens and quits each app a few times: leave the Mac alone while it runs (~20 minutes).
set -e
cd "${0:A:h}"
swiftc -O bench.swift -o /tmp/orbit-bench
[[ -d demo/.git ]] || (cd demo && git init -q && git add -A && git -c user.name=demo -c user.email=demo@example.com commit -qm init)
DEMO="$PWD/demo"
# VS Code and Cursor keep a socket in their profile; macOS limits its path to 104 characters
P=/tmp/orbit-bench-profiles
rm -rf $P && mkdir -p $P/{zed,code,code-ext,cursor,cursor-ext}
ORBIT=${ORBIT:-/Applications/Orbit.app}

# Orbit opens the folders it had open; point it at the demo for the run, then put them back
defaults export dev.orbit.app $P/orbit-defaults.plist
trap 'defaults import dev.orbit.app $P/orbit-defaults.plist' EXIT
defaults write dev.orbit.app orbit.openFolders -array "$DEMO"

BENCH_EXCLUDE='agentclientprotocol|acp@|-acp( |$)' /tmp/orbit-bench Orbit "$ORBIT" 3 15 30
/tmp/orbit-bench Orbit+agent "$ORBIT" 3 15 30
/tmp/orbit-bench Zed /Applications/Zed.app 3 15 30 -- --user-data-dir $P/zed "$DEMO"
/tmp/orbit-bench "VS Code" "/Applications/Visual Studio Code.app" 3 15 30 -- --user-data-dir $P/code --extensions-dir $P/code-ext "$DEMO"
/tmp/orbit-bench Cursor /Applications/Cursor.app 3 15 30 -- --user-data-dir $P/cursor --extensions-dir $P/cursor-ext "$DEMO"
