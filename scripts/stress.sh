#!/bin/bash
# Tries to break a debug build of Orbit (D243, D244). Orbit runs it itself
# (App/StressRunner.swift): it writes a project from every plugin's files,
# goes through every command, panel, Settings pane, plugin switch and plugin
# step once, plays the regressions, then takes random steps. After each the
# main thread has to go idle and every check has to hold, and whatever no
# step reached and nothing exempts fails the run. This script starts it and
# reports: the log, coverage, a sample of a hang, the crash report.
#   make stress                        the fixed part and 150 random steps
#   STEPS=500 SEED=7 make stress       more steps, or a failed run's order again
#   STEPS=0 make stress                the fixed part and the coverage check only
#   FOREGROUND=1 make stress           in front, with full screen (it takes over the Mac)
#   REPLAY=<log.txt> make stress       a failed run's steps again, in its order
#   APP=<Orbit.app> scripts/stress.sh  another debug build
# It runs a copy of the build with its own bundle id and settings, in the
# background: never activated, its window behind yours, so the Mac stays usable.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/orbit-env.sh

APP=${APP:-.build/xcode/Build/Products/Debug/Orbit.app}
STEPS=${STEPS:-150}
SEED=${SEED:-$RANDOM}
FOREGROUND=${FOREGROUND:-}
export ORBIT_DOMAIN=dev.orbit.app.stress
RESULTS=$PWD/.build/stress
OUT=$RESULTS/$SEED
RUN_APP=$RESULTS/OrbitStress.app

[ -x "$APP/Contents/MacOS/Orbit" ] || { echo "No debug build at $APP: make build" >&2; exit 1; }
rm -rf "$OUT" && mkdir -p "$OUT"
orbit_side_copy "$APP" "$RUN_APP" "$ORBIT_DOMAIN" "$([ -n "$FOREGROUND" ] || echo background)"
orbit_scratch
background=$([ -n "$FOREGROUND" ] && echo false || echo true)
REPLAY=${REPLAY:-}
[ -z "$REPLAY" ] || { cp "$REPLAY" "$ORBIT_SCRATCH/replay.txt"; REPLAY=$ORBIT_SCRATCH/replay.txt; }
plan=$(python3 -I -c 'import json, sys; seed, steps, project, out, background, replay = sys.argv[1:]
print(json.dumps({"seed": int(seed), "steps": int(steps), "project": project, "output": out, "background": background == "true", **({"replay": replay} if replay else {})}))' \
    "$SEED" "$STEPS" "$ORBIT_SCRATCH/project" "$OUT" "$background" "$REPLAY")
# No folders to reopen (the runner opens its project) and every plugin on.
ORBIT_EXTRA_PREFS=$(python3 -I -c 'import json, sys; print(json.dumps({"orbit.stress": sys.argv[1], "orbit.openFolders": [], "orbit.disabledPlugins": []}))' "$plan") \
    orbit_use_prefs "$ORBIT_SCRATCH/project" src/short.tsx
started=$(date +%s)
echo "Stress run on macOS $(sw_vers -productVersion), seed $SEED, $STEPS random steps$([ -n "$FOREGROUND" ] && echo ", in front"): $OUT"

# -g: launched without coming to the front.
open -g -n --stdout "$OUT/app.log" --stderr "$OUT/app.log" "$RUN_APP"
PID=
for _ in $(seq 1 50); do PID=$(pgrep -nf "$RUN_APP/Contents/MacOS/Orbit" || true); [ -z "$PID" ] || break; sleep 0.1; done
[ -n "$PID" ] || { echo "error: Orbit didn't start" >&2; exit 1; }

# The run writes result.txt when it ends; the watchdog writes it on a hang.
while kill -0 "$PID" 2>/dev/null; do
    if grep -q '^hung' "$OUT/result.txt" 2>/dev/null; then
        sample "$PID" 3 -file "$OUT/sample.txt" >/dev/null 2>&1 || true
        kill -9 "$PID" 2>/dev/null || true
        break
    fi
    sleep 0.5
done

# A crash report of this copy written since the start.
crash() {
    local report
    for report in $(ls -t ~/Library/Logs/DiagnosticReports/Orbit-*.ips 2>/dev/null | head -5); do
        [ "$(stat -f %m "$report")" -ge "$started" ] || continue
        head -1 "$report" | grep -q "\"bundleID\":\"$ORBIT_DOMAIN\"" && { echo "$report"; return; }
    done
}

summary=$(head -1 "$OUT/coverage.txt" 2>/dev/null || true)
result=$(cat "$OUT/result.txt" 2>/dev/null || true)
elapsed=$(( $(date +%s) - started ))
if [ -z "$result" ]; then
    # ReportCrash takes a while to write it.
    report=
    for _ in $(seq 1 30); do report=$(crash || true); [ -z "$report" ] || break; sleep 1; done
    result="crashed: ${report:-no crash report}"
fi
echo "$result ($elapsed s)"
# A replay runs a log's steps only: what it covers says nothing.
if [ -z "$REPLAY" ]; then
    [ -z "$summary" ] || echo "coverage: $summary"
    grep -E '^(UNCOVERED|STALE)' "$OUT/coverage.txt" 2>/dev/null | head -40 || true
fi
case "$result" in
    passed*) exit 0 ;;
    *)
        echo "last steps:"
        grep -E '^[0-9]+: ' "$OUT/log.txt" | tail -5 | sed 's/^/  /'
        [ ! -f "$OUT/sample.txt" ] || echo "sample of the hang: $OUT/sample.txt"
        echo "log: $OUT/log.txt; again in the same order: SEED=$SEED STEPS=$STEPS make stress"
        exit 1
        ;;
esac
