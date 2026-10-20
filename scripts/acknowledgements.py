#!/usr/bin/env python3
"""Writes App/Acknowledgements.txt, the licenses of the packages Orbit.app
ships, shown in About Orbit (D207). MIT and BSD ask for their notice in every
copy we hand out, so it's regenerated whenever a dependency changes:
`make acknowledgements` (after `make build` has checked the packages out).

Format, read by App/Acknowledgements.swift: an intro paragraph, then per
package a `# Name` line, a `url · license` line and the license's
paragraphs, separated by blank lines. GPL-3.0's text appears once, at the end.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CHECKOUTS = ROOT / ".build/xcode/SourcePackages/checkouts"
RESOLVED = ROOT / "Packages/OrbitKit/Package.resolved"
OUT = ROOT / "App/Acknowledgements.txt"

# Only SwiftTerm's command-line demo uses it; nothing of it is in the app.
NOT_SHIPPED = {"swift-argument-parser"}
GPL_START = "GNU GENERAL PUBLIC LICENSE"


def license_name(text: str) -> str:
    """The first license in the file: Sparkle's MIT is followed by the ones it bundles."""
    found = [(text.find(marker), name) for marker, name in [
        (GPL_START, "GPL-3.0"), ("Apache License", "Apache-2.0"),
        ("Redistribution and use", "BSD-3-Clause" if "Neither the name" in text else "BSD-2-Clause"),
        ("Permission is hereby granted", "MIT"),
    ] if marker in text]
    if not found:
        sys.exit(f"unknown license:\n{text[:200]}")
    return min(found)[1]


def paragraphs(text: str) -> list[str]:
    """Hard-wrapped lines joined, so the About panel wraps them; list items and
    copyright lines keep their own line."""
    out = []
    for block in re.split(r"\n\s*\n", text.strip()):
        lines = [line.strip() for line in block.splitlines() if line.strip() and not set(line.strip()) <= set("=-")]
        joined: list[str] = []
        for line in lines:
            if joined and not re.match(r"([-*•]|\d+\.|\(\w\))\s|Copyright\b", line):
                joined[-1] += " " + line
            else:
                joined.append(line)
        if joined:
            out.append("\n".join(joined))
    return out


def main() -> None:
    pins = json.loads(RESOLVED.read_text())["pins"]
    sections = []
    for pin in sorted(pins, key=lambda p: p["identity"]):
        if pin["identity"] in NOT_SHIPPED:
            continue
        url = pin["location"].removesuffix(".git")
        name = url.rsplit("/", 1)[1]
        folder = CHECKOUTS / name
        files = sorted(folder.glob("LICENSE*")) or sorted(folder.glob("COPYING*"))
        if not files:
            sys.exit(f"no license in {folder}: run `make build` first")
        text = files[0].read_text()
        kind = license_name(text)
        if kind == "GPL-3.0":
            # The package's own preface; the GPL itself follows once, below.
            text = text[: text.index(GPL_START)].rstrip() + "\n\nThe GNU GPL v3 text is at the end of this list."
        sections.append(f"# {name}\n{url} · {kind}\n\n" + "\n\n".join(paragraphs(text)))

    gpl = (ROOT / "LICENSE").read_text()
    intro = ("Orbit is free software: you can redistribute and change it under the terms of the "
             "GNU General Public License v3.0. Source code: https://github.com/mikhailmogilnikov/orbit\n\n"
             "Orbit is built on these open-source packages.")
    body = "\n\n".join([intro, *sections, "# GNU General Public License v3.0\nhttps://www.gnu.org/licenses/gpl-3.0.html · GPL-3.0",
                        *paragraphs(gpl)])
    OUT.write_text(body + "\n")
    print(f"{OUT.relative_to(ROOT)}: {len(sections)} packages")


if __name__ == "__main__":
    main()
