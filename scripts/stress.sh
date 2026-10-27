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
#   make stress                        4 copies; only what changed since a run passed (D246):
#                                      those plugins and what uses them, 60 random steps;
#                                      the app, kernel, UI kit or scripts changed: all, 150
#   FULL=1 make stress                 everything, changed or not
#   STEPS=600 SEED=7 make stress       more steps, or a failed run's order again
#   JOBS=1 make stress                 one copy doing it all
#   STEPS=0 make stress                the fixed part and the coverage check only
#   REPLAY=<log.txt> make stress       a failed copy's steps again, in its order, with its seed
#                                      and mode (several logs: one copy each, side by side)
#   SHRINK=<log.txt> make stress       the fewest of a failed copy's steps that still fail
#                                      the same way (D246): shrunk.txt, to REPLAY
#   MODE=1 REPLAY=<log.txt> make stress  in another copy's mode (its number above)
#   LEAKS=1 make stress                `leaks` on each copy once its steps pass (D246)
#   STACKS=1 REPLAY=<log> make stress  allocations logged, so leaks and retainers.txt say where
#                                      each object was made (everything a few times slower)
#   MEMORY_LIMIT=2048 make stress      a copy over this many MB fails (4096)
#   FOREGROUND=1 make stress           one copy in front, with full screen (it takes over the Mac)
#   PERF=1 make stress                 one quiet copy times launch, opening files, typing, scrolling,
#                                      tabs, Settings, memory and CPU at rest, against the baseline
#                                      (D248, D249: the median of the last five that passed; PERF_ACCEPT=1 starts over)
#   PILING=0 REPLAY=<log> make stress  what steps let go of isn't checked: a crash past a flaky leak (D250)
#   APP=<Orbit.app> scripts/stress.sh  another debug build
#   OUT=<folder> scripts/stress.sh     results there, not in .build/stress/<seed>
#   SHOTS=1 make stress                gallery.html: a full run shows every panel, Settings pane
#                                      and a few editors in each copy and shoots them (D248; ~50 s)
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/orbit-env.sh
# Stopped (the shrinker stops a round early): the copies' settings and scratch folders still go.
trap 'exit 143' TERM INT

APP=${APP:-.build/xcode/Build/Products/Debug/Orbit.app}
[ -z "${SHRINK:-}" ] || exec python3 -u -I scripts/stress-shrink.py "$SHRINK" "$APP"
SEED=${SEED:-$RANDOM}
FOREGROUND=${FOREGROUND:-}
REPLAYS=(${REPLAY:-})
LEAKS=${LEAKS:-}
STACKS=${STACKS:-}
PERF=${PERF:-}
MEMORY_LIMIT=${MEMORY_LIMIT:-4096}
JOBS=${JOBS:-4}
[ ${#REPLAYS[@]} = 0 ] || JOBS=${#REPLAYS[@]}
[ -z "$FOREGROUND$PERF" ] || JOBS=1
RESULTS=$PWD/.build/stress
OUT=${OUT:-$RESULTS/$SEED}
PASSED=$RESULTS/passed.json
CHANGED=
if [ ${#REPLAYS[@]} = 0 ] && [ -z "${FULL:-}$FOREGROUND$PERF" ]; then
    changes=$(python3 -I scripts/stress-changes.py compare "$PASSED")
    case "$changes" in
        none) echo "Nothing changed since the last stress run that passed (FULL=1 runs it anyway)"; exit 0 ;;
        all) ;;
        *) CHANGED=$changes ;;
    esac
fi
STEPS=${STEPS:-$([ -n "$CHANGED" ] && echo 60 || echo 150)}

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
OUT=$(cd "$OUT" && pwd)
# The code as it is now, stamped as passed if the run passes.
mkdir -p "$RESULTS" && python3 -I scripts/stress-changes.py save "$OUT/fingerprints.json"
started=$(date +%s)
# The copies' reports from before, out of the way of macOS' 25 a day (D250).
mkdir -p "$RESULTS/crash-reports"
for report in ~/Library/Logs/DiagnosticReports/Orbit-*.ips; do
    [ -f "$report" ] && head -1 "$report" | grep -q '"bundleID":"dev.orbit.app.stress' && mv "$report" "$RESULTS/crash-reports/" || true
done
echo "Stress run on macOS $(sw_vers -productVersion), seed $SEED, $STEPS random steps, $JOBS $([ "$JOBS" = 1 ] && echo copy || echo copies)$([ -n "$FOREGROUND" ] && echo ", in front")$([ -z "$CHANGED" ] || echo ", only what changed: $CHANGED"): $OUT"

PIDS=()
for ((job = 0; job < JOBS; job++)); do
    export ORBIT_DOMAIN=dev.orbit.app.stress$job
    app=$RESULTS/OrbitStress$job.app
    out=$OUT/$job
    mkdir -p "$out"
    orbit_side_copy "$APP" "$app" "$ORBIT_DOMAIN" "$([ -n "$FOREGROUND" ] || echo background)"
    orbit_scratch
    replay=
    if [ ${#REPLAYS[@]} != 0 ]; then
        replay=$out/replay.txt
        cp "${REPLAYS[$job]}" "$replay"
        # The failed copy's mode, kept beside its log.
        mode_index=${MODE:-$(cat "$(dirname "${REPLAYS[$job]}")/mode.txt" 2>/dev/null || echo 0)}
    else
        mode_index=${MODE:-$job}
    fi
    mode_index=$(( mode_index % ${#MODES[@]} ))
    echo "$mode_index" > "$out/mode.txt"
    mode=${MODES[$mode_index]}
    plan=$(python3 -I -c '
import json, sys
seed, steps, project, out, background, replay, job, jobs, mode, leaks, limit, changed, stacks, gallery, perf, piling = sys.argv[1:]
plan = {"seed": int(seed), "steps": int(steps), "project": project, "output": out, "background": background == "true",
        "shard": int(job), "shards": int(jobs), "bigProject": bool(json.loads(mode).get("orbit.stressBigProject")),
        "leaks": leaks == "1", "memoryLimitMB": int(limit), "stacks": stacks == "1", "gallery": gallery == "1", "perf": perf == "1", "piling": piling != "0"}
if replay: plan["replay"] = replay
if changed: plan["changed"] = changed.split()
print(json.dumps(plan))' \
        "$((SEED + job * 7919))" "$(( (STEPS + JOBS - 1) / JOBS ))" "$ORBIT_SCRATCH/project" "$out" \
        "$([ -n "$FOREGROUND" ] && echo false || echo true)" "$replay" "$job" "$JOBS" "$mode" "${LEAKS:-0}" "$MEMORY_LIMIT" "$CHANGED" "${STACKS:-0}" "$([ -z "$CHANGED$PERF" ] && [ ${#REPLAYS[@]} = 0 ] && [ "${SHOTS:-0}" = 1 ] && echo 1 || echo 0)" "${PERF:-0}" "${PILING:-1}")
    # No folders to reopen (the runner opens its project), every plugin on, the copy's mode.
    ORBIT_EXTRA_PREFS=$(python3 -I -c '
import json, sys
prefs = {"orbit.stress": sys.argv[1], "orbit.openFolders": [], "orbit.disabledPlugins": []}
prefs.update(json.loads(sys.argv[2]))
print(json.dumps(prefs))' "$plan" "$mode") orbit_use_prefs "$ORBIT_SCRATCH/project" src/short.tsx
    # -g: launched without coming to the front. With LEAKS, where each leak was made.
    open -g -n --stdout "$out/app.log" --stderr "$out/app.log" $([ -z "$STACKS" ] || echo --env MallocStackLogging=1) "$app"
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
        # Kept with the run: macOS writes 25 reports an app a day, and runs
        # crash more than that; the copies' reports leave its folder (D250).
        if [ -n "$report" ]; then mv "$report" "$out/crash.ips" && report=$out/crash.ips; fi
        result="crashed: ${report:-no crash report (macOS keeps 25 a day)}"
    fi
    echo "$result" > "$out/outcome.txt"
    echo "copy $job (${MODE_NAMES[$(cat "$out/mode.txt")]}): $result"
    case "$result" in
        passed*) ;;
        *)
            failed=1
            { grep -E '^[0-9]+: ' "$out/log.txt" 2>/dev/null || true; } | tail -5 | sed 's/^/    /'
            [ ! -f "$out/sample.txt" ] || echo "    sample of what it was doing: $out/sample.txt"
            echo "    log: $out/log.txt (REPLAY= it to play it again, SHRINK= it for the fewest steps that fail)"
            ;;
    esac
done

if [ -n "$PERF" ] && [ "$failed" = 0 ]; then
    python3 -I scripts/stress-perf.py "$OUT/0/perf.json" "$RESULTS/perf-baseline.json" "${PERF_ACCEPT:-0}" || failed=1
fi
# The copies' coverage added up: what none reached and nothing exempts fails the run.
if [ ${#REPLAYS[@]} = 0 ] && [ -z "$PERF" ]; then
    python3 -I - "$OUT" <<'EOF' || failed=1
import glob, json, sys
known, every, reached, exemptions = set(), set(), set(), {}
for path in glob.glob(f"{sys.argv[1]}/*/coverage.json"):
    data = json.load(open(path))
    known |= set(data["known"]); every |= set(data.get("all", data["known"])); reached |= set(data["reached"]); exemptions.update(data["exemptions"])
def exempt(key):
    return key in exemptions or any(e.endswith("*") and key.startswith(e[:-1]) for e in exemptions)
uncovered = sorted(k for k in known - reached if not exempt(k))
stale = sorted(e for e in exemptions if not (any(k.startswith(e[:-1]) for k in every) if e.endswith("*") else e in every))
left = len(every - known)
print(f"coverage: reached {len(reached & known)} of {len(known)}; {len(exemptions)} exempt" + (f"; {left} unchanged since a run passed" if left else ""))
for key in uncovered: print(f"UNCOVERED {key}")
for key in stale: print(f"STALE EXEMPTION {key}")
sys.exit(1 if uncovered or stale or not known else 0)
EOF
fi
python3 -I scripts/stress-gallery.py "$OUT" "${MODE_NAMES[@]}" || true
# The code it ran, as passed: the next run leaves out what's still the same.
[ "$failed" != 0 ] || [ ${#REPLAYS[@]} != 0 ] || [ -n "$FOREGROUND$PERF" ] || [ ! -f "$OUT/fingerprints.json" ] || cp "$OUT/fingerprints.json" "$PASSED"
echo "$([ "$failed" = 0 ] && echo passed || echo FAILED) in $(( $(date +%s) - started )) s; seed $SEED"
exit "$failed"
