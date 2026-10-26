#!/usr/bin/env python3
# What changed since the last stress run that passed (D246), so `make stress`
# runs only that. A fingerprint per part of the code: each plugin module on its
# own, the scripts, and everything else (the app, the kernel and UI kit, the
# build settings) as one; a change to either of the last two runs it all.
#   stress-changes.py compare <passed.json>   prints "all", "none" or the changed plugin modules
#   stress-changes.py compare-app <passed.json>   the same, the scripts left out (make release)
#   stress-changes.py save <passed.json>      after a run passed
import hashlib, json, os, subprocess, sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sources = "Packages/OrbitKit/Sources"
shared_modules = {"OrbitAPI", "OrbitUI", "OrbitACP", "OrbitKit"}


def files(paths):
    out = subprocess.run(["git", "ls-files", "-co", "--exclude-standard", "--", *paths],
                         cwd=root, capture_output=True, text=True, check=True).stdout
    return sorted(line for line in out.splitlines() if line)


def digest(paths):
    sha = hashlib.sha256()
    for path in files(paths):
        sha.update(path.encode() + b"\0")
        try:
            sha.update(open(os.path.join(root, path), "rb").read())
        except OSError:
            sha.update(b"gone")
    return sha.hexdigest()


def fingerprints():
    modules = sorted(name for name in os.listdir(os.path.join(root, sources)) if os.path.isdir(os.path.join(root, sources, name)))
    plugins = [name for name in modules if name not in shared_modules]
    parts = {name: digest([f"{sources}/{name}"]) for name in plugins}
    shared = [f"{sources}/{name}" for name in modules if name in shared_modules]
    parts["*"] = digest(["App", "project.yml", "Packages/OrbitKit/Package.swift", "Packages/OrbitKit/Package.resolved", *shared])
    parts["scripts"] = digest(["scripts"])
    return parts


command, path = sys.argv[1], sys.argv[2]
try:
    current = fingerprints()
except (OSError, subprocess.CalledProcessError):
    # Not in a git checkout (the copy of the scripts in the VM): it all runs, nothing is stamped.
    print("all") if command.startswith("compare") else None
    sys.exit(0)
if command == "save":
    with open(path, "w") as file:
        json.dump(current, file, indent=1, sort_keys=True)
    sys.exit(0)
try:
    passed = json.load(open(path))
except (OSError, ValueError):
    print("all")
    sys.exit(0)
if command == "compare-app":
    current.pop("scripts", None)
    passed.pop("scripts", None)
changed = sorted(name for name, value in current.items() if passed.get(name) != value)
if "*" in changed or "scripts" in changed or set(passed) != set(current):
    print("all")
else:
    print(" ".join(changed) if changed else "none")
