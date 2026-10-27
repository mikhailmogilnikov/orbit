#!/usr/bin/env python3
# The fewest of a failed stress copy's steps that still fail the same way
# (D246): `SHRINK=<log.txt> make stress`. The log's last steps first (1, 2, 4,
# 8…: what broke is usually near the end), then delta debugging over what's
# left, four replays side by side (scripts/stress.sh with several REPLAY logs),
# a round stopped as soon as one of them fails the same way. A step keeps its
# number, so its random numbers are the ones it had; "the same way" is the same
# check, hang, leak or crash (its exception and the first frame in Orbit; a
# crash macOS wrote no report for counts too). Writes shrunk.txt and its mode
# beside it, to REPLAY.
import json, os, re, signal, subprocess, sys, time

log_path, app = os.path.abspath(sys.argv[1]), sys.argv[2]
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
folder = os.path.dirname(log_path)
lines = open(log_path).read().splitlines()
seed_line = next((line for line in lines if re.search(r", seed \d+$", line)), "")
steps = [line for line in lines if re.match(r"^\d+: ", line)]
mode = open(os.path.join(folder, "mode.txt")).read().strip() if os.path.exists(os.path.join(folder, "mode.txt")) else "0"
work = os.path.join(root, ".build", "stress", "shrink-" + os.path.basename(os.path.dirname(folder)) + "-" + os.path.basename(folder))
# One at a time for what crashes only alone (SHRINK_JOBS=1): side by side
# they slow each other and the timing it needs goes (D250).
jobs = int(os.environ.get("SHRINK_JOBS", "4"))


def crash_signature(report):
    # An Objective-C exception's reason, when the copy's log has it: macOS
    # files the same one as EXC_CRASH one time, EXC_BREAKPOINT the next (D250).
    try:
        log = open(os.path.join(os.path.dirname(report), "app.log"), errors="replace").read()
        found = re.search(r"Terminating app due to uncaught exception '([^']+)', reason: '([^']{0,80})", log)
        if found:
            return f"crashed: {found.group(1)}: {re.sub(r'0x[0-9a-f]+|[0-9.]+', '#', found.group(2))}"
    except OSError:
        pass
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


def same(outcome):
    """Fails as the original did. macOS stops writing reports when a process crashes often."""
    if outcome.startswith("passed") or not outcome:
        return False
    if target.startswith("crashed") and outcome.startswith("crashed: no crash report"):
        return True
    return signature(outcome) == target


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
    copies = os.path.join(out, "copies")
    env = dict(os.environ, REPLAY=" ".join(logs), OUT=copies, MODE=mode, APP=app)
    env.pop("SHRINK", None)
    script = subprocess.Popen(["scripts/stress.sh"], cwd=root, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              start_new_session=True)
    while script.poll() is None:
        time.sleep(0.5)
        # A copy that failed the same way settles the round: the others needn't finish.
        for index in range(len(candidates)):
            if same(read(os.path.join(copies, str(index), "result.txt"))):
                try:
                    os.killpg(script.pid, signal.SIGTERM)
                except (PermissionError, ProcessLookupError):
                    pass  # The group is gone, its leader not reaped yet (macOS says EPERM).
                for other in range(len(candidates)):
                    subprocess.run(["pkill", "-f", f".build/stress/OrbitStress{other}.app/Contents/MacOS/Orbit"])
                script.wait()
                return [other == index for other in range(len(candidates))]
    return [same(read(os.path.join(copies, str(index), "outcome.txt"))) for index in range(len(candidates))]


def read(path):
    try:
        return open(path).read().strip()
    except OSError:
        return ""


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
if not any(any(run([steps, steps] if jobs > 1 else [steps])) for _ in range(1 if jobs > 1 else 2)):
    sys.exit("It doesn't fail the same way when replayed (twice): it depends on timing; the log is all there is.")

# The last steps alone first: 1, 2, 4… of them, four at a time.
length = 1
while length < len(steps):
    batch = []
    while length < len(steps) and len(batch) < jobs:
        batch.append(steps[-length:])
        length *= 2
    hits = [candidate for candidate, failed in zip(batch, run(batch)) if failed]
    if hits:
        steps = min(hits, key=len)
        print(f"  the last {len(steps)} steps fail alone")
        break

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
