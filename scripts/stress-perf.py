#!/usr/bin/env python3
# `PERF=1 make stress` (D248): one quiet copy times what a person waits for
# (perf.json), compared here with the accepted baseline. A number worse by a
# third and by more than its floor (20 ms, 5 MB, 2 % CPU; a launch 500 ms: the
# first after a build is cold) fails; the whole footprint is shown, not
# compared (it moves by a third run to run). The first run or PERF_ACCEPT=1
# makes the run the baseline.
#   stress-perf.py <perf.json> <baseline.json> <accept: 0|1>
import json, os, sys

current_path, baseline_path, accept = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
current = json.load(open(current_path))
floors = {"launch": 500, "ms": 20, "MB": 5, "%": 2}
shown_only = ("at the end",)


def floor(name):
    return next((value for key, value in floors.items() if key in name), 20)


baseline = None if accept or not os.path.exists(baseline_path) else json.load(open(baseline_path))
worse = []
print(f"{'':32}{'now':>10}{'baseline':>10}")
for name in sorted(current):
    now = current[name]
    then = baseline.get(name) if baseline else None
    mark = ""
    if any(part in name for part in shown_only):
        mark = "  (shown, not compared)"
    elif then is not None and now > then * 1.33 and now - then > floor(name):
        mark = "  WORSE"
        worse.append(name)
    print(f"{name:32}{now:10.1f}{'' if then is None else f'{then:10.1f}'}{mark}")
if baseline is None:
    with open(baseline_path, "w") as file:
        json.dump(current, file, indent=1, sort_keys=True)
    print(f"baseline {'accepted' if accept else 'written'}: {baseline_path}")
elif worse:
    print(f"slower than the baseline: {', '.join(worse)} (PERF_ACCEPT=1 if that's meant)")
    sys.exit(1)
