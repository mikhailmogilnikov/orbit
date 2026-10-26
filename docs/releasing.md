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
- **Code signing** is ad hoc until a Developer ID is set up (below): macOS asks once,
  on the first launch of a downloaded copy (since macOS 15 right-click →
  Open no longer gets past it: System Settings → Privacy & Security →
  Open Anyway). Updates installed by Sparkle don't ask again.
- **Debug builds never update** themselves, and neither does any build
  while `SUPublicEDKey` is empty.
- **Updates install only in Applications.** Sparkle can't swap an app in an
  iCloud-synced folder (Desktop, Documents, often Downloads), so a Release
  build launched elsewhere offers to move itself first (D221).

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
   make stress-full
   make release VERSION=0.2.0
   ```
   `make stress-full` (about 10 minutes, the first time longer: the macOS 26
   VM gets the Command Line Tools) runs the stress run longer, with `leaks`,
   and on macOS 26; when it passes it stamps the code it ran, and `make
   release` refuses code that changed since (docs, the site, the README and
   the scripts don't count) (D246, D247). `SKIP_STRESS=1` builds without.
   Output: `.build/release/0.2.0/Orbit-0.2.0.zip` and
   `.build/release/0.2.0/appcast.xml`. The app itself is at
   `.build/xcode/Build/Products/Release/Orbit.app`. The keychain may ask
   for access to the signing key. Before zipping, a copy of the build (its
   own bundle id and settings, beside the Orbit you use) opens a scratch
   project for 30 s, and the release stops if it quits, crashes, doesn't
   settle or spins the CPU (D242). `scripts/release.sh smoke <Orbit.app>` runs the
   same check on any build; `SKIP_SMOKE=1` skips it.
4. **Check the build.** Unzip the archive somewhere outside the repo,
   open the app (the first time: Privacy & Security → Open Anyway), and try what changed.
   `appcast.xml` should name the right version, build number and download
   URL (`…/releases/download/v0.2.0/Orbit-0.2.0.zip`).
5. **Push and publish:**
   ```bash
   git push origin master
   make release-publish VERSION=0.2.0
   ```
   Creates the GitHub release `v0.2.0` at the current commit (tagging it),
   uploads both files and generates release notes: the pull requests merged
   since the previous release, grouped by label (`.github/release.yml`),
   and a link to the full diff. Commits pushed straight to `master` aren't
   listed, so write a human summary on GitHub afterwards. Needs `gh` logged in.
   It also starts the site's build on `master` (the changelog and download
   link come from the releases, D228); after editing the notes, rebuild it
   once more:
   ```bash
   gh workflow run site.yml --ref master
   ```
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
- **It crashes at launch:** it can't update itself (an update installs on
  quit, and it doesn't live long enough to download one). Since D242 the
  launch after a crash is a safe start, where Check for Updates works;
  versions before 0.4.1 need the new zip downloaded by hand. Say how in the
  fixed release's notes (see 0.4.1's).

## Builds

- **Apple Silicon only** at the moment (`sparkle:hardwareRequirements` is
  `arm64` in the appcast). Intel Macs can't run these builds.
- **macOS 26 or later** (the deployment target); the appcast says so too,
  so older systems aren't offered the update.
- The Release build runs `xcodegen` first, like every build: edit
  `project.yml`, never the generated project.

## Developer ID and notarization

With an Apple Developer Program membership, releases are signed with a
Developer ID and notarized, so macOS opens downloaded copies without
asking. Not set up yet; once the two steps below are done, nothing else
changes (same key, same appcast, same commands, D222).

1. Create a **Developer ID Application** certificate (only the account
   holder can) in Xcode → Settings → Accounts → Manage Certificates → + →
   Developer ID Application. It lands in the login keychain; check:
   `security find-identity -v -p codesigning`.
2. Store notarization credentials once (an app-specific password from
   account.apple.com → Sign-In and Security → App-Specific Passwords; the
   team ID is in the certificate's name):
   ```bash
   xcrun notarytool store-credentials orbit-notary --apple-id <email> --team-id <TEAMID>
   ```

From then on `make release VERSION=0.3.0` finds the certificate and:
builds with the hardened runtime and `App/Orbit.entitlements` (library
validation off: grammar dylibs are compiled on the user's Mac, D71), signs
Sparkle's helpers, the framework and the app, submits the zip to Apple's
notary service and waits (a few minutes), staples the ticket, checks it
with Gatekeeper and zips it again. A rejection stops the build and prints
Apple's log. `DEVELOPER_ID="Developer ID Application: Name (TEAMID)"`
picks one of several certificates, `AD_HOC=1` makes an ad hoc build anyway,
`NOTARY_PROFILE` overrides the profile name.

Copies installed from ad hoc builds update to a Developer ID build through
Sparkle as usual: it checks the EdDSA signature, not the code signature.
Once a notarized build is out, the first-launch steps (Open Anyway) in the
README and the site's FAQ can go.

## Troubleshooting

- **"No update key yet"** — `make release-setup` hasn't run on this clone
  (`SUPublicEDKey` is empty).
- **generate_appcast can't find the key** — the build runs on a Mac
  without the private key in its keychain; import the backup.
- **The update downloads but fails to install** — the archive was signed
  with a different key than the one in the installed app's `Info.plist`.
- **Check for Updates… is greyed out** — a Debug build, or a build made
  before the key was set up.
