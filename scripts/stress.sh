#!/bin/bash
# Tries to break a debug build of Orbit (D243, D244). Orbit runs it itself
# (App/StressRunner.swift): it writes a project from every plugin's files,
# goes through every command, panel, Settings pane, plugin switch and plugin
# step once, plays the regressions, then takes random steps. After each the
# main thread has to go idle and every check has to hold, and whatever no
# step reached and nothing exempts fails the run.
#
# Copies run side by side (JOBS, D245), each with its own bundle id, settings,
# project and seed, its share of the fixed part and a mode of its own (scroller
# style, appearance, text sizes, wrapping, no color theme, a big project);
# their coverage is added up here. All in the background: never activated,
# windows behind yours, so the Mac stays usable.
#   make stress                        4 copies, 150 random steps between them
#   STEPS=600 SEED=7 make stress       more steps, or a failed run's order again
#   JOBS=1 make stress                 one copy doing it all
#   STEPS=0 make stress                the fixed part and the coverage check only
#   REPLAY=<log.txt> make stress       a failed copy's steps again, in its order (the
#                                      log's first line has the copy's seed: SEED= it for the same picks)
#   MODE=1 REPLAY=<log.txt> make stress  with a copy's mode (its number above)
#   FOREGROUND=1 make stress           one copy in front, with full screen (it takes over the Mac)
#   APP=<Orbit.app> scripts/stress.sh  another debug build
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/orbit-env.sh

APP=${APP:-.build/xcode/Build/Products/Debug/Orbit.app}
STEPS=${STEPS:-150}
SEED=${SEED:-$RANDOM}
FOREGROUND=${FOREGROUND:-}
REPLAY=${REPLAY:-}
JOBS=${JOBS:-4}
[ -z "$REPLAY$FOREGROUND" ] || JOBS=1
RESULTS=$PWD/.build/stress
OUT=$RESULTS/$SEED

# What each copy runs in, by its number (the first is Orbit's own settings).
MODES=(
    '{}'
    '{"AppleShowScrollBars": "Always", "orbit.appearance": "dark", "orbit.codeFontSize": 22, "orbit.interfaceTextSize": 15, "orbit.codeLineHeight": 1.6}'
    '{"orbit.appearance": "light", "orbit.codeFontSize": 9, "orbit.interfaceTextSize": 10, "plugin.orbit.editor.wrapsLines": true}'
    '{"orbit.lightTheme": null, "orbit.darkTheme": null, "orbit.lightIconTheme": null, "orbit.darkIconTheme": null, "orbit.stressBigProject": true}'
)
MODE_NAMES=("as set" "always-shown scrollers, dark, large text" "light, small text, wrapping" "no color theme, a big project")

[ -x "$APP/Contents/MacOS/Orbit" ] || { echo "No debug build at $APP: make build" >&2; exit 1; }
rm -rf "$OUT" && mkdir -p "$OUT"
[ -z "$REPLAY" ] || cp "$REPLAY" "$OUT/replay.txt"
started=$(date +%s)
echo "Stress run on macOS $(sw_vers -productVersion), seed $SEED, $STEPS random steps, $JOBS $([ "$JOBS" = 1 ] && echo copy || echo copies)$([ -n "$FOREGROUND" ] && echo ", in front"): $OUT"

PIDS=()
for ((job = 0; job < JOBS; job++)); do
    export ORBIT_DOMAIN=dev.orbit.app.stress$job
    app=$RESULTS/OrbitStress$job.app
    out=$OUT/$job
    mkdir -p "$out"
    orbit_side_copy "$APP" "$app" "$ORBIT_DOMAIN" "$([ -n "$FOREGROUND" ] || echo background)"
    orbit_scratch
    mode_index=$(( ${MODE:-$job} % ${#MODES[@]} ))
    mode=${MODES[$mode_index]}
    plan=$(python3 -I -c '
import json, sys
seed, steps, project, out, background, replay, job, jobs, mode = sys.argv[1:]
plan = {"seed": int(seed), "steps": int(steps), "project": project, "output": out, "background": background == "true",
        "shard": int(job), "shards": int(jobs), "bigProject": bool(json.loads(mode).get("orbit.stressBigProject"))}
if replay: plan["replay"] = replay
print(json.dumps(plan))' \
        "$((SEED + job * 7919))" "$(( (STEPS + JOBS - 1) / JOBS ))" "$ORBIT_SCRATCH/project" "$out" \
        "$([ -n "$FOREGROUND" ] && echo false || echo true)" "$([ -z "$REPLAY" ] || echo "$OUT/replay.txt")" "$job" "$JOBS" "$mode")
    # No folders to reopen (the runner opens its project), every plugin on, the copy's mode.
    ORBIT_EXTRA_PREFS=$(python3 -I -c '
import json, sys
prefs = {"orbit.stress": sys.argv[1], "orbit.openFolders": [], "orbit.disabledPlugins": []}
prefs.update(json.loads(sys.argv[2]))
print(json.dumps(prefs))' "$plan" "$mode") orbit_use_prefs "$ORBIT_SCRATCH/project" src/short.tsx
    # -g: launched without coming to the front.
    open -g -n --stdout "$out/app.log" --stderr "$out/app.log" "$app"
    pid=
    for _ in $(seq 1 50); do pid=$(pgrep -nf "$app/Contents/MacOS/Orbit" || true); [ -z "$pid" ] || break; sleep 0.1; done
    [ -n "$pid" ] || { echo "error: copy $job didn't start" >&2; exit 1; }
    PIDS+=("$pid")
done

# Each copy writes result.txt when it ends; its watchdog writes it on a hang.
while true; do
    running=0
    for ((job = 0; job < JOBS; job++)); do
        pid=${PIDS[$job]}
        kill -0 "$pid" 2>/dev/null || continue
        running=1
        if grep -qE '^(hung|busy)' "$OUT/$job/result.txt" 2>/dev/null && [ ! -f "$OUT/$job/sample.txt" ]; then
            sample "$pid" 3 -file "$OUT/$job/sample.txt" >/dev/null 2>&1 || true
            grep -q '^hung' "$OUT/$job/result.txt" && kill -9 "$pid" 2>/dev/null || true
        fi
    done
    [ "$running" = 1 ] || break
    sleep 0.5
done

# A crash report of a copy, written since the start.
crash() {
    local report domain=$1
    for report in $(ls -t ~/Library/Logs/DiagnosticReports/Orbit-*.ips 2>/dev/null | head -10); do
        [ "$(stat -f %m "$report")" -ge "$started" ] || continue
        head -1 "$report" | grep -q "\"bundleID\":\"$domain\"" && { echo "$report"; return; }
    done
}

failed=0
for ((job = 0; job < JOBS; job++)); do
    out=$OUT/$job
    result=$(cat "$out/result.txt" 2>/dev/null || true)
    if [ -z "$result" ]; then
        # ReportCrash takes a while to write it.
        report=
        for _ in $(seq 1 30); do report=$(crash "dev.orbit.app.stress$job" || true); [ -z "$report" ] || break; sleep 1; done
        result="crashed: ${report:-no crash report}"
    fi
    echo "copy $job (${MODE_NAMES[$(( ${MODE:-$job} % ${#MODE_NAMES[@]} ))]}): $result"
    case "$result" in
        passed*) ;;
        *)
            failed=1
            grep -E '^[0-9]+: ' "$out/log.txt" 2>/dev/null | tail -5 | sed 's/^/    /'
            [ ! -f "$out/sample.txt" ] || echo "    sample of what it was doing: $out/sample.txt"
            echo "    log: $out/log.txt (REPLAY=$out/log.txt make stress plays it again)"
            ;;
    esac
done

# The copies' coverage added up: what none reached and nothing exempts fails the run.
if [ -z "$REPLAY" ]; then
    python3 -I - "$OUT" <<'EOF' || failed=1
import glob, json, sys
known, reached, exemptions = set(), set(), {}
for path in glob.glob(f"{sys.argv[1]}/*/coverage.json"):
    data = json.load(open(path))
    known |= set(data["known"]); reached |= set(data["reached"]); exemptions.update(data["exemptions"])
def exempt(key):
    return key in exemptions or any(e.endswith("*") and key.startswith(e[:-1]) for e in exemptions)
uncovered = sorted(k for k in known - reached if not exempt(k))
stale = sorted(e for e in exemptions if not (any(k.startswith(e[:-1]) for k in known) if e.endswith("*") else e in known))
print(f"coverage: reached {len(reached & known)} of {len(known)}; {len(exemptions)} exempt")
for key in uncovered: print(f"UNCOVERED {key}")
for key in stale: print(f"STALE EXEMPTION {key}")
sys.exit(1 if uncovered or stale or not known else 0)
EOF
fi
echo "$([ "$failed" = 0 ] && echo passed || echo FAILED) in $(( $(date +%s) - started )) s; seed $SEED"
exit "$failed"
