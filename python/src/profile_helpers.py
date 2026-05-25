"""Scaffold and audit project profile scripts for CSO pipelines.

Python port of ``r/R/profile_helpers.R``.  Generates a ``profile_<repo>.py``
template wired with the standard CSO building blocks (cross-platform user
identification, YAML config load, optional producer / reviewer ``dw_mode``
block, optional Z: drive advisory, packages block, profile sentinel) and
audits an existing profile for the same blocks.
"""

from __future__ import annotations

import datetime as _dt
import getpass
import os
import re
from pathlib import Path
from typing import List, Optional, Union

import pandas as pd


def _sentinel_name(repo_name: str) -> str:
    """Return the sentinel variable name for ``repo_name`` (kebab/dot → snake)."""
    return "profile_" + re.sub(r"[-.]+", "_", repo_name)


def create_profile(
    repo_name: str,
    *,
    project_title: Optional[str] = None,
    output_path: Union[str, Path] = ".",
    include_dw_mode: bool = True,
    include_z_drive_check: bool = False,
    author: Optional[str] = None,
    overwrite: bool = False,
) -> str:
    """Generate a project profile script for a CSO data-warehouse pipeline.

    Writes a ``profile_<repo_name>.py`` template to disk.  The template
    wires up the standard CSO building blocks: cross-platform user
    identification, reproducibility seed, optional Z: drive integrity
    check, YAML user config load, optional producer / reviewer
    ``dw_mode`` resolution, a placeholder imports block, and a profile
    sentinel boolean.

    Parameters
    ----------
    repo_name
        Repository folder name.  Used in the sentinel name
        (``profile_<repo_name>`` with ``-`` and ``.`` converted to ``_``)
        and the generated filename (``profile_<repo_name>.py``).
    project_title
        Human-readable project title for the header block.
    output_path
        Directory the file is written to.
    include_dw_mode
        Include the producer / reviewer mode block that reads ``dw_mode``
        from ``user_config.yml`` and hard-fails when missing.
    include_z_drive_check
        Include the Z: drive availability advisory.
    author
        Author name for the header.
    overwrite
        If ``False``, raise when the target file already exists.

    Returns
    -------
    str
        Absolute path of the file written.
    """
    project_title = project_title or repo_name
    author = author or os.environ.get("USERNAME") or getpass.getuser()
    sentinel = _sentinel_name(repo_name)
    filename = f"profile_{repo_name}.py"
    out_dir = Path(output_path)
    try:
        out_dir.mkdir(parents=True, exist_ok=True)
    except PermissionError as exc:
        raise PermissionError(
            f"[cso_toolkit.create_profile] Cannot create {out_dir}.\n"
            f"  Underlying error: {exc.strerror or exc}\n"
            "  Fix: check filesystem permissions, or pass a writable "
            "output_path."
        ) from exc
    path = out_dir / filename
    if path.exists() and not overwrite:
        raise FileExistsError(
            f"[cso_toolkit.create_profile] File already exists: {path}\n"
            "  Fix: pass overwrite=True to replace it, or delete the "
            "existing profile first."
        )

    timestamp = _dt.datetime.now().strftime("%Y-%m-%d %H:%M")

    header = f'''"""
Project: {project_title}
Script : {filename}
Purpose: Sets user-specific paths, verifies folder structure, loads
         required modules, and prepares the working environment for
         pipeline execution.
Author : {author}
Created: {timestamp}
Toolkit: cso-toolkit (https://github.com/unicef-drp/cso-toolkit)
"""

from __future__ import annotations

import os
import random
import sys
from pathlib import Path

import yaml

# Reproducibility seed
random.seed(12345)

# ----------------------------------------
# 1. User Identification (cross-platform)
# ----------------------------------------
USERNAME = os.environ.get("USERNAME") or os.environ.get("USER") or ""
USERPROFILE = os.environ.get("USERPROFILE") or os.path.expanduser("~")

# ----------------------------------------
# 2. Flags and Controls
# ----------------------------------------
create_missing_folders = False

# ----------------------------------------
# 3. Repository name
# ----------------------------------------
repo_name = "{repo_name}"

'''

    z_block = ""
    if include_z_drive_check:
        z_block = '''# ----------------------------------------
# 4. Z: drive — non-blocking advisory
# ----------------------------------------
# The Z: drive is the legacy Azure file-share mirror of canonical
# deposits.  Absence does NOT stop execution — only an advisory.
network_root = "Z:/"
dw_z_available = Path(network_root).is_dir()
if not dw_z_available:
    print("\\n[!] Network drive (Z:) not mounted - NON-BLOCKING", file=sys.stderr)

'''

    config_block = '''# ----------------------------------------
# 5. Load user config (YAML required)
# ----------------------------------------
config_path = Path(USERPROFILE) / ".config" / "user_config.yml"
if not config_path.exists():
    raise FileNotFoundError(
        f"[X] Configuration file not found at: {config_path}\\n"
        "[>] Create or move your 'user_config.yml' to this location."
    )
with open(config_path, encoding="utf-8") as _f:
    user_config = yaml.safe_load(_f)  # cso-allow: io-yaml

'''

    mode_block = ""
    if include_dw_mode:
        mode_block = '''# ----------------------------------------
# 6. Producer / reviewer mode (cso-toolkit contract)
# ----------------------------------------
dw_mode = user_config.get("dw_mode")
if dw_mode not in ("producer", "reviewer"):
    raise ValueError(
        "[X] user_config.yml must set dw_mode to 'producer' or 'reviewer'."
    )

# Wire state into the toolkit so dw_save / dw_use / dw_api_fetch route by mode.
from cso_toolkit import _state as _cso_state  # noqa: E402

_cso_state.configure(
    dw_mode=dw_mode,
    dw_apis_allowed=(dw_mode == "producer"),
)

def dw_require_no_api(context: str | None = None) -> None:
    """Hard-stop when running in reviewer mode.  Use to gate ad-hoc
    network calls in analysis scripts."""
    if dw_mode == "reviewer":
        msg = "[X] External API access is forbidden in reviewer mode."
        if context:
            msg += f" Context: {context}"
        raise PermissionError(msg)

'''

    packages_block = '''# ----------------------------------------
# 7. Imports (extend as needed by the pipeline)
# ----------------------------------------
import pandas as pd  # noqa: F401  E402

'''

    sentinel_block = f'''# ----------------------------------------
# 8. Profile sentinel
# ----------------------------------------
{sentinel} = True

def log_message(msg: str) -> None:
    """Lightweight timestamped logger consumed by sector scripts."""
    import datetime as _dt2
    print(f"[{{_dt2.datetime.now():%Y-%m-%d %H:%M:%S}}] {{msg}}")

print(f"[OK] {filename} loaded")
'''

    path.write_text(
        header + z_block + config_block + mode_block + packages_block + sentinel_block,
        encoding="utf-8",
    )
    print(f"[OK] Profile written: {path}")
    return str(path.resolve())


# ---------------------------------------------------------------------------
# review_profile
# ---------------------------------------------------------------------------

def _check(check: str, ok: bool, ok_detail: str, fail_detail: str,
           level: str = "fail") -> dict:
    return {
        "check": check,
        "status": "pass" if ok else level,
        "detail": ok_detail if ok else fail_detail,
    }


def review_profile(
    path: Union[str, Path],
    *,
    require_dw_mode: bool = True,
    require_z_drive_check: bool = False,
    verbose: bool = True,
) -> pd.DataFrame:
    """Audit a profile script for the blocks the cso-toolkit contract expects.

    Reads a ``profile_<repo>.py`` file and runs a series of presence
    checks for the building blocks the cso-toolkit IO + API contract
    depends on (profile sentinel, cross-platform user identification,
    YAML config load, producer / reviewer ``dw_mode`` resolution, the
    ``dw_require_no_api`` guard, a reproducibility seed, and a packages
    block).

    Pattern-based (not parse-based), so it tolerates stylistic variation
    across profiles written before this helper existed.

    Parameters
    ----------
    path
        Path to the profile script.
    require_dw_mode
        Treat absence of the ``dw_mode`` block as ``"fail"`` (default)
        or ``"warn"``.
    require_z_drive_check
        Treat absence of the Z: advisory as ``"fail"`` (default
        ``False`` → ``"warn"``).
    verbose
        Print a formatted summary.

    Returns
    -------
    pd.DataFrame
        Columns ``check``, ``status``, ``detail``.
    """
    path = Path(path)
    if not path.exists():
        raise FileNotFoundError(
            f"[cso_toolkit.review_profile] Profile file not found: {path}\n"
            "  Fix: pass the correct path; relative paths are resolved "
            f"against {os.getcwd()}."
        )
    try:
        src = path.read_text(encoding="utf-8")
    except UnicodeDecodeError as exc:
        raise RuntimeError(
            f"[cso_toolkit.review_profile] {path} is not UTF-8.\n"
            f"  Underlying error: {exc}\n"
            "  Fix: re-save the profile as UTF-8."
        ) from exc

    def has(pattern: str) -> bool:
        return re.search(pattern, src, re.MULTILINE) is not None

    checks: List[dict] = []

    # 1. Profile sentinel
    sentinel_match = re.search(r"^\s*profile_[A-Za-z0-9_]+\s*=\s*True\b",
                               src, re.MULTILINE)
    checks.append(_check(
        "Profile sentinel object",
        sentinel_match is not None,
        f"Found: {sentinel_match.group(0).strip()}" if sentinel_match else "",
        "Missing `profile_<repo> = True` sentinel — sector scripts cannot "
        "verify the profile was imported.",
    ))

    # 2. Cross-platform user identification
    checks.append(_check(
        "Cross-platform user identification",
        has(r"os\.environ\.get\(\s*['\"]USERNAME['\"]") or has(r"os\.environ\.get\(\s*['\"]USER['\"]"),
        "Reads USERNAME / USER via os.environ.get().",
        "Profile never reads USERNAME / USER — Mac/Linux/Windows paths may break.",
    ))

    # 3. Reproducibility seed
    checks.append(_check(
        "Reproducibility seed",
        has(r"random\.seed\(") or has(r"np\.random\.seed\(") or has(r"numpy\.random\.seed\("),
        "A seed call is present.",
        "No random.seed() / np.random.seed() — reruns are not bit-reproducible.",
        level="warn",
    ))

    # 4. user_config.yml load
    loads_yaml = (
        has(r"user_config\.ya?ml")
        and (has(r"yaml\.safe_load") or has(r"yaml\.load"))
    )
    checks.append(_check(
        "user_config.yml load",
        loads_yaml,
        "Loads user_config.yml via yaml.safe_load().",
        "Profile never reads user_config.yml — per-user paths and dw_mode "
        "cannot resolve.",
    ))

    # 5. dw_mode resolution
    dw_mode_present = has(r"dw_mode") and has(r"producer") and has(r"reviewer")
    checks.append(_check(
        "dw_mode (producer/reviewer) resolution",
        dw_mode_present,
        "dw_mode resolved against producer / reviewer.",
        "dw_mode block missing — dw_io.py / dw_api.py route-by-mode contract "
        "will not engage.",
        level="fail" if require_dw_mode else "warn",
    ))

    # 6. dw_require_no_api guard
    checks.append(_check(
        "dw_require_no_api guard",
        has(r"dw_require_no_api"),
        "dw_require_no_api is defined or invoked.",
        "dw_require_no_api not defined — reviewer mode cannot enforce the "
        "no-API rule.",
        level="fail" if require_dw_mode else "warn",
    ))

    # 7. Z: drive advisory
    checks.append(_check(
        "Z: drive availability advisory",
        has(r"dw_z_available") or has(r"network_root\s*=\s*['\"]Z:"),
        "Z: drive availability is checked.",
        "Z: drive advisory not present — runs without the legacy mirror "
        "will be silent.",
        level="fail" if require_z_drive_check else "warn",
    ))

    # 8. Imports block
    checks.append(_check(
        "Imports block",
        has(r"^\s*import\s+\w") or has(r"^\s*from\s+\w"),
        "An imports block is present.",
        "No import statements — pipeline likely fails on first run.",
        level="warn",
    ))

    out = pd.DataFrame(checks)

    if verbose:
        icon = {"pass": "[OK]", "warn": "[!]", "fail": "[X]"}
        print(f"\nProfile review: {path.resolve()}")
        print("-" * 72)
        for r in checks:
            print(f"{icon.get(r['status'], '?'):<5} {r['check']:<44} {r['detail']}")
        n_fail = sum(1 for r in checks if r["status"] == "fail")
        n_warn = sum(1 for r in checks if r["status"] == "warn")
        n_pass = sum(1 for r in checks if r["status"] == "pass")
        print("-" * 72)
        print(f"{n_pass} passed, {n_warn} warnings, {n_fail} failures.")

    return out
