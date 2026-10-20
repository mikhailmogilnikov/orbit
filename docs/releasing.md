# Releasing Orbit

How a version of Orbit is built, checked and published, and how installed
copies update themselves. The reasoning behind it is in D129
(`decisions.md`); the script is `scripts/release.sh`.

## How it fits together

- **Builds** are Release builds of `Orbit.app`, zipped with `ditto`.
- **Hosting** is GitHub Releases of `mikhailmogilnikov/orbit` (a public
  repo). Each release carries two files: `Orbit-<version>.zip` and
  `appcast.xml`.
- **Updates** come through [Sparkle](https://sparkle-project.org) 2.10.0
  (pinned in `project.yml`). The app reads
  `https://github.com/mikhailmogilnikov/orbit/releases/latest/download/appcast.xml`,
  so the newest release's appcast is always the one used. It checks once
  a day on its own; **Orbit → Check for Updates…** checks right away.
- **Update signing**: every zip is signed with an EdDSA key. The public
  half is `SUPublicEDKey` in `App/Info.plist`; the private half lives only
  in the login keychain of the Mac that made it. Sparkle refuses an update
  whose signature doesn't match.
- **Code signing** is ad hoc for now (no Developer ID): macOS asks once,
  on the first launch of a downloaded copy (right-click → Open). Updates
  installed by Sparkle don't ask again.
- **Debug builds never update** themselves, and neither does any build
  while `SUPublicEDKey` is empty.

## One-time setup (done)

```bash
make release-setup
```

Creates the key pair (the keychain asks for access), and writes the public
key into `App/Info.plist`. Running it again only prints the existing key.

**Back up the private key.** Without it, no future update can be signed,
and installed copies can only be updated by downloading a new build by
hand. Export it and keep the file somewhere safe, never in the repo:

```bash
.build/xcode/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x ~/sparkle-private-key
```

On another Mac, import it with `generate_keys -f <file>`.

## Making a release

1. **Pick the version.** Semantic: `0.2.0`, `0.2.1` for fixes, `0.3.0`
   for features. The build number is set automatically to the number of
   commits on the current branch, so it always grows — Sparkle compares
   build numbers, not version strings.
2. **Commit everything.** The script warns about uncommitted changes, since
   they'd end up in the build without being in any commit.
   If a dependency changed since the last release, run
   `make acknowledgements` first: the licenses in About Orbit come from it (D207).
3. **Build:**
   ```bash
   make release VERSION=0.2.0
   ```
   Output: `.build/release/0.2.0/Orbit-0.2.0.zip` and
   `.build/release/0.2.0/appcast.xml`. The app itself is at
   `.build/xcode/Build/Products/Release/Orbit.app`. The keychain may ask
   for access to the signing key.
4. **Check the build.** Unzip the archive somewhere outside the repo,
   open the app (right-click → Open the first time), and try what changed.
   `appcast.xml` should name the right version, build number and download
   URL (`…/releases/download/v0.2.0/Orbit-0.2.0.zip`).
5. **Push and publish:**
   ```bash
   git push origin master
   make release-publish VERSION=0.2.0
   ```
   Creates the GitHub release `v0.2.0` at the current commit (tagging it),
   uploads both files and writes release notes from the commits since the
   previous release. Needs `gh` logged in. Edit the notes on GitHub
   afterwards if they need a human summary.
6. **Check the update.** On a Mac with the previous version installed,
   **Check for Updates…** should offer the new one, then install and
   relaunch.

## Fixing a bad release

- **Wrong files, not yet installed by anyone:** delete the release and its
  tag on GitHub (`gh release delete v0.2.0 --cleanup-tag`), fix, and
  publish again under the same version.
- **Already installed somewhere:** don't reuse the version. Publish a new
  one (`0.2.1`); its higher build number makes Sparkle offer it.
- **Rolling back:** Sparkle never offers a lower build number. To go back,
  release the old code again under a new version.

## Builds

- **Apple Silicon only** at the moment (`sparkle:hardwareRequirements` is
  `arm64` in the appcast). Intel Macs can't run these builds.
- **macOS 26 or later** (the deployment target); the appcast says so too,
  so older systems aren't offered the update.
- The Release build runs `xcodegen` first, like every build: edit
  `project.yml`, never the generated project.

## Later: Developer ID and notarization

With an Apple Developer Program membership, releases can be signed with a
Developer ID and notarized, so macOS opens downloaded copies without
asking. The script already supports it; nothing else changes (same key,
same appcast, same commands).

1. Create a **Developer ID Application** certificate in the Apple
   Developer account and install it in the login keychain. Check that it's
   there: `security find-identity -v -p codesigning`.
2. Store notarization credentials once (an app-specific password from
   appleid.apple.com):
   ```bash
   xcrun notarytool store-credentials orbit-notary --apple-id <email> --team-id <TEAMID>
   ```
3. Release with the identity in the environment:
   ```bash
   DEVELOPER_ID="Developer ID Application: Name (TEAMID)" TEAM_ID=TEAMID make release VERSION=0.3.0
   ```
   This turns on the hardened runtime with `App/Orbit.entitlements`
   (library validation off: grammar dylibs are compiled on the user's Mac,
   D71), submits the zip to Apple's notary service, waits for it, staples
   the ticket to the app and zips it again. `NOTARY_PROFILE` overrides the
   profile name.

Copies installed from ad hoc builds update to a Developer ID build through
Sparkle as usual: it checks the EdDSA signature, not the code signature.

## Troubleshooting

- **"No update key yet"** — `make release-setup` hasn't run on this clone
  (`SUPublicEDKey` is empty).
- **generate_appcast can't find the key** — the build runs on a Mac
  without the private key in its keychain; import the backup.
- **The update downloads but fails to install** — the archive was signed
  with a different key than the one in the installed app's `Info.plist`.
- **Check for Updates… is greyed out** — a Debug build, or a build made
  before the key was set up.
