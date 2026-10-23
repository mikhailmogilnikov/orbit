#!/bin/bash
# Tries to break a debug build of Orbit (D243): a project of awkward files
# (empty, one line, 48 lines, huge, one endless line, emoji and RTL, CRLF,
# binary, an image, symlinks), then window sizes, full screen, panels, splits,
# typing, line edits, agent edits and their review, wrapping and appearance:
# first each once, then in random order. After every step Orbit has to be
# alive, answer on its main thread and go quiet again; the first step that
# breaks it stops the run with its log, a screenshot and the crash report.
#   make stress                        the fixed pass and 150 random steps
#   STEPS=500 SEED=7 make stress       more steps, or a failed run's order again
#   APP=<Orbit.app> scripts/stress.sh  another debug build (DebugRemote is debug-only)
#   FOREGROUND=1 make stress           in front, with full screen (it takes over the Mac)
# It runs a copy of the build beside Orbit itself, with settings of its own,
# in the background: never activated, its window behind yours, so the Mac stays usable.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/orbit-env.sh

APP=${APP:-.build/xcode/Build/Products/Debug/Orbit.app}
STEPS=${STEPS:-150}
SEED=${SEED:-$RANDOM}
RESULTS=.build/stress
# A copy with its own bundle id: settings of its own, run beside Orbit itself.
export ORBIT_DOMAIN=dev.orbit.app.stress
RUN_APP=$RESULTS/OrbitStress.app
INBOX=/tmp/orbit-remote-$ORBIT_DOMAIN
OUTBOX=$INBOX-out.txt
LOG=$RESULTS/stress-$SEED.log
# A step may keep Orbit busy this long (a huge file highlighting) before it counts as a loop.
QUIET_WITHIN=${QUIET_WITHIN:-20}
FOREGROUND=${FOREGROUND:-}

[ -x "$APP/Contents/MacOS/Orbit" ] || { echo "No debug build at $APP: make build" >&2; exit 1; }
mkdir -p "$RESULTS"
orbit_side_copy "$APP" "$RUN_APP" "$ORBIT_DOMAIN" "$([ -n "$FOREGROUND" ] || echo background)"
: > "$LOG"
say() { echo "$*" | tee -a "$LOG"; }

orbit_scratch
P=$ORBIT_SCRATCH/project
FILES=()

make_project() {
    mkdir -p "$P/src/deep/a/b/c" "$P/docs" "$P/.orbit"
    : > "$P/empty.txt"
    printf 'no newline at the end' > "$P/one-line.txt"
    for i in $(seq 1 48); do echo "export const item$i = { id: $i, title: 'Item $i' }"; done > "$P/src/short.tsx"
    python3 -I - "$P" <<'EOF'
import os, random, struct, sys, zlib
p = sys.argv[1]
def write(name, text, mode="w", **kw):
    with open(os.path.join(p, name), mode, **kw) as f: f.write(text)
write("src/long.swift", "".join(f"func f{i}(_ x: Int) -> Int {{ x * {i} }} // {'·' * (i % 90)}\n" for i in range(6000)))
write("src/minified.js", "var a=" + ",".join(f"b{i}={i}" for i in range(30000)) + ";")
write("docs/unicode.md", "# Ünïcödé\n\n" + "\n".join([
    "emoji: 👩‍👩‍👧‍👦 🏳️‍🌈 🇯🇵 ✋🏽 " * 8,
    "RTL: שלום עולם مرحبا بالعالم " * 6,
    "combining: é ä Z̵̶̷ " * 10,
    "CJK: 漢字かなカナ한국어 " * 12,
    "zero width: a​b‌c‍d﻿e",
    "\ttab\tseparated\tcolumns",
]) + "\n")
write("crlf.txt", "".join(f"line {i}\r\n" for i in range(300)), newline="")
write("blank.txt", "\n" * 2000)
write("tabs.go", "package main\n\nfunc main() {\n" + "".join("\t" * (i % 12) + f"x{i} := {i}\n" for i in range(400)) + "}\n")
write("huge.log", "".join(f"2026-10-23 12:00:{i % 60:02d} INFO request {i} took {i % 977} ms path=/api/v1/items/{i}\n" for i in range(120000)))
random.seed(1)
write("binary.bin", bytes(random.getrandbits(8) for _ in range(65536)), "wb")
def png(w, h):
    raw = b"".join(b"\x00" + bytes((x * 7 + y) % 256 for x in range(w * 3)) for y in range(h))
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
write("docs/image.png", png(64, 48), "wb")
write("src/deep/a/b/c/name with spaces & ünïcode.txt", "deep\n")
write(".orbit/settings.json", '{ "editor": { "wordWrap": false } }\n')
EOF
    ln -s src/short.tsx "$P/link-to-short.tsx"
    ln -s src/deep "$P/link-to-deep"
    ln -s missing.txt "$P/broken-link.txt"
    git -C "$P" init -q && git -C "$P" add -A && git -C "$P" -c user.name=stress -c user.email=stress@orbit.invalid commit -qm fixture
    # Changes against git, for the gutter and Source Control.
    sed -i '' 's/Item 3/Item three/; 10d' "$P/src/short.tsx"
    FILES=(empty.txt one-line.txt src/short.tsx src/long.swift src/minified.js docs/unicode.md crlf.txt blank.txt
           tabs.go huge.log binary.bin docs/image.png "src/deep/a/b/c/name with spaces & ünïcode.txt" link-to-short.tsx broken-link.txt)
}

PID=
STEP=0
CRASHES=0

fail() {
    say "FAILED at step $STEP: $*"
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        # Not `send`: it fails again when Orbit stopped reading. In the
        # background a window-server shot would show the windows over Orbit's.
        printf '%s %s\n' "$([ -n "$FOREGROUND" ] && echo shot || echo viewshot)" "$PWD/$RESULTS/stress-$SEED.png" > "$INBOX"
        sleep 1
        sample "$PID" 3 -file "$RESULTS/stress-$SEED-sample.txt" >/dev/null 2>&1 || true
        kill "$PID" 2>/dev/null || true
    fi
    sleep 3
    if [ "$(orbit_crash_reports)" != "$CRASHES" ]; then say "crash report: $(orbit_newest_crash_report)"; fi
    say "log: $LOG; run this order again with SEED=$SEED STEPS=$STEPS make stress"
    exit 1
}

# DebugRemote takes a file of lines and deletes it: the next waits for that.
send() {
    local i
    for i in $(seq 1 200); do [ -e "$INBOX" ] || break; sleep 0.05; done
    [ ! -e "$INBOX" ] || fail "Orbit stopped taking commands for 10 s (main thread stuck)"
    printf '%s\n' "$1" > "$INBOX.next" && mv "$INBOX.next" "$INBOX"
}

ping_app() {
    local i answer
    # What DebugRemote said about the step (a key it couldn't send): into the log.
    answer=$(cat "$OUTBOX" 2>/dev/null || true)
    [ -z "$answer" ] || [ "$answer" = pong ] || echo "   remote: $answer" >> "$LOG"
    rm -f "$OUTBOX"
    send ping
    for i in $(seq 1 200); do
        [ "$(cat "$OUTBOX" 2>/dev/null)" = pong ] && return 0
        kill -0 "$PID" 2>/dev/null || return 1
        sleep 0.05
    done
    return 1
}

# Seconds of CPU the process has used.
cpu_seconds() {
    ps -o time= -p "$PID" | awk -F: '{ s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; print s }'
}

check() {
    local i cpu=0 before after
    kill -0 "$PID" 2>/dev/null || fail "Orbit quit"
    ping_app || { kill -0 "$PID" 2>/dev/null && fail "no answer from the main thread for 10 s" || fail "Orbit quit"; }
    # A layout loop spins at 100% until AppKit gives up: Orbit has to go quiet,
    # under 40% of a core over a third of a second.
    for i in $(seq 1 $((QUIET_WITHIN * 3))); do
        before=$(cpu_seconds)
        sleep 0.3
        after=$(cpu_seconds)
        [ -n "$after" ] || fail "Orbit quit"
        cpu=$(awk -v a="$before" -v b="$after" 'BEGIN { printf "%d", (b - a) / 0.3 * 100 }')
        [ "$cpu" -lt 40 ] && break
    done
    [ "$cpu" -lt 40 ] || fail "still busy (${cpu}% CPU) $QUIET_WITHIN s after the step"
    [ "$(orbit_crash_reports)" = "$CRASHES" ] || fail "a new crash report"
}

# One step: what it does goes to the log first, so a crash names it.
step() {
    STEP=$((STEP + 1))
    echo "$STEP: $*" >> "$LOG"
    case "$1" in
        open) send "open $P/$2" ;;
        wrap) printf '{ "editor": { "wordWrap": %s } }\n' "$2" > "$P/.orbit/settings.json" ;;
        fullscreen) send fullscreen; sleep 2 ;;
        *) send "$*" ;;
    esac
    # Lets the step's layout start before the ping is answered.
    sleep 0.1
    check
}

edits=(
    "run shell.focusEditor" "key cmd+down" "key cmd+up" "type Hello, stress ☃ 👩‍👩‍👧 שלום" "key return" "key tab"
    "key delete" "key cmd+a" "key cmd+z" "key cmd+shift+z" "run editor.moveLineDown" "run editor.moveLineUp"
    "run editor.copyLineDown" "run editor.deleteLine" "run editor.toggleComment" "run editor.addCaretBelow"
    "run editor.selectAllOccurrences" "run editor.indentLines" "run editor.outdentLines" "run editor.expandSelection"
    "key esc"
)
layout=(
    "size 960 600" "size 1100 700" "size 1280 800" "size 2400 1600" "size 973 611"
    "run shell.toggleSidebar" "run shell.toggleAgents" "run terminal.toggle" "run shell.splitEditor"
    "run shell.joinEditors" "run shell.moveTabToOtherSide" "run editor.zoomIn" "run editor.zoomOut" "run editor.zoomReset"
    "appearance dark" "appearance light" "appearance system" "wrap true" "wrap false"
)
tabs=("run shell.nextTab" "run shell.previousTab" "run editor.closeTab" "run shell.reopenClosedTab" "run shell.goBack")
agent=("run debug.simulateAgentEdit" "run editor.nextChange" "run review.acceptAll" "run review.rejectAll" "run editor.undoChange")

make_project
CRASHES=$(orbit_crash_reports)
# Full screen takes a Space of its own and switches to it: only in front.
[ -z "$FOREGROUND" ] || layout+=(fullscreen)
background=$([ -n "$FOREGROUND" ] && echo false || echo true)
ORBIT_EXTRA_PREFS="{\"orbit.debugRemote\": true, \"orbit.debugRemoteBackground\": $background}" \
    orbit_use_prefs "$P" src/short.tsx src/long.swift src/short.tsx
say "Stress run on $(sw_vers -productVersion), seed $SEED, $STEPS random steps$([ -n "$FOREGROUND" ] && echo ", in front"); project $P"
rm -f "$INBOX" "$OUTBOX"
# -g: launched without coming to the front.
open -g -n --stdout "$PWD/$LOG.app" --stderr "$PWD/$LOG.app" "$RUN_APP"
for _ in $(seq 1 50); do PID=$(pgrep -nf "$RUN_APP/Contents/MacOS/Orbit" || true); [ -z "$PID" ] || break; sleep 0.1; done
[ -n "$PID" ] || fail "Orbit didn't start"
for _ in $(seq 1 6); do ping_app && break; kill -0 "$PID" 2>/dev/null || fail "Orbit quit while launching"; done
check
say "launched; the fixed pass"

for file in "${FILES[@]}"; do step open "$file"; step key cmd+down; step key cmd+up; done
for action in "${layout[@]}"; do step $action; done
if [ -n "$FOREGROUND" ]; then
    # The layout pass ended in full screen: the same files there, then back.
    for file in src/short.tsx src/minified.js docs/unicode.md; do step open "$file"; done
    step fullscreen
fi
# A narrow window with wrapping.
step wrap true
step size 960 600
for file in src/minified.js docs/unicode.md src/long.swift blank.txt; do step open "$file"; step key cmd+down; done
step wrap false
for file in src/short.tsx src/long.swift empty.txt; do
    step open "$file"
    for action in "${edits[@]}"; do step $action; done
done
for file in src/short.tsx src/long.swift; do
    step open "$file"
    for action in "${agent[@]}" "${agent[@]}"; do step $action; done
done
for action in "${tabs[@]}"; do step $action; done
say "fixed pass: $STEP steps; now $STEPS random ones"

RANDOM=$SEED
all=("${edits[@]}" "${layout[@]}" "${tabs[@]}" "${agent[@]}")
for ((i = 0; i < STEPS; i++)); do
    if [ $((RANDOM % 4)) = 0 ]; then
        step open "${FILES[$((RANDOM % ${#FILES[@]}))]}"
    else
        step ${all[$((RANDOM % ${#all[@]}))]}
    fi
done

kill "$PID"
wait "$PID" 2>/dev/null || true
say "Passed: $STEP steps (seed $SEED)"
