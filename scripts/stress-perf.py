#!/usr/bin/env python3
# `PERF=1 make stress` (D248): one quiet copy times what a person waits for
# (perf.json), compared here with the baseline: each number's median over the
# last five runs that passed (D249: one run's numbers move by a third, and a
# lucky one as the baseline failed the next). A number worse by half and by
# more than its floor (20 ms, 5 MB, 2 % CPU; a launch 2 s: the first after
# a build is cold, 2.2 s to a warm one's 1.3, and one took 4 s) fails; the whole footprint is
# shown, not compared. A run that passes joins the baseline; PERF_ACCEPT=1
# starts it over from this run.
#   stress-perf.py <perf.json> <baseline.json> <accept: 0|1>
import json, os, statistics, sys

current_path, baseline_path, accept = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
current = json.load(open(current_path))
floors = {"launch": 2000, "ms": 20, "MB": 5, "%": 2}
shown_only = ("at the end",)
kept = 5


def floor(name):
    return next((value for key, value in floors.items() if key in name), 20)


runs = []
if not accept and os.path.exists(baseline_path):
    saved = json.load(open(baseline_path))
    # D248's baseline was one run.
    runs = saved.get("runs", [saved]) if isinstance(saved, dict) else []
baseline = {}
for name in current:
    values = [run[name] for run in runs if name in run]
    if values:
        baseline[name] = statistics.median(values)

worse = []
print(f"{'':32}{'now':>10}{'baseline':>10}")
for name in sorted(current):
    now = current[name]
    then = baseline.get(name)
    mark = ""
    if any(part in name for part in shown_only):
        mark = "  (shown, not compared)"
    elif then is not None and now > then * 1.5 and now - then > floor(name):
        mark = "  WORSE"
        worse.append(name)
    print(f"{name:32}{now:10.1f}{'' if then is None else f'{then:10.1f}'}{mark}")
if worse:
    print(f"slower than the baseline: {', '.join(worse)} (PERF_ACCEPT=1 if that's meant)")
    sys.exit(1)
runs = (runs + [current])[-kept:]
with open(baseline_path, "w") as file:
    json.dump({"runs": runs}, file, indent=1, sort_keys=True)
print(f"baseline {'started over' if accept else 'of'} {len(runs)} run{'s' if len(runs) > 1 else ''}: {baseline_path}")
