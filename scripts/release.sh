#!/bin/bash
# Builds a release of Orbit and its Sparkle appcast (D129):
#   scripts/release.sh setup            once: the update signing key (private half in the keychain)
#   scripts/release.sh build 0.2.0      Release build → .build/release/0.2.0/{Orbit-0.2.0.zip, appcast.xml}
#   scripts/release.sh publish 0.2.0    a GitHub release v0.2.0 with both files
#   scripts/release.sh smoke <Orbit.app> the launch check `build` runs, on any build
#
# With a "Developer ID Application" certificate in the keychain the build is signed
# with it, hardened, notarized with the keychain profile NOTARY_PROFILE (default
# "orbit-notary", made once with `xcrun notarytool store-credentials orbit-notary`)
# and stapled; DEVELOPER_ID picks one of several, AD_HOC=1 skips it. Otherwise ad hoc.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/orbit-env.sh

REPO=mikhailmogilnikov/orbit
DERIVED=.build/xcode
SPARKLE_BIN=$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin
NOTARY_PROFILE=${NOTARY_PROFILE:-orbit-notary}
command=${1:-}
version=${2:-}

resolve_sparkle() {
    if [ ! -x "$SPARKLE_BIN/generate_keys" ]; then
        xcodegen generate --quiet
        xcodebuild -resolvePackageDependencies -project Orbit.xcodeproj -scheme Orbit -derivedDataPath "$DERIVED" -quiet
    fi
}

public_key() {
    /usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" App/Info.plist 2>/dev/null || true
}

find_developer_id() {
    if [ -n "${AD_HOC:-}" ]; then DEVELOPER_ID=; return; fi
    if [ -z "${DEVELOPER_ID:-}" ]; then
        local ids
        ids=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' | sort -u)
        [ "$(printf '%s' "$ids" | grep -c .)" -le 1 ] || {
            echo "Several Developer ID certificates; pick one with DEVELOPER_ID=\"...\":" >&2; echo "$ids" >&2; exit 1; }
        DEVELOPER_ID=$ids
    fi
    [ -n "$DEVELOPER_ID" ] || return 0
    TEAM_ID=$(echo "$DEVELOPER_ID" | sed -n 's/.*(\([A-Z0-9]*\))$/\1/p')
    [ -n "$TEAM_ID" ] || { echo "No team ID in \"$DEVELOPER_ID\"." >&2; exit 1; }
    # Checked before the build, not after a long one.
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || {
        echo "No notarization profile \"$NOTARY_PROFILE\": run" >&2
        echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <email> --team-id $TEAM_ID" >&2; exit 1; }
}

# xcodebuild re-signs Sparkle.framework but not the helpers inside it, which keep
# Sparkle's ad hoc signature, and notarization rejects any unsigned nested code.
# Inside out, as Sparkle's docs list them.
sign_app() {
    local app=$1 identity=$2 flags=(--force --options runtime)
    [ "$identity" = - ] || flags+=(--timestamp)
    local sparkle=$app/Contents/Frameworks/Sparkle.framework/Versions/B
    codesign "${flags[@]}" --sign "$identity" "$sparkle/XPCServices/Installer.xpc"
    codesign "${flags[@]}" --sign "$identity" --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
    codesign "${flags[@]}" --sign "$identity" "$sparkle/Autoupdate"
    codesign "${flags[@]}" --sign "$identity" "$sparkle/Updater.app"
    codesign "${flags[@]}" --sign "$identity" "$app/Contents/Frameworks/Sparkle.framework"
    codesign "${flags[@]}" --sign "$identity" --entitlements App/Orbit.entitlements "$app"
    codesign --verify --deep --strict "$app"
}

notarize() {
    local zip=$1 result id status
    echo "Notarizing (usually a few minutes)..."
    result=$(xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)
    id=$(echo "$result" | plutil -extract id raw -o - -)
    status=$(echo "$result" | plutil -extract status raw -o - -)
    if [ "$status" != Accepted ]; then
        echo "Notarization: $status. Apple's log:" >&2
        xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2
        exit 1
    fi
}

# The build opens a scratch project with files in tabs and has to last (D242):
# 0.4.0 crashed seconds after launch on macOS 27 and couldn't update itself.
# SKIP_SMOKE=1 skips it. `make stress` goes much further, on a debug build (D243).
smoke_test() {
    local app=$1
    [ -z "${SKIP_SMOKE:-}" ] || { echo "warning: launch check skipped" >&2; return; }
    orbit_scratch
    # A copy with its own bundle id and settings, so it runs beside Orbit itself.
    local demo=$ORBIT_SCRATCH/demo crashes copy=$ORBIT_SCRATCH/OrbitCheck.app
    export ORBIT_DOMAIN=dev.orbit.app.check
    orbit_side_copy "$app" "$copy" "$ORBIT_DOMAIN"
    mkdir -p "$demo/src"
    # Shorter than the window, like the file 0.4.0 crashed on.
    for i in $(seq 1 48); do echo "export const item$i = { id: $i, title: 'Item $i' }"; done > "$demo/src/short.ts"
    for i in $(seq 1 400); do echo "let value$i = $i // a line long enough to need a horizontal scroll bar in a narrow window"; done > "$demo/src/long.swift"
    orbit_use_prefs "$demo" src/short.ts src/long.swift src/short.ts
    crashes=$(orbit_crash_reports)
    echo "Launch check: opening a project in the build for 30 s…"
    "$copy/Contents/MacOS/Orbit" >/dev/null 2>&1 &
    local pid=$! cpu=0
    sleep 30
    if kill -0 "$pid" 2>/dev/null; then
        cpu=$(ps -o %cpu= -p "$pid" | tr -d ' ')
        kill "$pid"
        wait "$pid" 2>/dev/null || true
    else
        echo "error: the build quit within 30 s of opening a project ($(orbit_newest_crash_report))" >&2
        exit 1
    fi
    # LaunchGuard clears its key once the launch has lasted.
    if defaults read "$ORBIT_DOMAIN" orbit.unfinishedLaunches >/dev/null 2>&1; then
        echo "error: the build didn't settle after launch (LaunchGuard's key is still set)" >&2; exit 1
    fi
    if [ "$(orbit_crash_reports)" != "$crashes" ]; then
        echo "error: a new Orbit crash report appeared during the launch check" >&2; exit 1
    fi
    # A layout loop spins at 100% until AppKit gives up.
    if [ "${cpu%.*}" -ge 50 ]; then echo "error: the build used ${cpu}% CPU sitting idle" >&2; exit 1; fi
    echo "Launch check passed (idle at ${cpu}% CPU)"
}

case "$command" in
setup)
    resolve_sparkle
    # Makes the key pair once; later runs only print the public half.
    "$SPARKLE_BIN/generate_keys" >/dev/null
    key=$("$SPARKLE_BIN/generate_keys" -p)
    /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $key" App/Info.plist
    echo "Public key written to App/Info.plist: $key"
    echo "Commit it. The private key stays in this Mac's login keychain; back it up with"
    echo "  $SPARKLE_BIN/generate_keys -x sparkle-private-key  (and keep that file out of git)."
    ;;
build)
    [ -n "$version" ] || { echo "usage: $0 build <version>" >&2; exit 1; }
    [ -n "$(public_key)" ] || { echo "No update key yet: run 'make release-setup' first." >&2; exit 1; }
    if [ -n "$(git status --porcelain)" ]; then echo "warning: uncommitted changes go into this build" >&2; fi
    find_developer_id
    build_number=$(git rev-list --count HEAD)
    sign=(CODE_SIGN_IDENTITY=- ENABLE_HARDENED_RUNTIME=NO)
    if [ -n "${DEVELOPER_ID:-}" ]; then
        echo "Signing with $DEVELOPER_ID"
        sign=(CODE_SIGN_IDENTITY="$DEVELOPER_ID" DEVELOPMENT_TEAM="$TEAM_ID" ENABLE_HARDENED_RUNTIME=YES
              CODE_SIGN_ENTITLEMENTS=App/Orbit.entitlements OTHER_CODE_SIGN_FLAGS=--timestamp)
    fi
    xcodegen generate --quiet
    xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Release -derivedDataPath "$DERIVED" \
        -skipPackagePluginValidation -quiet \
        MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number" "${sign[@]}" build
    app=$DERIVED/Build/Products/Release/Orbit.app
    out=.build/release/$version
    rm -rf "$out" && mkdir -p "$out"
    zip=$out/Orbit-$version.zip
    [ -z "${DEVELOPER_ID:-}" ] || sign_app "$app" "$DEVELOPER_ID"
    smoke_test "$app"
    ditto -c -k --keepParent "$app" "$zip"
    if [ -n "${DEVELOPER_ID:-}" ]; then
        notarize "$zip"
        xcrun stapler staple "$app"
        spctl --assess --type execute "$app"
        rm "$zip" && ditto -c -k --keepParent "$app" "$zip"
    else
        echo "warning: ad hoc signed (no Developer ID certificate): macOS asks on the first launch" >&2
    fi
    # Signs the archive with the keychain's private key; the newest release is all Sparkle needs.
    "$SPARKLE_BIN/generate_appcast" --download-url-prefix "https://github.com/$REPO/releases/download/v$version/" \
        --link "https://github.com/$REPO" -o "$out/appcast.xml" "$out"
    echo "Built $zip (build $build_number) and $out/appcast.xml"
    echo "Publish with: make release-publish VERSION=$version"
    ;;
smoke)
    [ -d "${2:-}" ] || { echo "usage: $0 smoke <Orbit.app>" >&2; exit 1; }
    smoke_test "$2"
    ;;
publish)
    [ -n "$version" ] || { echo "usage: $0 publish <version>" >&2; exit 1; }
    out=.build/release/$version
    [ -f "$out/appcast.xml" ] || { echo "Build it first: make release VERSION=$version" >&2; exit 1; }
    gh release create "v$version" "$out/Orbit-$version.zip" "$out/appcast.xml" \
        --repo "$REPO" --target "$(git rev-parse HEAD)" --title "Orbit $version" --generate-notes
    # On master: a run for the release's tag can't deploy to Pages (D228).
    gh workflow run site.yml --repo "$REPO" --ref master
    echo "Rebuilding the site; after editing the notes: gh workflow run site.yml --ref master"
    ;;
*)
    sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
