#!/bin/bash
# Before a release (D246): `make stress-full`. The stress run longer (800
# random steps between 4 copies), with `leaks` on each copy at its end, then
# on macOS 26 in the VM. When all pass on a committed tree it leaves
# .build/stress/passed-<commit>, which `make release` asks for.
#   SEED=… STEPS=…            as for make stress
#   NO_VM=1                   without the macOS 26 run (not stamped then)
set -euo pipefail
cd "$(dirname "$0")/.."

SEED=${SEED:-$RANDOM}
STEPS=${STEPS:-800}
commit=$(git rev-parse HEAD)
clean=$([ -z "$(git status --porcelain)" ] && echo 1 || true)
started=$(date +%s)

echo "== macOS $(sw_vers -productVersion), $STEPS steps, with leaks"
FULL=1 SEED=$SEED STEPS=$STEPS LEAKS=1 scripts/stress.sh
if [ -z "${NO_VM:-}" ]; then
    echo "== macOS 26 in the VM"
    SEED=$((SEED + 1)) STEPS=$((STEPS / 4)) scripts/stress-vm.sh
fi

echo "Full stress run passed in $(( $(date +%s) - started )) s; seed $SEED"
if [ -n "$clean" ] && [ -z "${NO_VM:-}" ]; then
    echo "seed $SEED, $STEPS steps, $(date '+%Y-%m-%d %H:%M')" > ".build/stress/passed-$commit"
    echo "Stamped $commit for make release"
else
    echo "Not stamped for a release: $([ -n "$clean" ] && echo "the VM run was left out" || echo "the tree has uncommitted changes")"
fi
