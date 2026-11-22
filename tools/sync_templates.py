"""Copy the templates the project scaffolders use into the R and Python packages.

create_research_project() and create_official_stats_project() read their
templates from the installed package: r/inst/templates/ (R) and
python/src/templates/ (Python). The source of truth is templates/ at the
repository root; this script copies the files listed in SHIPPED there into
both packages, byte for byte, and removes files that are no longer listed.

    python tools/sync_templates.py           # copy
    python tools/sync_templates.py --check   # report differences, exit 1 if any

Both test suites (r/tests/testthat/test-create_project.R,
python/tests/test_create_project.py) fail while a copy differs.
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "templates"
TARGETS = [ROOT / "r" / "inst" / "templates", ROOT / "python" / "src" / "templates"]

# Paths relative to templates/; a trailing slash means every file below it.
SHIPPED = [
    "cso_project.yml",
    "gitignore/research-project.gitignore",
    "gitignore/official-stats.gitignore",
    "gitattributes/project.gitattributes",
    "hooks/pre-push",
    "tools/check.R",
    "tools/check",
    "checks/README.md",
    "agents/",
    "testthat/tests/testthat.R",
    "testthat/tests/testthat/helper-project.R",
    "workflows/",
    "project/",
    "profile/",
]


def shipped_files() -> list[str]:
    out = []
    for entry in SHIPPED:
        if entry.endswith("/"):
            base = SOURCE / entry
            out += [p.relative_to(SOURCE).as_posix()
                    for p in sorted(base.rglob("*")) if p.is_file()]
        else:
            out.append(entry)
    return out


def main(argv: list[str]) -> int:
    check = "--check" in argv
    files = shipped_files()
    hidden = [f for f in files if any(part.startswith(".") for part in f.split("/"))]
    if hidden:
        # R CMD check notes hidden files and setuptools' globs skip them.
        print("hidden files cannot be shipped:", ", ".join(hidden))
        return 2
    problems = 0
    for target in TARGETS:
        for rel in files:
            src, dst = SOURCE / rel, target / rel
            if dst.is_file() and dst.read_bytes() == src.read_bytes():
                continue
            problems += 1
            print(("differs: " if dst.exists() else "missing: ") + dst.relative_to(ROOT).as_posix())
            if not check:
                dst.parent.mkdir(parents=True, exist_ok=True)
                dst.write_bytes(src.read_bytes())
        if target.exists():
            for p in sorted(target.rglob("*")):
                if p.is_file() and p.relative_to(target).as_posix() not in files:
                    problems += 1
                    print("stale:   " + p.relative_to(ROOT).as_posix())
                    if not check:
                        p.unlink()
    if check:
        return 1 if problems else 0
    print(f"{len(files)} template file(s) in sync in {len(TARGETS)} package(s)"
          + (f"; {problems} change(s) made" if problems else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
