#!/usr/bin/env python3
"""Converts Zed's languages into Orbit's grammar table (D71).

Reads, at pinned commits:
  - Zed's own languages (`crates/grammars/src/*/config.toml`) and the grammar
    crates its Cargo.toml / Cargo.lock pin (crates.io's `.cargo_vcs_info.json`
    names the commit a release was cut from);
  - the extension catalog (`zed-industries/extensions`): each extension's
    `extension.toml` (`[grammars.<name>]`: repository, commit, path) and
    `languages/*/config.toml`, at the commit the catalog's submodule points to.
    Zed's API only says which extensions provide languages and how popular
    they are (the order ties are broken in).

Zed's default settings (`assets/settings/default.json`) add `file_types`:
globs that win over a language's suffixes (`.env.*` is Env).

Writes Packages/OrbitKit/Sources/OrbitAPI/Resources/Grammars.json. Queries
stay on GitHub, fetched when a language is installed. Run with
`make import-grammars`.
"""
import io
import os
import json
import re
import subprocess
import sys
import tarfile
import threading
import tomllib
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

# Zed-internal languages, not files anyone opens.
SKIPPED_LANGUAGES = {"Zed Keybind Context"}

# Extensions whose queries name nodes their own grammar lacks (they fail in Zed too).
BROKEN_LANGUAGES = {"Ferret", "Ayla"}


def git(*arguments, cwd=None):
    return subprocess.run(["git", *arguments], cwd=cwd, check=True, capture_output=True).stdout


FETCHING = threading.Lock()
CHECKOUTS = {}


def fetch(repository, commit, directory):
    """A checkout without large blobs: configs and queries, not parser.c.
    Extensions living in one repository (Zed's) share it."""
    with FETCHING:
        lock = CHECKOUTS.setdefault(directory, threading.Lock())
    with lock:
        if not (directory / "fetched").exists():
            directory.mkdir(parents=True, exist_ok=True)
            git("init", "-q", cwd=directory)
            git("fetch", "-q", "--depth", "1", "--filter=blob:limit=256k", repository, commit, cwd=directory)
            (directory / "fetched").touch()
    return directory


def show(directory, path):
    try:
        return git("show", f"FETCH_HEAD:{path}", cwd=directory).decode()
    except subprocess.CalledProcessError:
        return None


def files(directory):
    return git("ls-tree", "-r", "--name-only", "FETCH_HEAD", cwd=directory).decode().splitlines()


def symlinks(directory):
    """Path → where it points, for the symlinks in a checkout (queries shared between languages)."""
    links = {}
    for line in git("ls-tree", "-r", "FETCH_HEAD", cwd=directory).decode().splitlines():
        meta, path = line.split("\t", 1)
        if meta.startswith("120000"):
            links[path] = show(directory, path).strip()
    return links


def resolved(path, links):
    """Follows symlinks: raw.githubusercontent.com serves a link's target path, not the file."""
    for _ in range(8):
        if path not in links:
            return path
        path = str(Path(os.path.normpath(Path(path).parent / links[path])))
    return path


def download(url):
    request = urllib.request.Request(url, headers={"User-Agent": "orbit-import-grammars"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


def github_raw(repository, commit, path):
    match = re.match(r"https://github\.com/([^/]+)/([^/]+?)(?:\.git)?/?$", repository)
    if not match:
        return None
    return f"https://raw.githubusercontent.com/{match[1]}/{match[2]}/{commit}/{urllib.parse.quote(path)}"


def reachable(url):
    request = urllib.request.Request(url, method="HEAD", headers={"User-Agent": "orbit-import-grammars"})
    try:
        with urllib.request.urlopen(request, timeout=30):
            return True
    except Exception:
        return False


def fetchable(repository, commit, work):
    """Whether the commit can be fetched: crates may name commits never pushed, repositories vanish."""
    directory = work / "verify" / re.sub(r"\W", "_", repository + commit)
    directory.mkdir(parents=True, exist_ok=True)
    try:
        git("init", "-q", cwd=directory)
        git("fetch", "-q", "--depth", "1", "--filter=tree:0", repository, commit, cwd=directory)
        return True
    except subprocess.CalledProcessError:
        return False


def tagged_commit(repository, version):
    """The commit a release tag points to (`v0.24.2` or `0.24.2`)."""
    for tag in (f"v{version}", version):
        try:
            lines = git("ls-remote", repository, f"refs/tags/{tag}", f"refs/tags/{tag}^{{}}").decode().splitlines()
        except subprocess.CalledProcessError:
            continue
        refs = dict(reversed(line.split("\t")) for line in lines)
        commit = refs.get(f"refs/tags/{tag}^{{}}") or refs.get(f"refs/tags/{tag}")
        if commit:
            return commit
    return None


def normalized(repository):
    return re.sub(r"\.git$", "", repository.rstrip("/"))


def slug(name):
    """A folder name: `C++` → `cpp`, `Vue.js` → `vue-js`."""
    name = name.lower().replace("+", "p").replace("#", "sharp")
    return re.sub(r"-+", "-", re.sub(r"[^a-z0-9]", "-", name)).strip("-")


def language_entry(config, highlights, injections):
    entry = {
        "name": config["name"],
        "grammar": config.get("grammar"),
        "suffixes": config.get("path_suffixes", []),
        "highlights": highlights,
    }
    if injections:
        entry["injections"] = injections
    if "first_line_pattern" in config:
        entry["firstLine"] = config["first_line_pattern"]
    # Editing: ⌘/ and auto-closed brackets (D73).
    comments = config.get("line_comments") or ([config["line_comment"]] if isinstance(config.get("line_comment"), str) else [])
    if comments:
        entry["lineComments"] = comments
    block = config.get("block_comment")
    if isinstance(block, dict) and "start" in block and "end" in block:
        entry["blockComment"] = [block["start"], block["end"]]
    elif isinstance(block, list) and len(block) == 2:
        entry["blockComment"] = block
    brackets = [
        {"start": b["start"], "end": b["end"]}
        for b in config.get("brackets", []) if isinstance(b, dict) and b.get("close") and "start" in b and "end" in b
    ]
    if brackets:
        entry["brackets"] = brackets
    if config.get("autoclose_before"):
        entry["autocloseBefore"] = config["autoclose_before"]
    if config.get("modeline_aliases"):
        entry["aliases"] = config["modeline_aliases"]
    return entry


# --- Zed's own languages ----------------------------------------------------------


def symbol_in_crate(lib_rs, constant):
    match = re.search(rf"pub const {constant}: LanguageFn\s*=\s*unsafe\s*\{{\s*LanguageFn::from_raw\((tree_sitter_\w+)\)", lib_rs)
    if not match:
        raise ValueError(f"no {constant} in bindings/rust/lib.rs")
    return match[1]


def grammar_folder(parsers, symbol, read):
    """The folder holding the parser that exports `symbol`, relative to the repository."""
    if len(parsers) == 1:
        return str(Path(parsers[0]).parent.parent)
    for parser in parsers:
        if re.search(rf"\b{symbol}\s*\(\s*void\s*\)", read(parser) or ""):
            return str(Path(parser).parent.parent)
    raise ValueError(f"no parser.c exports {symbol}")


def core_grammar(dependency, constant, work):
    """repository, commit, path and symbol of a grammar crate Zed depends on."""
    if "git" in dependency:
        repository, commit = normalized(dependency["git"]), dependency["rev"]
        checkout = work / "core" / re.sub(r"\W", "_", repository + commit)
        if not (checkout / ".git").exists():
            checkout.mkdir(parents=True)
            git("init", "-q", cwd=checkout)
            git("fetch", "-q", "--depth", "1", repository, commit, cwd=checkout)
        listing = files(checkout)
        lib = next(path for path in listing if path.endswith("bindings/rust/lib.rs"))
        symbol = symbol_in_crate(show(checkout, lib), constant)
        parsers = [path for path in listing if path.endswith("src/parser.c")]
        folder = grammar_folder(parsers, symbol, lambda path: show(checkout, path))
        return {"repository": repository, "commit": commit, "path": None if folder == "." else folder, "symbol": symbol}

    name, version = dependency["package"], dependency["version"]
    crate = tarfile.open(fileobj=io.BytesIO(download(f"https://static.crates.io/crates/{name}/{name}-{version}.crate")))
    prefix = f"{name}-{version}/"

    def read(path):
        try:
            return crate.extractfile(prefix + path).read().decode()
        except (KeyError, AttributeError):
            return None

    vcs = json.loads(read(".cargo_vcs_info.json"))
    manifest = tomllib.loads(read("Cargo.toml"))
    repository = normalized(manifest["package"]["repository"])
    symbol = symbol_in_crate(read("bindings/rust/lib.rs"), constant)
    parsers = [member.name[len(prefix):] for member in crate.getmembers() if member.name.endswith("src/parser.c")]
    folder = str(Path(vcs.get("path_in_vcs", "")) / grammar_folder(parsers, symbol, read))
    return {
        "repository": repository, "commit": vcs["git"]["sha1"], "path": None if folder == "." else folder, "symbol": symbol,
        "version": version, "crate": f"https://static.crates.io/crates/{name}/{name}-{version}.crate", "inCrate": str(Path(folder).relative_to(vcs.get("path_in_vcs", ""))),
    }


def zed_languages(zed, commit, work):
    workspace = tomllib.loads((zed / "Cargo.toml").read_text())["workspace"]["dependencies"]
    lock = {}
    for package in tomllib.loads((zed / "Cargo.lock").read_text())["package"]:
        lock.setdefault(package["name"], []).append(package["version"])
    registered = re.findall(
        r'\(\s*"([\w-]+)",\s*(tree_sitter_\w+)::(\w+)\.into\(\),?\s*\)',
        (zed / "crates/grammars/src/grammars.rs").read_text(),
    )
    grammars = {}
    for grammar, crate, constant in registered:
        key = next(key for key in workspace if key.replace("-", "_") == crate)
        dependency = workspace[key]
        dependency = {"version": dependency} if isinstance(dependency, str) else dict(dependency)
        if "git" not in dependency:
            dependency["package"] = dependency.get("package", key)
            requirement = dependency["version"].lstrip("^=~")
            versions = lock[dependency["package"]]
            dependency["version"] = next((v for v in versions if v.startswith(requirement)), versions[0])
        grammars[grammar] = core_grammar(dependency, constant, work)

    languages = []
    for config_path in sorted((zed / "crates/grammars/src").glob("*/config.toml")):
        config = tomllib.loads(config_path.read_text())
        if config["name"] in SKIPPED_LANGUAGES or config.get("grammar") not in grammars:
            continue
        folder = config_path.parent

        def url(name):
            path = folder / name
            if not path.exists():
                return None
            relative = os.path.relpath(path.resolve(), zed.resolve())
            return f"https://raw.githubusercontent.com/zed-industries/zed/{commit}/{relative}"

        if url("highlights.scm"):
            languages.append(language_entry(config, url("highlights.scm"), url("injections.scm")))
    return languages, grammars


def jsonc(text):
    """JSON with comments and trailing commas, as Zed's settings are."""
    text = re.sub(r'("(?:\\.|[^"\\])*")|//[^\n]*|/\*.*?\*/', lambda m: m.group(1) or "", text, flags=re.S)
    return json.loads(re.sub(r",(\s*[}\]])", r"\1", text))


def add_file_types(languages, default_settings):
    """Zed's default `file_types` (language name → globs) onto the languages."""
    file_types = jsonc(Path(default_settings).read_text()).get("file_types", {})
    for language in languages:
        if language["name"] in file_types:
            language["fileTypes"] = file_types[language["name"]]


# --- The extension catalog --------------------------------------------------------


def catalog_extensions(catalog):
    entries = tomllib.loads((catalog / "extensions.toml").read_text())
    urls = dict(re.findall(r'path = (\S+)\s+url = (\S+)', (catalog / ".gitmodules").read_text()))
    commits = {}
    for line in git("ls-tree", "HEAD", "extensions/", cwd=catalog).decode().splitlines():
        meta, path = line.split("\t")
        mode, kind, sha = meta.split()
        if kind == "commit":
            commits[path] = sha
    extensions = {}
    for id, entry in entries.items():
        submodule = entry["submodule"]
        if submodule in urls and submodule in commits:
            extensions[id] = {"repository": normalized(urls[submodule]), "commit": commits[submodule], "path": entry.get("path", "")}
    return extensions


def extension_languages(id, extension, work):
    checkout = fetch(extension["repository"], extension["commit"], work / "extensions" / re.sub(r"\W", "_", extension["repository"] + extension["commit"]))
    root = extension["path"].strip("/")
    prefix = root + "/" if root else ""
    manifest_text = show(checkout, prefix + "extension.toml")
    if manifest_text is None:
        return [], {}, "no extension.toml"
    manifest = tomllib.loads(manifest_text)
    grammars = {}
    for name, grammar in manifest.get("grammars", {}).items():
        commit = grammar.get("commit") or grammar.get("rev")
        if "repository" not in grammar or not commit:
            continue
        grammars[name] = {
            "repository": normalized(grammar["repository"]),
            "commit": commit,
            "path": grammar.get("path"),
            "symbol": "tree_sitter_" + name.replace("-", "_"),
        }
    every = set(files(checkout))
    links = symlinks(checkout)
    listing = [path[len(prefix):] for path in every if path.startswith(prefix)]
    folders = manifest.get("languages") or sorted({str(Path(path).parent) for path in listing if re.fullmatch(r"languages/[^/]+/config\.toml", path)})

    def url(path):
        path = resolved(prefix + path, links)
        return github_raw(extension["repository"], extension["commit"], path) if path in every else None

    languages = []
    for folder in folders:
        folder = folder.strip("/")
        config_text = show(checkout, resolved(f"{prefix}{folder}/config.toml", links))
        highlights = url(f"{folder}/highlights.scm")
        if config_text is None or highlights is None:
            continue
        config = tomllib.loads(config_text)
        if config.get("grammar") in grammars and config["name"] not in BROKEN_LANGUAGES:
            languages.append(language_entry(config, highlights, url(f"{folder}/injections.scm")))
    return languages, grammars, None if languages else "no language with a grammar and highlights"


def main():
    zed, zed_commit, catalog, catalog_commit, work, output = sys.argv[1:7]
    zed, catalog, work = Path(zed), Path(catalog), Path(work)

    languages, grammars = zed_languages(zed, zed_commit, work)
    names = {slug(language["name"]) for language in languages}

    popular = json.loads(download("https://api.zed.dev/extensions?provides=languages&max_schema_version=1"))["data"]
    popular.sort(key=lambda extension: -extension.get("download_count", 0))
    extensions = catalog_extensions(catalog)
    wanted = [extension["id"] for extension in popular if extension["id"] in extensions]

    with ThreadPoolExecutor(16) as pool:
        results = list(pool.map(lambda id: (id, *safe(extension_languages, id, extensions[id], work)), wanted))

    skipped = {}
    for id, found, found_grammars, problem in results:
        if problem:
            skipped[id] = problem
        for language in found:
            if slug(language["name"]) in names:
                continue
            name = language["grammar"]
            grammar = found_grammars[name]
            key = name
            # Two extensions may build different grammars under one name.
            if key in grammars and {k: grammars[key][k] for k in ("repository", "commit", "path")} != {k: grammar[k] for k in ("repository", "commit", "path")}:
                key = f"{name}@{id}"
            grammars.setdefault(key, grammar)
            language["grammar"] = key
            language["extension"] = id
            languages.append(language)
            names.add(slug(language["name"]))

    # What the app would fetch must be there: the grammar's commit and the queries.
    with ThreadPoolExecutor(16) as pool:
        def verify(item):
            key, grammar = item
            if fetchable(grammar["repository"], grammar["commit"], work):
                return key, True
            commit = grammar.get("version") and tagged_commit(grammar["repository"], grammar["version"])
            if commit and fetchable(grammar["repository"], commit, work):
                grammar["commit"] = commit
                return key, True
            if "crate" in grammar:
                # The repository moved or the commit was never pushed; the published crate stays.
                path = grammar["inCrate"]
                grammar.update(archive=grammar["crate"], commit=grammar["version"], path=None if path == "." else path)
                return key, True
            return key, False

        used = {language["grammar"] for language in languages}
        broken = {key for key, ok in pool.map(verify, [(key, grammars[key]) for key in used]) if not ok}
        urls = sorted({url for language in languages for url in (language["highlights"], language.get("injections")) if url})
        missing = {url for url, ok in zip(urls, pool.map(reachable, urls)) if not ok}
    for language in languages:
        if language["grammar"] in broken:
            skipped[language["name"]] = f"grammar {grammars[language['grammar']]['repository']} isn't fetchable at its commit"
        elif {language["highlights"], language.get("injections")} & missing:
            skipped[language["name"]] = "queries aren't reachable"
    languages = [language for language in languages if language["name"] not in skipped]
    add_file_types(languages, zed / "assets/settings/default.json")
    for grammar in grammars.values():
        for field in ("version", "crate", "inCrate"):
            grammar.pop(field, None)

    ids = set()
    for language in languages:
        id, number = slug(language["name"]), 2
        while id in ids:
            id, number = f"{slug(language['name'])}-{number}", number + 1
        ids.add(id)
        language["id"] = id
    used = {language["grammar"] for language in languages}
    document = {
        "source": {
            "zed": f"https://github.com/zed-industries/zed/tree/{zed_commit}/crates/grammars/src",
            "extensions": f"https://github.com/zed-industries/extensions/tree/{catalog_commit}",
        },
        "license": "Each grammar and query keeps its repository's license; nothing of theirs is bundled, only where to fetch it",
        "languages": languages,
        "grammars": {key: {k: v for k, v in grammar.items() if v is not None} for key, grammar in sorted(grammars.items()) if key in used},
    }
    Path(output).write_text(json.dumps(document, indent=1, ensure_ascii=False) + "\n")
    print(f"{len(languages)} languages, {len(used)} grammars; {len(skipped)} extensions or languages left out")
    for id, reason in sorted(skipped.items()):
        print(f"  {id}: {reason}")


def safe(function, *arguments):
    try:
        return function(*arguments)
    except Exception as error:  # one broken extension doesn't stop the import
        return [], {}, f"{type(error).__name__}: {error}".splitlines()[0][:200]


if __name__ == "__main__":
    main()
