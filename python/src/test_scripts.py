"""Audit Python scripts for direct calls to commands wrapped by cso-toolkit.

Python port of ``r/R/test_scripts.R`` — adapted to detect the *Python*
equivalents of the raw IO / HTTP calls the toolkit wraps.

The contract this enforces is:

* File IO must go through :func:`cso_toolkit.dw_save` /
  :func:`cso_toolkit.dw_use` / :func:`cso_toolkit.dw_compare` /
  :func:`cso_toolkit.dw_merge` — never ``pd.read_csv``, ``df.to_excel``,
  ``pickle.dump``, etc.
* External APIs must go through :func:`cso_toolkit.dw_api_fetch` /
  :func:`cso_toolkit.dw_api_cached` — never ``requests.get``,
  ``httpx.get``, ``sdmx.Client``, ``wbgapi.data.fetch``, etc.

Per-line escape hatch: append ``# cso-allow: <rule-id>`` to the offending
line.  Multiple rules can be silenced as comma-separated ids.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List, Optional, Sequence, Union

import pandas as pd


# ---------------------------------------------------------------------------
# Rule registry
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class _Rule:
    """One audit rule.  ``pattern`` is matched against each line after
    string literals are scrubbed."""
    id: str
    family: str           # "io" | "api"
    pattern: str          # regex
    message: str
    suggest: str


_BUILTIN_RULES: tuple[_Rule, ...] = (
    # ---- IO commands wrapped by dw_io.py ----
    _Rule(
        id="io-read-csv", family="io",
        pattern=r"(?:pd\.|pandas\.)?read_csv\s*\(",
        message="Direct CSV read via pandas.",
        suggest="dw_use(name=..., sector=..., kind=...)",
    ),
    _Rule(
        id="io-to-csv", family="io",
        pattern=r"\.to_csv\s*\(",
        message="Direct CSV write via pandas .to_csv().",
        suggest="dw_save(df, name=..., sector=..., kind=..., isid=...)",
    ),
    _Rule(
        id="io-read-excel", family="io",
        pattern=r"(?:pd\.|pandas\.)?read_excel\s*\(",
        message="Direct Excel read.",
        suggest="dw_use(...) — auto-dispatches on .xlsx",
    ),
    _Rule(
        id="io-to-excel", family="io",
        pattern=r"\.to_excel\s*\(",
        message="Direct Excel write.",
        suggest="dw_save(df, name='...xlsx', ...)",
    ),
    _Rule(
        id="io-read-stata", family="io",
        pattern=r"(?:pd\.|pandas\.)?read_stata\s*\(",
        message="Direct Stata .dta read.",
        suggest="dw_use(...) — auto-dispatches on .dta",
    ),
    _Rule(
        id="io-to-stata", family="io",
        pattern=r"\.to_stata\s*\(",
        message="Direct Stata .dta write.",
        suggest="dw_save(df, name='...dta', ...)",
    ),
    _Rule(
        id="io-read-parquet", family="io",
        pattern=r"(?:pd\.|pandas\.)?read_parquet\s*\(",
        message="Direct Parquet read.",
        suggest="dw_use(...) — auto-dispatches on .parquet",
    ),
    _Rule(
        id="io-to-parquet", family="io",
        pattern=r"\.to_parquet\s*\(",
        message="Direct Parquet write.",
        suggest="dw_save(df, name='...parquet', ...)",
    ),
    _Rule(
        id="io-pickle", family="io",
        pattern=r"pickle\.(?:dump|load)\s*\(",
        message="Direct pickle dump / load.",
        suggest="dw_save(obj, name='...pkl') / dw_use(...)",
    ),
    _Rule(
        id="io-json", family="io",
        pattern=r"json\.(?:dump|load)\s*\(",
        message="Direct JSON dump / load on a file handle.",
        suggest="dw_save(obj, name='...json') / dw_use(...)",
    ),
    _Rule(
        id="io-yaml", family="io",
        pattern=r"yaml\.(?:safe_dump|dump|safe_load|load)\s*\(",
        message="Direct YAML read / write.",
        suggest=(
            "dw_save(obj, name='...yaml') / dw_use(...).  "
            "(Profile YAML config load is exempt — add # cso-allow: io-yaml.)"
        ),
    ),
    _Rule(
        id="io-open-write", family="io",
        pattern=r"\bopen\s*\([^)]*['\"][rwba+xt]+['\"]",
        message="Raw open(...) for IO.",
        suggest=(
            "Prefer dw_save / dw_use for canonical paths; raw open() is "
            "fine for scratch files but should not touch warehouse paths."
        ),
    ),

    # ---- API commands wrapped by dw_api.py ----
    _Rule(
        id="api-requests", family="api",
        pattern=r"\brequests\.(?:get|post|put|patch|delete|request)\s*\(",
        message="Direct HTTP call via requests.",
        suggest="dw_api_fetch(api='http' | 'json_get' | ..., cache_key=...)",
    ),
    _Rule(
        id="api-httpx", family="api",
        pattern=r"\bhttpx\.(?:get|post|put|patch|delete|Client|AsyncClient)\s*\(",
        message="Direct HTTP call via httpx.",
        suggest="dw_api_fetch(api='http' | 'json_get' | ..., cache_key=...)",
    ),
    _Rule(
        id="api-urllib", family="api",
        pattern=r"urllib\.request\.urlopen\s*\(",
        message="Direct HTTP call via urllib.",
        suggest="dw_api_fetch(api='http', cache_key=...)",
    ),
    _Rule(
        id="api-sdmx", family="api",
        pattern=r"sdmx\.Client\s*\(",
        message="Direct sdmx.Client call.",
        suggest="dw_api_fetch(api='sdmx', providerId=..., flowRef=..., key=..., cache_key=...)",
    ),
    _Rule(
        id="api-wbgapi", family="api",
        pattern=r"wbgapi\.(?:data|series|economy)\.",
        message="Direct wbgapi call.",
        suggest="dw_api_fetch(api='wb' | 'wb_indicators', indicator=..., cache_key=...)",
    ),
    _Rule(
        id="api-wbdata", family="api",
        pattern=r"\bwbdata\.(?:get_data|get_dataframe|get_series)\s*\(",
        message="Direct wbdata call.",
        suggest="dw_api_fetch(api='wb', indicator=..., cache_key=...)",
    ),
    _Rule(
        id="api-urlretrieve", family="api",
        pattern=r"urllib\.request\.urlretrieve\s*\(",
        message="Direct file download bypasses the cache.",
        suggest="dw_api_fetch(api='http', cache_key=...) and pass the cached bytes to your reader.",
    ),
)


# ---------------------------------------------------------------------------
# Auditor
# ---------------------------------------------------------------------------

_STRING_RE = re.compile(r'"[^"]*"|\'[^\']*\'')
_ALLOW_RE = re.compile(r"#\s*cso-allow:\s*([A-Za-z0-9_,\-\s]+)")
_COMMENT_RE = re.compile(r"#.*$")


def _strip_strings(line: str) -> str:
    """Replace string literals with empty strings (keep length-equivalent)."""
    return _STRING_RE.sub('""', line)


def _allowed_ids(line: str) -> set[str]:
    m = _ALLOW_RE.search(line)
    if not m:
        return set()
    return {x.strip() for x in m.group(1).split(",") if x.strip()}


def test_scripts(
    path: Union[str, Path],
    pattern: str = r"\.py$",
    *,
    recursive: bool = True,
    ignore_files: Sequence[str] = (
        "dw_io.py", "dw_api.py", "cso_toolkit_sync.py",
        "profile_helpers.py", "test_scripts.py", "_state.py",
        "__init__.py",
    ),
    ignore_dirs: Sequence[str] = (
        ".git", ".venv", "venv", "env", "__pycache__",
        ".tox", ".pytest_cache", "node_modules",
    ),
    custom_rules: Optional[Iterable[_Rule]] = None,
    error_on_violation: bool = False,
    verbose: bool = True,
) -> pd.DataFrame:
    """Audit Python scripts for direct calls to commands wrapped by cso-toolkit.

    Recursively scans a directory of ``.py`` scripts and flags any line
    that calls a raw file-IO or external-API function that
    :mod:`cso_toolkit.dw_io` / :mod:`cso_toolkit.dw_api` is meant to wrap.

    Parameters
    ----------
    path
        Directory (recursed) or single ``.py`` file to scan.
    pattern
        Regex of filenames to include.
    recursive
        Recurse into subdirectories.
    ignore_files
        Basenames to skip (the toolkit's own implementation files default
        to ignored since they must call the wrapped commands).
    ignore_dirs
        Directory basenames to skip (e.g. ``"venv"``, ``"__pycache__"``).
    custom_rules
        Additional rules merged with the built-in registry.
    error_on_violation
        If ``True``, raise after reporting when any ``family="io"`` or
        ``"api"`` violation is found (useful in CI).
    verbose
        Print a formatted summary.

    Returns
    -------
    pd.DataFrame
        Columns ``file``, ``line``, ``rule``, ``family``, ``message``,
        ``suggest``, ``snippet``.  Empty when clean.

    Raises
    ------
    RuntimeError
        When ``error_on_violation=True`` and violations are found.
    """
    p = Path(path)
    if not p.exists():
        raise FileNotFoundError(f"Path not found: {path}")

    file_re = re.compile(pattern, re.IGNORECASE)

    if p.is_dir():
        files: List[Path] = []
        walker = p.rglob("*") if recursive else p.glob("*")
        for f in walker:
            if not f.is_file():
                continue
            if not file_re.search(f.name):
                continue
            if f.name in ignore_files:
                continue
            if any(part in ignore_dirs for part in f.parts):
                continue
            files.append(f)
    else:
        files = [p]

    rules = list(_BUILTIN_RULES) + list(custom_rules or [])
    compiled = [(r, re.compile(r.pattern)) for r in rules]

    violations: List[dict] = []

    for f in sorted(files):
        try:
            lines = f.read_text(encoding="utf-8").splitlines()
        except (OSError, UnicodeDecodeError):
            continue
        for i, raw in enumerate(lines, start=1):
            no_str = _strip_strings(raw)
            allow = _allowed_ids(raw)
            no_comment = _COMMENT_RE.sub("", no_str)
            for rule, regex in compiled:
                if rule.id in allow:
                    continue
                if regex.search(no_comment):
                    violations.append({
                        "file": str(f),
                        "line": i,
                        "rule": rule.id,
                        "family": rule.family,
                        "message": rule.message,
                        "suggest": rule.suggest,
                        "snippet": raw.strip(),
                    })

    out = pd.DataFrame(
        violations,
        columns=["file", "line", "rule", "family",
                 "message", "suggest", "snippet"],
    )

    if verbose:
        print("\ncso-toolkit contract audit")
        print("-" * 72)
        print(f"Files scanned : {len(files)}")
        print(f"Violations    : {len(out)}")
        if len(out) > 0:
            print()
            for v in violations:
                print(f"[{v['rule']}] {v['file']}:{v['line']}")
                print(f"  {v['message']}")
                print(f"  > {v['snippet']}")
                print(f"  -> {v['suggest']}\n")
        else:
            print("[OK] Clean.")
        print("-" * 72)

    if error_on_violation and ((out["family"].isin(["io", "api"])).any()
                                if len(out) > 0 else False):
        raise RuntimeError(
            f"cso-toolkit contract: {len(out)} violation(s) found across "
            f"{out['file'].nunique()} file(s)."
        )

    return out
