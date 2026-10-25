#!/usr/bin/env python3
# The fewest of a failed stress copy's steps that still fail the same way
# (D246): `SHRINK=<log.txt> make stress`. Delta debugging over the log's steps,
# four replays side by side (scripts/stress.sh with several REPLAY logs). A
# step keeps its number, so its random numbers are the ones it had; "the same
# way" is the same check, hang, leak or crash (its exception and the first
# frame in Orbit). Writes shrunk.txt and its mode beside it, to REPLAY.
import json, os, re, subprocess, sys

log_path, app = os.path.abspath(sys.argv[1]), sys.argv[2]
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
folder = os.path.dirname(log_path)
lines = open(log_path).read().splitlines()
seed_line = next((line for line in lines if re.search(r", seed \d+$", line)), "")
steps = [line for line in lines if re.match(r"^\d+: ", line)]
mode = open(os.path.join(folder, "mode.txt")).read().strip() if os.path.exists(os.path.join(folder, "mode.txt")) else "0"
work = os.path.join(root, ".build", "stress", "shrink-" + os.path.basename(os.path.dirname(folder)) + "-" + os.path.basename(folder))
jobs = 4


def crash_signature(report):
    try:
        text = open(report).read()
        body = json.loads(text[text.index("\n") + 1:])
    except (OSError, ValueError):
        return "crashed"
    images = [image.get("name", "") for image in body.get("usedImages", [])]
    frames = body.get("lastExceptionBacktrace") or body["threads"][body.get("faultingThread", 0)].get("frames", [])
    index = lambda frame: frame.get("imageIndex", len(images))
    ours = [frame.get("symbol", "?") for frame in frames if index(frame) < len(images) and "Orbit" in images[index(frame)]]
    return f"crashed: {body.get('exception', {}).get('type', '?')} in {ours[0] if ours else '?'}"


def signature(outcome):
    """What a failure is, without what depends on how many steps came before."""
    if outcome.startswith("crashed: ") and outcome.endswith(".ips"):
        return crash_signature(outcome[len("crashed: "):])
    kind = re.sub(r"^failed: \d+: [^:]*: ", "", outcome)
    if kind.startswith("check "):
        return kind.split(":")[0]
    if kind.startswith(("hung", "busy")):
        return kind.split(":")[0]
    return re.sub(r"\d+", "#", kind)[:120]


round_number = 0


def run(candidates):
    """Replays each list of steps in a copy of its own; which failed as the original did."""
    global round_number
    round_number += 1
    out = os.path.join(work, str(round_number))
    os.makedirs(out, exist_ok=True)
    logs = []
    for index, candidate in enumerate(candidates):
        path = os.path.join(out, f"candidate{index}.txt")
        open(path, "w").write("\n".join([seed_line] + candidate) + "\n")
        logs.append(path)
    open(os.path.join(out, "mode.txt"), "w").write(mode)
    env = dict(os.environ, REPLAY=" ".join(logs), OUT=os.path.join(out, "copies"), MODE=mode, APP=app)
    env.pop("SHRINK", None)
    subprocess.run(["scripts/stress.sh"], cwd=root, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    results = []
    for index in range(len(candidates)):
        try:
            outcome = open(os.path.join(out, "copies", str(index), "outcome.txt")).read().strip()
        except OSError:
            outcome = "no outcome"
        results.append(not outcome.startswith("passed") and signature(outcome) == target)
    return results


def chunks(items, count):
    size, rest = divmod(len(items), count)
    result, start = [], 0
    for index in range(count):
        end = start + size + (1 if index < rest else 0)
        result.append(items[start:end])
        start = end
    return [chunk for chunk in result if chunk]


original = open(os.path.join(folder, "outcome.txt")).read().strip() if os.path.exists(os.path.join(folder, "outcome.txt")) \
    else open(os.path.join(folder, "result.txt")).read().strip()
target = signature(original)
print(f"Shrinking {len(steps)} steps that failed as: {target}")
if not any(run([steps, steps])):
    sys.exit("It doesn't fail the same way when replayed (twice): it depends on timing; the log is all there is.")

count = 2
while len(steps) > 1:
    parts = chunks(steps, count)
    # Each part alone, then everything but each part: the first that still fails wins.
    candidates = parts + ([[step for other in parts if other is not part for step in other] for part in parts] if count > 2 else [])
    found = None
    for start in range(0, len(candidates), jobs):
        batch = candidates[start:start + jobs]
        for candidate, failed in zip(batch, run(batch)):
            if failed:
                found = candidate
                break
        if found:
            break
    if found:
        count = 2 if len(found) <= len(steps) // count else max(count - 1, 2)
        steps = found
        print(f"  {len(steps)} steps still fail")
    elif count >= len(steps):
        break
    else:
        count = min(len(steps), count * 2)

shrunk = os.path.join(work, "shrunk.txt")
open(shrunk, "w").write("\n".join([seed_line] + steps) + "\n")
open(os.path.join(work, "mode.txt"), "w").write(mode)
print(f"{len(steps)} steps fail as {target}:")
for step in steps:
    print(f"    {step}")
print(f"REPLAY={os.path.relpath(shrunk, root)} make stress")
