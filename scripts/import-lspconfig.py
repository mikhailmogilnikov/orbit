#!/usr/bin/env python3
"""Converts nvim-lspconfig's server configs into Orbit's server table (D65).

Reads, without running any of it:
  - nvim-lspconfig's `lsp/*.lua` (Apache-2.0): command, file types, root
    markers, settings, init options, as far as they are plain data;
  - Neovim's `runtime/lua/vim/filetype.lua` (Apache-2.0): which extensions and
    file names make a file type; GitHub Linguist's `languages.yml` (MIT) for
    file types Neovim only gets from plugins;
  - Mason's registry: which package installs a server, and what it needs.

Writes Packages/OrbitKit/Sources/OrbitLanguages/Resources/Servers.json.
Entries whose command isn't plain data are left out; root logic written as a
function becomes a marker group when it's a `root_pattern(...)` call, else the
open folder. Run with `make import-lspconfig`.
"""
import json
import re
import sys
from pathlib import Path

# --- A reader for Lua table literals ------------------------------------------------


class NotData(Exception):
    pass


TOKEN = re.compile(
    r"""
    (?P<space>\s+|--\[(?P<eq>=*)\[.*?\](?P=eq)\]|--[^\n]*)
  | (?P<long>\[(?P<leq>=*)\[.*?\](?P=leq)\])
  | (?P<string>"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')
  | (?P<number>-?(?:0x[0-9a-fA-F]+|\d+(?:\.\d+)?(?:[eE][-+]?\d+)?))
  | (?P<name>[A-Za-z_][A-Za-z0-9_]*)
  | (?P<op>\.\.|[{}\[\]=,;().:#+*/<>~-])
    """,
    re.S | re.X,
)


def tokens(text):
    position = 0
    out = []
    while position < len(text):
        match = TOKEN.match(text, position)
        if not match:
            raise NotData(f"can't read {text[position:position + 20]!r}")
        position = match.end()
        if match.group("space"):
            continue
        if match.group("long") is not None:
            body = re.match(r"\[(=*)\[\n?(.*)\]\1\]", match.group("long"), re.S).group(2)
            out.append(("string", body))
        elif match.group("string") is not None:
            out.append(("string", unquote(match.group("string"))))
        elif match.group("number") is not None:
            out.append(("number", match.group("number")))
        elif match.group("name") is not None:
            out.append(("name", match.group("name")))
        else:
            out.append(("op", match.group("op")))
    return out


def unquote(literal):
    body = literal[1:-1]
    escapes = {"n": "\n", "t": "\t", "\\": "\\", '"': '"', "'": "'", "r": "\r", "0": "\0"}
    return re.sub(r"\\(.)", lambda m: escapes.get(m.group(1), m.group(1)), body)


class Reader:
    def __init__(self, items):
        self.items = items
        self.index = 0

    def peek(self, offset=0):
        index = self.index + offset
        return self.items[index] if index < len(self.items) else ("eof", None)

    def take(self):
        item = self.peek()
        self.index += 1
        return item

    def expect(self, kind, value=None):
        item = self.take()
        if item[0] != kind or (value is not None and item[1] != value):
            raise NotData(f"expected {value or kind}, got {item}")
        return item

    def value(self):
        kind, text = self.peek()
        if kind == "string":
            self.take()
            # `'a' .. 'b'` still is data.
            while self.peek() == ("op", ".."):
                self.take()
                other = self.value()
                if not isinstance(other, str):
                    raise NotData("concatenation")
                text += other
            return text
        if kind == "number":
            self.take()
            number = float(int(text, 16)) if text.lower().startswith(("0x", "-0x")) else float(text)
            return int(number) if number.is_integer() else number
        if kind == "name" and text in ("true", "false"):
            self.take()
            return text == "true"
        if kind == "name" and text == "nil":
            self.take()
            return None
        if (kind, text) == ("op", "{"):
            return self.table()
        if (kind, text) == ("op", "-") and self.peek(1)[0] == "number":
            self.take()
            return -self.value()
        raise NotData(f"not data: {text}")

    def table(self):
        self.expect("op", "{")
        array, record = [], {}
        while self.peek() != ("op", "}"):
            kind, text = self.peek()
            if kind == "name" and self.peek(1) == ("op", "="):
                self.take()
                self.take()
                record[text] = self.value()
            elif (kind, text) == ("op", "["):
                self.take()
                key = self.value()
                self.expect("op", "]")
                self.expect("op", "=")
                record[str(key)] = self.value()
            else:
                array.append(self.value())
            if self.peek()[1] in (",", ";"):
                self.take()
        self.expect("op", "}")
        if array and record:
            raise NotData("mixed table")
        if record:
            return {key: value for key, value in record.items() if value is not None}
        return array


def return_table(source):
    """The `return { ... }` table's fields, each as tokens (read lazily: one bad field doesn't spoil the rest)."""
    match = re.search(r"^return\s*\{", source, re.M)
    if not match:
        raise NotData("no return table")
    items = tokens(source[match.start() + len("return"):])
    fields = {}
    depth = 0
    index = 1  # past `{`
    start = None
    key = None
    while index < len(items):
        kind, text = items[index]
        if depth == 0 and key is None:
            if (kind, text) == ("op", "}"):
                break
            if kind == "name" and items[index + 1] == ("op", "="):
                key = text
                index += 2
                start = index
                continue
        if (kind, text) in (("op", "{"), ("op", "("), ("op", "[")) or (kind == "name" and text in ("function", "if", "do")):
            depth += 1
        elif (kind, text) in (("op", "}"), ("op", ")"), ("op", "]")) or (kind == "name" and text == "end"):
            if depth == 0:
                if key is not None:
                    fields[key] = items[start:index]
                break
            depth -= 1
        elif depth == 0 and (kind, text) == ("op", ",") and key is not None:
            fields[key] = items[start:index]
            key = None
        index += 1
    return fields


def data(field):
    reader = Reader(field)
    value = reader.value()
    if reader.peek()[0] != "eof":
        raise NotData("expression")
    return value


# --- File types --------------------------------------------------------------------


# Extensions Neovim decides by content, with what it answers for an ordinary file.
DETECTED = {
    "markdown": ["md", "markdown", "mkd", "mkdn", "mdwn", "mdown"], "html": ["html", "htm", "shtml"],
    "c": ["c", "h"], "cpp": ["cpp", "cc"], "objc": ["m"], "objcpp": ["mm"], "typescript": ["ts"],
    "sh": ["sh"], "bash": ["bash", "bats"], "ksh": ["ksh"], "tex": ["tex"], "sql": ["sql"],
    "terraform": ["tf"], "xml": ["xml"], "perl": ["pl", "pm", "t"], "r": ["r", "R"], "typst": ["typ"],
    "elixir": ["ex"], "d": ["d"], "fsharp": ["fs"], "fortran": ["f"], "clojure": ["edn"], "turtle": ["ttl"],
    "make": ["mk", "mak"], "diff": ["patch"], "yacc": ["y"], "text": ["txt"], "asm": ["asm", "s", "S"],
    "proto": ["pro"], "csh": ["csh", "tcsh"], "pascal": ["p"], "verilog": ["v"],
}


def normalized(name):
    return re.sub(r"[^a-z0-9]", "", name.lower())


def linguist(path):
    """Linguist's languages: normalized name or alias → (extensions, file names)."""
    out, current, key = {}, None, None
    for line in Path(path).read_text().splitlines():
        if not line or line.startswith(("#", "---")):
            continue
        if not line.startswith(" "):
            current = {"names": [line.rstrip(":").strip('"')], "extensions": [], "filenames": []}
            for name in current["names"]:
                out[normalized(name)] = current
            continue
        stripped = line.strip()
        if re.fullmatch(r"[a-z_]+:", stripped):
            key = stripped[:-1]
        elif re.fullmatch(r"[a-z_]+: .*", stripped):
            key = None
        elif stripped.startswith("- ") and key in ("extensions", "filenames", "aliases"):
            value = stripped[2:].strip('"')
            if key == "aliases":
                out.setdefault(normalized(value), current)
            else:
                current[key].append(value)
    return out


def filetypes(path, languages_yml):
    """File type → (extensions, names): Neovim's static tables, then Linguist for
    file types Neovim only knows from plugins or content (never taking an extension Neovim decides)."""
    source = Path(path).read_text()
    out = {}

    def section(name):
        begin = source.index(f"-- BEGIN {name}")
        end = source.index(f"-- END {name}")
        return source[begin:end]

    entry = re.compile(r"""^\s*(?:\[(['"])(?P<quoted>[^'"]+)\1\]|(?P<bare>[A-Za-z0-9_]+))\s*=\s*'(?P<ft>[a-z0-9_.]+)',\s*$""", re.M)
    for name, slot in (("EXTENSION", 0), ("FILENAME", 1)):
        for match in entry.finditer(section(name)):
            key = match.group("quoted") or match.group("bare")
            if slot == 1 and "/" in key:
                continue
            out.setdefault(match.group("ft"), ([], []))[slot].append(key)
    for kind, extensions in DETECTED.items():
        out.setdefault(kind, ([], []))[0].extend(extensions)
    known = set(re.findall(r"""^\s*(?:\[['"]([^'"]+)['"]\]|([A-Za-z0-9_]+))\s*=""", section("EXTENSION"), re.M))
    known = {quoted or bare for quoted, bare in known}
    return out, known, linguist(languages_yml)


def display_name(kinds, types):
    """The language a server is for, as people say it: Linguist's name for its first file type."""
    for kind in kinds:
        language = types[2].get(normalized(kind.split(".")[-1]))
        if language:
            return language["names"][0]
    return kinds[0] if kinds else ""


def files_for(kind, types):
    table, known, languages = types
    if kind in table:
        return table[kind]
    language = languages.get(normalized(kind.split(".")[-1]))
    if not language:
        return [], []
    extensions = [e.lstrip(".") for e in language["extensions"] if e.lstrip(".") not in known]
    return extensions, language["filenames"]


# --- Which server a file gets ---------------------------------------------------------

# Linters, formatters, spell checkers, assistants, and servers for one framework
# or one kind of file inside a language: never a file's language server.
NOT_A_DEFAULT = {
    # tools across many languages
    "tailwindcss", "htmx", "snyk_ls", "harper_ls", "ast_grep", "gitlab_duo", "unocss", "codebook", "ltex_plus",
    "oxfmt", "oxlint", "emmet_ls", "emmet_language_server", "wc_language_server", "dprint", "biome", "rome", "eslint",
    "vale_ls", "stylelint_lsp", "ttags", "turbo_ls", "stimulus_ls", "fallow", "textlsp", "typos_lsp", "cspell_ls",
    "grammarly", "prosemd_lsp", "quick_lint_js", "cssmodules_ls", "css_variables", "spectral", "zizmor",
    # one language's linters and formatters
    "ruff", "ruff_lsp", "pytest_language_server", "statix", "sqruff", "air", "stylua", "stylua3p_ls", "selene3p_ls",
    "rubocop", "standardrb", "tflint", "bacon_ls", "fortitude", "rumdl", "remark_ls", "panache", "golangci_lint_ls",
    "dcmls", "solc", "hdl_checker", "theme_check", "shuck", "syntax_tree",
    # frameworks and file kinds inside a language
    "djls", "djlsp", "tvm_ffi_navigator", "symfony_lsp", "glint", "ember", "lwc_ls", "antlersls", "nxls",
    "laravel_ls", "laravel_lsp", "phpantom_lsp", "gh_actions_ls", "azure_pipelines_ls", "home_assistant",
    "hydra_lsp", "debputy", "postgres_lsp", "bqls", "terragrunt_ls", "denols", "dagger", "zk", "mpls",
    "markdown_oxide", "daedalus_ls", "flux_lsp", "buddy_ls", "rust_glancer", "anakin_language_server",
}

# Where a language has several good servers: the usual choice first (what
# VS Code's and Zed's extensions run), by Neovim file type.
PREFERRED = {
    "c": ["clangd", "ccls", "clice"], "cpp": ["clangd", "ccls", "clice"], "cuda": ["clangd"],
    "php": ["intelephense", "phpactor", "psalm"], "json": ["jsonls"], "glsl": ["glsl_analyzer", "glslls"],
    "fortran": ["fortls"], "ruby": ["ruby_lsp", "solargraph", "sorbet"], "sh": ["bashls"], "bash": ["bashls"],
    "javascript": ["ts_ls", "vtsls"], "typescript": ["ts_ls", "vtsls"], "markdown": ["marksman"],
    "perl": ["perlnavigator", "perlls"], "sql": ["sqls", "sqlls"], "elixir": ["expert", "elixirls", "nextls", "lexical"],
    "html": ["html", "superhtml"], "yaml": ["yamlls"], "lua": ["lua_ls", "emmylua_ls"], "haskell": ["hls"],
    "bzl": ["starpls", "bzl"], "fsharp": ["fsautocomplete"], "java": ["jdtls", "jls", "java_language_server"],
    "kotlin": ["kotlin_lsp", "kotlin_language_server"], "nim": ["nim_langserver"], "rmd": ["r_language_server"],
    "verilog": ["verible", "slang_server", "svls"], "systemverilog": ["verible", "slang_server", "svls"],
    "asm": ["asm_lsp"], "make": ["autotools_ls"], "proto": ["buf_ls", "protols", "pbls"], "robot": ["robotcode"],
    "vlang": ["v_analyzer"], "cmake": ["neocmake", "cmake"], "coq": ["coq_lsp"], "crystal": ["crystalline"],
    "css": ["cssls"], "scss": ["cssls", "somesass_ls"], "cue": ["cue"], "d": ["serve_d"], "dockerfile": ["dockerls"],
    "fennel": ["fennel_ls"], "wgsl": ["wgsl_analyzer"], "mdx": ["mdx_analyzer"], "terraform": ["terraformls", "tofu_ls"],
    "nix": ["nixd", "nil_ls"], "openscad": ["openscad_lsp"], "rego": ["regal", "regols"], "liquid": ["shopify_theme_ls"],
    "solidity": ["solidity_ls_nomicfoundation", "solidity_ls"], "toml": ["taplo", "tombi"], "typst": ["tinymist"],
    "tex": ["texlab"], "plaintex": ["texlab"], "python": ["basedpyright", "pyright"], "rust": ["rust_analyzer"],
    "scheme": ["scheme_langserver"], "racket": ["racket_langserver"], "reason": ["reason_ls"],
    "dts": ["dts_lsp"], "vhdl": ["vhdl_ls"], "gn": ["gn_language_server"], "eruby": ["herb_ls"],
}


def choices(entries, kinds_of, installable):
    """Extension / file name → server ids, best first."""
    def rank(entry, kind):
        preferred = PREFERRED.get(kind, [])
        return (
            preferred.index(entry["id"]) if entry["id"] in preferred else len(preferred),
            not installable(entry), len(kinds_of[entry["id"]]), entry["id"],
        )

    out = {"extensions": {}, "fileNames": {}}
    for slot, key in (("extensions", "languages"), ("fileNames", "fileNames")):
        claims = {}
        for entry in entries:
            if entry["id"] in NOT_A_DEFAULT:
                continue
            for name, kind in entry[key].items():
                claims.setdefault(name, []).append((rank(entry, kind), entry["id"]))
        out[slot] = {name: [server for _, server in sorted(found)] for name, found in sorted(claims.items())}
    return out


# --- Mason -------------------------------------------------------------------------

NEEDS = {"npm": "Node.js", "pypi": "Python 3", "golang": "Go", "cargo": "Rust"}
INSTALLABLE = {"npm", "pypi", "golang", "cargo", "github", "generic"}


def mason(path):
    registry = json.loads(Path(path).read_text())
    by_server = {}
    for package in registry:
        name = (package.get("neovim") or {}).get("lspconfig")
        if not name:
            continue
        kind = package["source"]["id"].removeprefix("pkg:").split("/")[0]
        by_server[name] = {
            "package": package["name"],
            "bins": sorted((package.get("bin") or {}).keys()),
            "installable": kind in INSTALLABLE,
            "needs": NEEDS.get(kind),
        }
    return by_server


# --- Conversion --------------------------------------------------------------------


def roots(fields):
    """Marker groups: nvim's list (a nested list is one group) or a `root_pattern(...)` call."""
    if "root_markers" in fields:
        value = data(fields["root_markers"])
        groups = [[item] if isinstance(item, str) else item for item in value]
        return [group for group in groups if group and all(isinstance(marker, str) for marker in group)]
    if "root_dir" in fields:
        items, groups = fields["root_dir"], []
        for index, item in enumerate(items):
            if item != ("name", "root_pattern") or items[index + 1] != ("op", "("):
                continue
            group, cursor = [], index + 2
            while items[cursor] != ("op", ")"):
                if items[cursor][0] == "string":
                    group.append(items[cursor][1])
                elif items[cursor] != ("op", ","):
                    group = []  # a variable or a call: not data
                    break
                cursor += 1
            if group:
                groups.append(group)
        return groups
    return []


def local_first_command(field):
    """nvim-lspconfig's "the project's node_modules/.bin copy, else the global one":
    `local cmd = 'name'` … `vim.lsp.rpc.start({ cmd, args… }, dispatchers)`."""
    items = list(field)
    binary = None
    for index in range(len(items) - 3):
        if items[index:index + 3] == [("name", "local"), ("name", "cmd"), ("op", "=")] and items[index + 3][0] == "string":
            binary = items[index + 3][1]
    calls = [i for i in range(len(items) - 4) if items[i:i + 4] == [("name", "rpc"), ("op", "."), ("name", "start"), ("op", "(")]]
    if not binary or len(calls) != 1 or "node_modules" not in " ".join(str(item[1]) for item in items):
        raise NotData("cmd is a function")
    start = calls[0] + 4
    if items[start] != ("op", "{") or items[start + 1] != ("name", "cmd"):
        raise NotData("cmd is a function")
    arguments, cursor = [], start + 2
    while items[cursor] != ("op", "}"):
        if items[cursor][0] == "string":
            arguments.append(items[cursor][1])
        elif items[cursor] != ("op", ","):
            raise NotData("cmd is a function")
        cursor += 1
    return [binary] + arguments


def convert(name, source, types, packages):
    fields = return_table(source)
    if "cmd" not in fields:
        raise NotData("no cmd")
    local_first = False
    try:
        command = data(fields["cmd"])
    except NotData:
        command, local_first = local_first_command(fields["cmd"]), True
    if not command or not all(isinstance(part, str) for part in command):
        raise NotData("cmd isn't plain")
    kinds = data(fields["filetypes"]) if "filetypes" in fields else []
    languages, names = {}, {}
    for kind in kinds:
        extensions, files = files_for(kind, types)
        for extension in extensions:
            languages.setdefault(extension.lower(), kind)
        for file in files:
            names.setdefault(file, kind)
    if not languages and not names:
        raise NotData("no file types Orbit can match")

    entry = {
        "id": name,
        "name": display_name(kinds, types),
        "lspconfig": name,
        "languages": languages,
        "fileNames": names,
        "roots": [],
        "launch": [],
    }
    try:
        entry["roots"] = roots(fields)
    except NotData:
        pass
    package = packages.get(name)
    binary, arguments = command[0], command[1:]
    if local_first:
        entry["launch"].append({"project": {"binary": binary, "arguments": arguments}})
    if package and package["installable"] and binary in package["bins"]:
        entry["install"] = {"package": package["package"], "binary": binary, "arguments": arguments}
        if package["needs"]:
            entry["install"]["needs"] = package["needs"]
        entry["launch"].append({"installed": {}})
    entry["launch"].append({"path": {"binary": binary, "arguments": arguments}})
    if not entry.get("install"):
        entry["missingHint"] = f"Install {binary} and make sure it's on your PATH."
    for key, field in (("settings", "settings"), ("initializationOptions", "init_options")):
        if field in fields:
            try:
                value = data(fields[field])
                if value not in ({}, []):
                    entry[key] = value
            except NotData:
                pass
    # Servers built on tsserver (Astro, MDX) are told where TypeScript is, from
    # the project or a copy Orbit has (`${typescriptSdk}`).
    if any(text == "get_typescript_server_path" for _, text in fields.get("before_init", [])):
        options = entry.get("initializationOptions")
        options = options if isinstance(options, dict) else {}
        typescript = options.get("typescript")
        options["typescript"] = {**(typescript if isinstance(typescript, dict) else {}), "tsdk": "${typescriptSdk}"}
        entry["initializationOptions"] = options
    entry["kinds"] = kinds
    return entry


def main():
    lspconfig, filetype_lua, languages_yml, registry, commit, output = sys.argv[1:7]
    types = filetypes(filetype_lua, languages_yml)
    packages = mason(registry)
    entries, skipped = [], {}
    for path in sorted(Path(lspconfig, "lsp").glob("*.lua")):
        try:
            entries.append(convert(path.stem, path.read_text(), types, packages))
        except NotData as error:
            skipped[path.stem] = str(error)
    kinds_of = {entry["id"]: entry.pop("kinds") for entry in entries}
    document = {
        "source": f"https://github.com/neovim/nvim-lspconfig/tree/{commit}/lsp",
        "license": "Apache-2.0 (nvim-lspconfig, Neovim's file type table); MIT (GitHub Linguist's languages)",
        "servers": entries,
        "choices": choices(entries, kinds_of, lambda entry: "install" in entry),
    }
    Path(output).write_text(json.dumps(document, indent=1, sort_keys=True, ensure_ascii=False) + "\n")
    print(f"{len(entries)} servers, {len(skipped)} left out")
    for name, reason in sorted(skipped.items()):
        print(f"  {name}: {reason}")


if __name__ == "__main__":
    main()
