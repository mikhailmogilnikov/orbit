#!/bin/bash
# Before a release (D246): `make stress-full`. The stress run longer (800
# random steps between 4 copies), with `leaks` on each copy at its end, then
# on macOS 26 in the VM. When both pass it stamps the code it ran
# (.build/stress/full-passed.json, a fingerprint per part as make stress
# keeps, D247), which `make release` compares the code with: docs, the site
# or the README changing since doesn't call for another run.
#   SEED=… STEPS=…            as for make stress
#   NO_VM=1                   without the macOS 26 run (not stamped then)
set -euo pipefail
cd "$(dirname "$0")/.."

SEED=${SEED:-$RANDOM}
STEPS=${STEPS:-800}
started=$(date +%s)
mkdir -p .build/stress
fingerprints=$(mktemp -t orbit-stress-full)
python3 -I scripts/stress-changes.py save "$fingerprints"

echo "== macOS $(sw_vers -productVersion), $STEPS steps, with leaks"
FULL=1 SEED=$SEED STEPS=$STEPS LEAKS=1 scripts/stress.sh
if [ -z "${NO_VM:-}" ]; then
    echo "== macOS 26 in the VM"
    SEED=$((SEED + 1)) STEPS=$((STEPS / 4)) scripts/stress-vm.sh
fi

echo "Full stress run passed in $(( $(date +%s) - started )) s; seed $SEED"
if [ -z "${NO_VM:-}" ]; then
    mv "$fingerprints" .build/stress/full-passed.json
    echo "Stamped the code it ran for make release"
else
    rm -f "$fingerprints"
    echo "Not stamped for a release: the macOS 26 run was left out"
fi
