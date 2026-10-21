# Orbit's website

Astro, plain CSS, no UI framework (D216 in `docs/decisions.md`).

```bash
pnpm install
pnpm dev      # http://localhost:4321
pnpm build    # dist/
pnpm check    # types
```

The pages read the repo at build time, so run them from `site/` with the rest of the repo next
to it:

| Page | From |
| --- | --- |
| `/extensions` | `docs/extensions.md` |
| `/roadmap` | `docs/roadmap.md` (all but "Done") |
| `/shortcuts` | the `OrbitCommand` registrations in `App/` and `Packages/OrbitKit/Sources` |
| `/changelog`, download links | GitHub Releases (set `GITHUB_TOKEN` if the API rate-limits the build) |
| `/numbers`, the home page's bars | `src/data/numbers.json` |

## The numbers

`bench/run.sh` opens Orbit, Zed, VS Code and Cursor on `bench/demo` a few times each and prints
one line per run; it takes ~20 minutes and opens windows, so leave the Mac alone. Then:

```bash
bench/run.sh > results.tsv
node bench/summarize.mjs results.tsv
```

`ORBIT=/path/to/Orbit.app` measures a build other than `/Applications/Orbit.app`.

## The link preview

`public/og.jpg` is `og/card.html` rendered by `og/render.sh` (Chrome and ImageMagick): the home
page's hero at card size. Edit the HTML, then rerun the script.

## Deploying

GitHub Pages, by `.github/workflows/site.yml`: on a push to `master` that touches the site, the docs
or the Swift sources, and on every release. The build reads `../docs` and `../Packages`, so the
whole repository has to be checked out.
