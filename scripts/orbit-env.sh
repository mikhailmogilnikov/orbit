# Sourced by scripts that run a build of Orbit on a scratch project (D242, D243):
# a copy of the build under its own bundle id (ORBIT_DOMAIN), with settings of
# its own started from Orbit's, so it runs beside the Orbit in use.

# A scratch folder, deleted on exit. Not under /var: Orbit shortens /private/var
# paths and the saved tabs wouldn't match.
orbit_scratch() {
    ORBIT_SCRATCH=$(mktemp -d "$HOME/Library/Caches/orbit-run.XXXXXX")
}

# The copy of a build, under its own bundle id; `background` makes it an
# agent app (no Dock icon, not brought to the front when it starts).
orbit_side_copy() {
    local app=$1 copy=$2 id=$3 mode=${4:-}
    rm -rf "$copy"
    ditto "$app" "$copy"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $id" "$copy/Contents/Info.plist"
    [ "$mode" != background ] || /usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$copy/Contents/Info.plist"
    codesign --force --deep --sign - "$copy" 2>/dev/null
}

# orbit_use_prefs <project> <active tab> <tab>... — extra keys as JSON in ORBIT_EXTRA_PREFS.
orbit_use_prefs() {
    local project=$1 active=$2 domain=$ORBIT_DOMAIN extra=${ORBIT_EXTRA_PREFS:-}
    shift 2
    [ -n "$extra" ] || extra='{}'
    [ "$domain" != dev.orbit.app ] || { echo "ORBIT_DOMAIN has to be a bundle id of its own" >&2; exit 1; }
    defaults export dev.orbit.app "$ORBIT_SCRATCH/saved.plist" 2>/dev/null || echo '{}' | plutil -convert xml1 -o "$ORBIT_SCRATCH/saved.plist" -
    trap "defaults delete '$domain' 2>/dev/null; rm -rf '$ORBIT_SCRATCH'" EXIT
    python3 -I - "$ORBIT_SCRATCH/saved.plist" "$ORBIT_SCRATCH/run.plist" "$project" "$active" "$extra" "$@" <<'EOF'
import json, plistlib, sys
saved, run, project, active, extra, *tabs = sys.argv[1:]
prefs = plistlib.load(open(saved, "rb"))
prefs["orbit.openFolders"] = [project]
prefs["orbit.openFileTabs"] = {project: {"active": active, "files": tabs}}
prefs["orbit.moveToApplicationsSuppressed"] = True
prefs.pop("orbit.unfinishedLaunches", None)
prefs.update(json.loads(extra))
plistlib.dump(prefs, open(run, "wb"))
EOF
    # `import` merges: a last run's leftovers go first.
    defaults delete "$domain" 2>/dev/null || true
    defaults import "$domain" "$ORBIT_SCRATCH/run.plist"
}

orbit_crash_reports() {
    ls ~/Library/Logs/DiagnosticReports | grep -c '^Orbit-' || true
}

orbit_newest_crash_report() {
    ls -t ~/Library/Logs/DiagnosticReports/Orbit-* 2>/dev/null | head -1
}
