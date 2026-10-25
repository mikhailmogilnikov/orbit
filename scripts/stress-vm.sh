#!/bin/bash
# The stress run on macOS 26, the minimum (D1), in a Tart VM (D235, D246):
# `make stress-vm`. Starts the VM when it isn't running (and stops it after),
# copies the debug build and the scripts in over SSH, runs scripts/stress.sh
# there and brings the results back to .build/stress/vm-<seed>.
#
# Once per VM it installs an SSH key (through Tart's guest agent) and the
# Command Line Tools, which the run needs for git and python3 (the vanilla
# image has neither; a few minutes' download).
#   VM=tahoe                      the Tart VM (macos-tahoe-vanilla)
#   JOBS=2 STEPS=150 SEED=…       as for make stress; 2 copies fit the VM's 4 cores
#   REPLAY=<log.txt>              a failed copy's steps again there (its mode.txt beside it)
#   SHRINK=<log.txt>              its fewest steps that fail there (to .build/stress/shrink-…)
set -euo pipefail
cd "$(dirname "$0")/.."

TART=${TART:-$(command -v tart || echo "$HOME/Applications/tart.app/Contents/MacOS/tart")}
VM=${VM:-tahoe}
APP=${APP:-.build/xcode/Build/Products/Debug/Orbit.app}
SEED=${SEED:-$RANDOM}
JOBS=${JOBS:-2}
STEPS=${STEPS:-150}
KEY=$HOME/.tart/orbit-stress-key
OUT=$PWD/.build/stress/vm-$SEED${REPLAY:+-replay}${SHRINK:+-shrink}

[ -x "$TART" ] || { echo "No Tart (https://tart.run): brew install cirruslabs/cli/tart" >&2; exit 1; }
[ -x "$APP/Contents/MacOS/Orbit" ] || { echo "No debug build at $APP: make build" >&2; exit 1; }
"$TART" list | grep -qE "^local +$VM " || { echo "No Tart VM named $VM: tart clone ghcr.io/cirruslabs/macos-tahoe-vanilla:latest $VM" >&2; exit 1; }

if ! "$TART" list | grep -E "^local +$VM " | grep -q running; then
    echo "Starting $VM"
    "$TART" run "$VM" --no-graphics >/dev/null 2>&1 &
    stops_vm=1
fi
stops_vm=${stops_vm:-}
IP=$("$TART" ip "$VM" --wait 180)

[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N '' -C orbit-stress -f "$KEY"
vm() { ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=10 "admin@$IP" "$@"; }
# Not authorized yet (or sshd still starting): the key through Tart's guest
# agent, or with the image's password (cirruslabs images: admin/admin).
authorize="mkdir -p ~/.ssh && { grep -qF '$(cat "$KEY.pub")' ~/.ssh/authorized_keys 2>/dev/null || echo '$(cat "$KEY.pub")' >> ~/.ssh/authorized_keys; } && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys"
askpass=$(mktemp -t orbit-askpass)
trap 'rm -f "$askpass"; [ -z "${stops_vm:-}" ] || "$TART" stop "$VM" >/dev/null 2>&1 || true' EXIT
printf '#!/bin/sh\necho "%s"\n' "${VM_PASSWORD:-admin}" > "$askpass" && chmod 700 "$askpass"
for _ in $(seq 1 30); do vm true 2>/dev/null && break
    "$TART" exec "$VM" /bin/sh -c "$authorize" >/dev/null 2>&1 ||
        SSH_ASKPASS=$askpass SSH_ASKPASS_REQUIRE=force ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
            -o PubkeyAuthentication=no -o ConnectTimeout=10 "admin@$IP" "$authorize" </dev/null >/dev/null 2>&1 || true
    sleep 3
done
vm true || { echo "Can't reach $VM over SSH at $IP" >&2; exit 1; }
echo "$VM: macOS $(vm sw_vers -productVersion) at $IP"

if ! vm 'xcode-select -p >/dev/null 2>&1 && /usr/bin/python3 -c 1 >/dev/null 2>&1'; then
    echo "Installing the Command Line Tools in $VM (once)"
    vm 'touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
        label=$(softwareupdate -l 2>/dev/null | sed -n "s/^\* Label: \(Command Line Tools.*\)$/\1/p" | sort -V | tail -1)
        [ -n "$label" ] || { echo "softwareupdate lists no Command Line Tools" >&2; exit 1; }
        sudo -n softwareupdate -i "$label" --agree-to-license >/dev/null
        rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress'
fi

echo "Copying the build into $VM"
vm 'rm -rf ~/orbit-stress && mkdir -p ~/orbit-stress/.build/replay'
rsync -a -e "ssh -i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes" \
    scripts "$APP" "admin@$IP:orbit-stress/"
replay=
for variable in REPLAY SHRINK; do
    log=${!variable:-}
    [ -n "$log" ] || continue
    rsync -a -e "ssh -i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes" \
        "$log" $(ls "$(dirname "$log")"/{mode,outcome,result}.txt 2>/dev/null) "admin@$IP:orbit-stress/.build/replay/"
    replay="$variable=\$HOME/orbit-stress/.build/replay/$(basename "$log")"
done
status=0
vm "cd ~/orbit-stress && APP=Orbit.app JOBS=$JOBS STEPS=$STEPS SEED=$SEED OUT=\$HOME/orbit-stress/out $replay ${MODE:+MODE=$MODE} scripts/stress.sh" || status=$?
rm -rf "$OUT" && mkdir -p "$OUT"
rsync -a -e "ssh -i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes" \
    "admin@$IP:orbit-stress/out/" "$OUT/" || true
[ -z "${SHRINK:-}" ] || rsync -a -e "ssh -i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes" \
    "admin@$IP:orbit-stress/.build/stress/shrink-*" .build/stress/ || true
# Crash reports of the copies, written there.
rsync -a -e "ssh -i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes" \
    --include 'Orbit-*.ips' --exclude '*' "admin@$IP:Library/Logs/DiagnosticReports/" "$OUT/" 2>/dev/null || true
echo "macOS 26 results: $OUT"
exit "$status"
