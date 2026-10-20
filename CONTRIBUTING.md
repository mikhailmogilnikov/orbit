# Contributing to Orbit

Thanks for wanting to help. Orbit is a small project with strong opinions
about how it looks and works, so a little context first saves everyone time.

## Before you start

- **Bugs**: open an issue with the template — macOS version, Orbit version,
  steps, and the crash report if there was one
  (`~/Library/Logs/DiagnosticReports/Orbit-*.ips`).
- **Features**: open an issue before writing code. Read
  [product.md](docs/product.md) first: some things are deliberate (for
  example, agent changes are reviewed inline in the editor — there is no
  separate review tab, D7).
- **Small fixes** (typos, obvious bugs): a pull request straight away is fine.

## Setting up

You need macOS 26, Xcode 26, XcodeGen and the Metal Toolchain:

```bash
brew install xcodegen
xcodebuild -downloadComponent MetalToolchain
make run
```

`Orbit.xcodeproj` is generated: change `project.yml`, never the project.
`cd Packages/OrbitKit && swift build` is the fastest compile check.

Read [architecture.md](docs/architecture.md) before larger changes. The short
version:

- **Everything is a plugin.** New features go into a plugin under
  `Packages/OrbitKit/Sources/` using only the public `OrbitAPI`. Plugins never
  import each other; they share functionality through services.
- **One plugin host per window.** Plugin state lives in the plugin instance,
  never in a static shared by windows, and a closed window or a plugin turned
  off frees everything it held.
- **Swift 6 strict concurrency.** UI and model types are
  `@MainActor @Observable`.
- **Native look.** Colors, corners and fonts come from `Theme` and
  `.orbitFont(_:)` in OrbitUI; actions use Liquid Glass button styles.

## Pull requests

- Keep a PR to one change, and say what it does and why. Screenshots or a
  short recording for anything visible.
- `make test` passes, and the app builds (`make build`). CI runs both.
- New product or technical decisions get an entry in
  [decisions.md](docs/decisions.md) (and its index); update
  [roadmap.md](docs/roadmap.md) when something ships.
- Code, comments, commits and docs are in English. Comments explain *why*,
  not *what*, and there aren't many of them.
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org)
  (`feat:`, `fix:`, `docs:`…), as in the history.

## Extensions

Themes, icon themes and extension packages don't need a change to Orbit at
all — see [extensions.md](docs/extensions.md) and `examples/extensions/`.

## License

By contributing, you agree that your contributions are licensed under the
[GPL-3.0](LICENSE), like the rest of Orbit. Everyone taking part follows the
[Code of Conduct](CODE_OF_CONDUCT.md).
