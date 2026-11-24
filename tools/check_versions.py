#!/usr/bin/env python3
"""Every version stamp in the repository names the same release.

    python3 tools/check_versions.py      exit 1 if any stamp disagrees

The version is written by hand in ten files (handbook chapter "Versioning and
releases", "The version is stamped in more than one place"). A stamp left
behind mislabels provenance: dw_toolkit_version() is recorded in dw_stage()
sidecars and dw_publish() payloads. This check reads the release from
r/DESCRIPTION and its date from NEWS.md, then requires every other stamp to
match both. Between releases the stamps all name the last release, so the
check holds on develop too.

Standard library only. Run in the `Conformance` workflow's compare job.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

VER = r"(\d+\.\d+\.\d+(?:\.\d+)?(?:-rc\d+)?)"

# Stamps that must all equal the release: (file, [patterns]). Each pattern has
# one group, the version; it must match at least once, and every match counts.
STAMPS = [
    ("r/R/dw_io.R", [r"^# Toolkit version: {V}\s*$",
                     r"Currently `\"{V}\"`",
                     r"vendored tag = {V}\"",
                     r"^\s*\"{V}\"\s*$"]),
    ("r/man/dw_toolkit_version.Rd", [r"Currently `\"{V}\"`"]),
    ("r/tests/testthat/test-dw_io-mode-contract.R", [r"current v{V} stamp",
                                                    r"dw_toolkit_version\(\), \"{V}\"\)"]),
    ("r/tests/testthat/test-dw_publish.R", [r"body\$toolkit,\s*\"{V}\""]),
    ("python/pyproject.toml", [r"^version = \"{V}\""]),
    ("python/src/__init__.py", [r"^__version__ = \"{V}\""]),
    ("python/src/dw_io.py", [r"^Toolkit version: {V}\s*$",
                             r"version stamp \(\"{V}\"\)",
                             r"^_TOOLKIT_VERSION = \"{V}\"",
                             r"Semver string \(``\"{V}\"``\)",
                             r"^\s*'{V}'\s*$"]),
    ("CITATION.cff", [r"^\s*version: \"{V}\""]),
    (".zenodo.json", [r"^\s*\"version\": \"{V}\""]),
    ("README.md", [r", v{V} \(\d{{4}}\),"]),
    ("book/introduction.qmd", [r"currently v{V}\)"]),
    ("book/appendices/e-glossary.qmd", [r"as of `cso-toolkit` \*\*v{V}\*\*"]),
]

# Dates that must equal the release date: (file, pattern with one group).
DATES = [
    ("CITATION.cff", r"^\s*date-released: \"(\d{4}-\d\d-\d\d)\""),
    (".zenodo.json", r"^\s*\"publication_date\": \"(\d{4}-\d\d-\d\d)\""),
]


def read(repo: Path, rel: str) -> str:
    return (repo / rel).read_text(encoding="utf-8")


def release(repo: Path) -> tuple:
    """(version, date): the version from r/DESCRIPTION, its date from NEWS.md."""
    m = re.search(r"^Version:\s*(\S+)\s*$", read(repo, "r/DESCRIPTION"), re.M)
    if not m:
        sys.exit("[versions] r/DESCRIPTION has no Version: line")
    v = m.group(1)
    m = re.search(rf"^## v{re.escape(v)} \((\d{{4}}-\d\d-\d\d)\)", read(repo, "NEWS.md"), re.M)
    return v, (m.group(1) if m else None)


def check(repo: Path) -> list:
    """Every disagreement, as 'file:line: message'; empty when all agree."""
    v, date = release(repo)
    errs = []
    if date is None:
        errs.append(f"NEWS.md: no '## v{v} (YYYY-MM-DD)' heading for r/DESCRIPTION's {v}")
    for rel, pats in STAMPS:
        text = read(repo, rel)
        for pat in pats:
            rx = re.compile(pat.format(V=VER), re.M)
            hits = [(text.count("\n", 0, m.start()) + 1, m.group(1)) for m in rx.finditer(text)]
            if not hits:
                errs.append(f"{rel}: no stamp matching /{pat.format(V='X.Y.Z')}/")
            errs += [f"{rel}:{ln}: {got}, expected {v}" for ln, got in hits if got != v]
    readme = read(repo, "README.md")
    if date and not re.search(rf"^\| `v{re.escape(v)}` \| {date} \|", readme, re.M):
        errs.append(f"README.md: no version-table row '| `v{v}` | {date} |'")
    if date:
        for rel, pat in DATES:
            text = read(repo, rel)
            hits = [(text.count("\n", 0, m.start()) + 1, m.group(1))
                    for m in re.finditer(pat, text, re.M)]
            if not hits:
                errs.append(f"{rel}: no release date found")
            errs += [f"{rel}:{ln}: date {got}, expected {date} (NEWS.md)"
                     for ln, got in hits if got != date]
    return errs


def main() -> int:
    repo = Path(__file__).resolve().parents[1]
    v, date = release(repo)
    errs = check(repo)
    if errs:
        print(f"[versions] FAIL: stamps disagree with r/DESCRIPTION ({v})")
        for e in errs:
            print(f"  {e}")
        print("  Fix: stamp every place listed in chapter 'Versioning and releases'.")
        return 1
    n = sum(len(p) for _, p in STAMPS) + len(DATES) + 1
    print(f"[versions] PASS: v{v} ({date}); {n} stamp patterns in "
          f"{len({f for f, _ in STAMPS + DATES})} files agree")
    return 0


if __name__ == "__main__":
    sys.exit(main())
