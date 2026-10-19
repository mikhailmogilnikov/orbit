#!/bin/bash
# Builds a release of Orbit and its Sparkle appcast (D129):
#   scripts/release.sh setup            once: the update signing key (private half in the keychain)
#   scripts/release.sh build 0.2.0      Release build → .build/release/0.2.0/{Orbit-0.2.0.zip, appcast.xml}
#   scripts/release.sh publish 0.2.0    a GitHub release v0.2.0 with both files
#
# Signing is ad hoc unless DEVELOPER_ID ("Developer ID Application: Name (TEAMID)")
# and TEAM_ID are set: then the build is hardened, notarized with the keychain
# profile NOTARY_PROFILE (default "orbit-notary", made once with
# `xcrun notarytool store-credentials orbit-notary`) and stapled.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO=mikhailmogilnikov/orbit
DERIVED=.build/xcode
SPARKLE_BIN=$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin
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
    build_number=$(git rev-list --count HEAD)
    sign=(CODE_SIGN_IDENTITY=- ENABLE_HARDENED_RUNTIME=NO)
    if [ -n "${DEVELOPER_ID:-}" ]; then
        [ -n "${TEAM_ID:-}" ] || { echo "DEVELOPER_ID needs TEAM_ID too." >&2; exit 1; }
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
    ditto -c -k --keepParent "$app" "$zip"
    if [ -n "${DEVELOPER_ID:-}" ]; then
        xcrun notarytool submit "$zip" --keychain-profile "${NOTARY_PROFILE:-orbit-notary}" --wait
        xcrun stapler staple "$app"
        rm "$zip" && ditto -c -k --keepParent "$app" "$zip"
    fi
    # Signs the archive with the keychain's private key; the newest release is all Sparkle needs.
    "$SPARKLE_BIN/generate_appcast" --download-url-prefix "https://github.com/$REPO/releases/download/v$version/" \
        --link "https://github.com/$REPO" -o "$out/appcast.xml" "$out"
    echo "Built $zip (build $build_number) and $out/appcast.xml"
    echo "Publish with: make release-publish VERSION=$version"
    ;;
publish)
    [ -n "$version" ] || { echo "usage: $0 publish <version>" >&2; exit 1; }
    out=.build/release/$version
    [ -f "$out/appcast.xml" ] || { echo "Build it first: make release VERSION=$version" >&2; exit 1; }
    gh release create "v$version" "$out/Orbit-$version.zip" "$out/appcast.xml" \
        --repo "$REPO" --target "$(git rev-parse HEAD)" --title "Orbit $version" --generate-notes
    ;;
*)
    sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
