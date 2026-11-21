"""dw_deposit -- fetch pipeline inputs from the canonical deposit and verify them.

Python port of ``r/R/dw_deposit.R`` (#152). Some pipelines keep their raw
inputs out of Git (Consult-tool exports, licensed microdata, large
deliveries) in a local, gitignored folder of the consumer repository.
Reproducibility then rests on the copy deposited in the canonical store: the
Teams ``060.DW-MASTER`` folder and its Z: drive mirror.

* :func:`dw_fetch_inputs` fills the local folder from the deposit (or reads
  the deposit in place) and verifies every input;
* :func:`dw_check_deposit` proves that every local input has an identical
  (SHA-256) copy in the deposit.

Mode contract: both functions only READ the canonical deposit and only
WRITE under ``local_root``, so they behave identically in producer and
reviewer sessions and never touch Teams or Z:.

The deposit layout mirrors the consumer repository: a local folder
``<repo>/<rel_dir>`` corresponds to ``<teamsFolderCanonical>/<rel_dir>`` on
Teams and ``<dwZDrive>/<rel_dir>`` on Z:.
"""
from __future__ import annotations

import os
import re
import shutil
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Union

import pandas as pd

from . import _state
from .dw_io import _sha256_file

__all__ = ["dw_check_deposit", "dw_fetch_inputs"]

_IGNORED = re.compile(r"(^|/)\.gitkeep$|\.dw_fetch\.tmp$")
_STATUS_COLS = ["file", "path", "sha256", "origin", "teams", "z"]


def _say(fn: str, verbose: Optional[bool], *parts: str) -> None:
    if verbose is None or verbose:
        print(f"[cso_toolkit.{fn}] " + "".join(parts))


def _deposit_dirs(rel_dir: str, teams_root: Optional[str], z_root: Optional[str]) -> Dict[str, Optional[str]]:
    """The deposit folders on Teams and Z: for ``rel_dir`` (``None`` when unavailable)."""
    if teams_root is None:
        teams_root = _state._get("teamsFolderCanonical")
    if z_root is None:
        z_root = _state._get("dwZDrive") if _state._get("dw_z_available") is True else None

    def join(root):
        if not isinstance(root, (str, os.PathLike)) or not str(root) or not os.path.isdir(root):
            return None
        return os.path.join(str(root), rel_dir)
    return {"teams": join(teams_root), "z": join(z_root)}


def _list(folder: Optional[str], pattern: Optional[str]) -> List[str]:
    """Files under ``folder`` matching ``pattern`` (on the file name), relative, '/'-separated."""
    if folder is None or not os.path.isdir(folder):
        return []
    rx = re.compile(pattern) if pattern else None
    out = []
    for base, _dirs, files in os.walk(folder):
        for f in files:
            rel = os.path.relpath(os.path.join(base, f), folder).replace(os.sep, "/")
            if _IGNORED.search(rel):
                continue
            if rx is None or rx.search(f):
                out.append(rel)
    return sorted(out)


def _subdirs(folder: Optional[str]) -> List[str]:
    if folder is None or not os.path.isdir(folder):
        return []
    out = []
    for base, dirs, _files in os.walk(folder):
        for d in dirs:
            out.append(os.path.relpath(os.path.join(base, d), folder).replace(os.sep, "/"))
    return out


def _gitkeep(root: str, subdirs: Sequence[str] = ()) -> int:
    """Make sure ``root`` and its ``subdirs`` exist, each holding an empty ``.gitkeep``."""
    created = 0
    for d in dict.fromkeys([root] + [os.path.join(root, s) for s in subdirs]):
        os.makedirs(d, exist_ok=True)
        keep = os.path.join(d, ".gitkeep")
        if not os.path.exists(keep):
            open(keep, "w").close()
            created += 1
    return created


def _compare(copy_path: Optional[str], size: int, sha: str) -> str:
    """``match`` / ``differs`` / ``missing`` / ``no access`` for one deposit copy."""
    if copy_path is None:
        return "no access"
    if not os.path.exists(copy_path):
        return "missing"
    if os.path.getsize(copy_path) != size:
        return "differs"
    return "match" if _sha256_file(copy_path) == sha else "differs"


def _copy(src: str, dest: str) -> str:
    """Copy to ``<dest>.dw_fetch.tmp``, verify the SHA-256, rename into place. One retry."""
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    tmp = dest + ".dw_fetch.tmp"
    src_sha = _sha256_file(src)
    for _attempt in range(2):
        try:
            if os.path.exists(tmp):
                os.remove(tmp)
            shutil.copy2(src, tmp)
            if _sha256_file(tmp) == src_sha:
                os.replace(tmp, dest)
                return src_sha
        except OSError:
            pass
    if os.path.exists(tmp):
        os.remove(tmp)
    raise OSError(
        f"[cso_toolkit.dw_fetch_inputs] Could not copy '{os.path.basename(dest)}' from the deposit.\n"
        f"  Source: {src}\n  Target: {dest}\n"
        "  The copy failed or its SHA-256 did not match the source, twice.\n"
        "  Fix: make sure the source is fully synced (OneDrive) or Z: is reachable, and that "
        "the target folder is writable; then rerun."
    )


def _where(dirs: Dict[str, Optional[str]]) -> str:
    return (f"  Teams: {dirs['teams'] or '(not available)'}\n"
            f"  Z:     {dirs['z'] or '(not available)'}")


def _norm(p: Union[str, os.PathLike]) -> str:
    return os.path.abspath(str(p)).replace("\\", "/").rstrip("/")


def dw_check_deposit(
    paths: Sequence[Union[str, os.PathLike]],
    local_root: Union[str, os.PathLike],
    rel_dir: str,
    teams_root: Optional[str] = None,
    z_root: Optional[str] = None,
    stop_on_fail: bool = True,
    verbose: Optional[bool] = None,
    debug: Optional[bool] = None,
) -> pd.DataFrame:
    """Check that local input files are deposited on Teams or Z:.

    For every file in ``paths`` (which must lie under ``local_root``), looks
    for the file at the same relative path in the canonical deposit,
    ``<teams_root>/<rel_dir>`` and ``<z_root>/<rel_dir>``, and compares the two
    by size and SHA-256. A file passes when an identical copy exists on Teams
    **or** on Z:, and no copy that exists differs. Mirror of R
    ``dw_check_deposit()``.

    Parameters
    ----------
    paths
        Full paths of the local input files to check.
    local_root
        The local folder that mirrors ``rel_dir``.
    rel_dir
        The same folder relative to the deposit root.
    teams_root, z_root
        Deposit roots; ``None`` uses the session's ``teamsFolderCanonical``
        and (when ``dw_z_available``) ``dwZDrive``.
    stop_on_fail
        Raise when any file fails (default). ``False`` returns the report.
    verbose, debug
        Progress messages (default on) and troubleshooting detail.

    Returns
    -------
    pandas.DataFrame
        One row per file: ``file`` (relative to ``local_root``), ``sha256``,
        ``teams`` and ``z`` (``match`` / ``differs`` / ``missing`` /
        ``no access``) and ``ok``.

    Raises
    ------
    FileNotFoundError
        Neither deposit root is reachable.
    ValueError
        A path lies outside ``local_root``, or (with ``stop_on_fail``) a file
        is missing from the deposit or differs from a deposited copy.
    """
    dirs = _deposit_dirs(rel_dir, teams_root, z_root)
    if debug:
        _say("dw_check_deposit", True, f"teams={dirs['teams']} | z={dirs['z']}")
    if dirs["teams"] is None and dirs["z"] is None:
        raise FileNotFoundError(
            "[cso_toolkit.dw_check_deposit] Cannot verify the inputs: neither the Teams deposit "
            "nor Z: is available.\n"
            "  The check needs teamsFolderCanonical (Teams) or dwZDrive with dw_z_available = "
            "True (Z:).\n"
            "  Fix: source the consumer profile (it sets those globals), make sure the Teams "
            "folder is synced, or connect to Z: (VPN); then rerun."
        )
    root_n = _norm(local_root)
    paths_n = [_norm(p) for p in paths]
    outside = [str(p) for p, n in zip(paths, paths_n) if not n.startswith(root_n + "/")]
    if outside:
        raise ValueError(
            f"[cso_toolkit.dw_check_deposit] {len(outside)} path(s) are not under local_root "
            f"({root_n}), so their deposit location is undefined:\n  " + "\n  ".join(outside) +
            "\n  Fix: pass the files that live under local_root, or set local_root to the folder "
            "that mirrors rel_dir."
        )
    rows = []
    for n in paths_n:
        rel = n[len(root_n) + 1:]
        size, sha = os.path.getsize(n), _sha256_file(n)
        rows.append({
            "file": rel, "sha256": sha,
            "teams": _compare(None if dirs["teams"] is None else os.path.join(dirs["teams"], rel), size, sha),
            "z": _compare(None if dirs["z"] is None else os.path.join(dirs["z"], rel), size, sha),
        })
    report = pd.DataFrame(rows, columns=["file", "sha256", "teams", "z"])
    deposited = (report["teams"] == "match") | (report["z"] == "match")
    differs = (report["teams"] == "differs") | (report["z"] == "differs")
    report["ok"] = deposited & ~differs
    table = report[["file", "teams", "z"]].to_string(index=False)

    if (~report["ok"]).any() and stop_on_fail:
        fixes = []
        if (~deposited & ~differs).any():
            fixes.append("  - missing: copy the file to the Teams deposit folder above (same relative "
                         "path) and let OneDrive sync.")
        if differs.any():
            fixes.append("  - differs: the local file and the deposited copy are not the same; decide "
                         "which is correct and replace the other.")
        raise ValueError(
            f"[cso_toolkit.dw_check_deposit] Deposit check failed for {int((~report['ok']).sum())} "
            f"of {len(report)} input file(s).\n{table}\n"
            f"  Deposit folders checked:\n{_where(dirs)}\n"
            "  Each local input needs an identical copy (same SHA-256) on Teams or Z:, at the same "
            "relative path.\n  Fix:\n" + "\n".join(fixes)
        )
    _say("dw_check_deposit", verbose, f"{int(report['ok'].sum())} of {len(report)} input file(s) "
         f"match a copy in the deposit.\n{table}\n{_where(dirs)}")
    return report


def dw_fetch_inputs(
    local_root: Union[str, os.PathLike],
    rel_dir: str,
    pattern: Optional[str] = None,
    copy: bool = True,
    gitkeep: bool = True,
    teams_root: Optional[str] = None,
    z_root: Optional[str] = None,
    verbose: Optional[bool] = None,
    debug: Optional[bool] = None,
) -> pd.DataFrame:
    """Fetch pipeline inputs from the canonical deposit, then verify them.

    Mirror of R ``dw_fetch_inputs()``. In order:

    1. Lists the input files (matching ``pattern``) in ``local_root`` and in
       the deposit folder ``<root>/<rel_dir>`` on Teams and on Z:.
    2. Stops if Teams and Z: hold different versions of the same file.
    3. Files in the deposit but not in ``local_root``: with ``copy=True``
       (default) copies them into ``local_root`` at the same relative path,
       preferring Z:, and verifies each copy's SHA-256; with ``copy=False``
       leaves ``local_root`` untouched and returns their deposit paths.
    4. With ``gitkeep=True`` (default), makes sure ``local_root`` and every
       subfolder found locally or in the deposit exist locally, each with an
       empty ``.gitkeep``. ``.gitkeep`` files are never inputs.
    5. Calls :func:`dw_check_deposit` on every local file.

    Pass the returned manifest to :func:`dw_save`'s ``metadata`` (for example
    ``metadata={"inputs": manifest[["file", "sha256", "origin"]]}``) so the
    output's sidecar names the exact inputs it was built from.

    Returns
    -------
    pandas.DataFrame
        The input manifest: ``file``, ``path`` (the full path to read),
        ``sha256``, ``origin`` (``local``, ``copied from Z:``, ``copied from
        Teams``, ``read from Z:`` or ``read from Teams``), ``teams``, ``z``.

    Raises
    ------
    FileNotFoundError
        No input file exists locally or in the deposit.
    ValueError
        Teams and Z: disagree on a file, or a local input is missing from the
        deposit or differs from it (from :func:`dw_check_deposit`).
    OSError
        A copy could not be verified.
    """
    local_root = str(local_root)
    dirs = _deposit_dirs(rel_dir, teams_root, z_root)
    if debug:
        _say("dw_fetch_inputs", True, f"local={local_root} | teams={dirs['teams']} | "
             f"z={dirs['z']} | copy={copy}")
    local_rel = _list(local_root, pattern)
    teams_rel = _list(dirs["teams"], pattern)
    z_rel = _list(dirs["z"], pattern)

    if not (local_rel or teams_rel or z_rel):
        tail = ("; the deposit is not reachable either, so also source the consumer profile, sync "
                "Teams, or connect to Z:." if dirs["teams"] is None and dirs["z"] is None else ".")
        raise FileNotFoundError(
            "[cso_toolkit.dw_fetch_inputs] No input files"
            + (f" matching '{pattern}'" if pattern else "")
            + " were found locally or in the deposit.\n"
            f"  Local: {_norm(local_root)}\n{_where(dirs)}\n"
            "  Fix: deposit the input files in the Teams folder above (same relative layout as the "
            "local folder) and rerun" + tail
        )

    for f in sorted(set(teams_rel) & set(z_rel)):
        tp, zp = os.path.join(dirs["teams"], f), os.path.join(dirs["z"], f)
        if os.path.getsize(tp) != os.path.getsize(zp) or _sha256_file(tp) != _sha256_file(zp):
            raise ValueError(
                f"[cso_toolkit.dw_fetch_inputs] Teams and Z: hold different versions of '{f}'.\n"
                f"  Teams: {tp}\n  Z:     {zp}\n"
                "  The deposit must have one version of each input before any run uses it.\n"
                "  Fix: decide which version is correct, replace the other, and rerun."
            )

    z_set = set(z_rel)
    deposit_only = sorted((z_set | set(teams_rel)) - set(local_rel))

    def src_of(f):
        return os.path.join(dirs["z"], f) if f in z_set else os.path.join(dirs["teams"], f)

    def mirror_of(f):
        return "Z:" if f in z_set else "Teams"

    copied: List[str] = []
    in_place = []
    if deposit_only and copy:
        _say("dw_fetch_inputs", verbose, f"copying {len(deposit_only)} input file(s) from the "
             f"deposit into {local_root}")
        for f in deposit_only:
            _copy(src_of(f), os.path.join(local_root, f))
            _say("dw_fetch_inputs", verbose, f"  copied {f} (from {mirror_of(f)})")
        copied = deposit_only
        local_rel = local_rel + deposit_only
    elif deposit_only:
        _say("dw_fetch_inputs", verbose, f"copy = False: reading {len(deposit_only)} input file(s) "
             "in place from the deposit")
        for f in deposit_only:
            src = src_of(f)
            sha, size = _sha256_file(src), os.path.getsize(src)
            in_place.append({
                "file": f, "path": src, "sha256": sha, "origin": f"read from {mirror_of(f)}",
                "teams": _compare(None if dirs["teams"] is None else os.path.join(dirs["teams"], f), size, sha),
                "z": _compare(None if dirs["z"] is None else os.path.join(dirs["z"], f), size, sha),
            })

    if gitkeep:
        subdirs = list(dict.fromkeys(_subdirs(local_root) + _subdirs(dirs["teams"]) + _subdirs(dirs["z"])))
        n_keep = _gitkeep(local_root, subdirs)
        if debug:
            _say("dw_fetch_inputs", True, f"gitkeep: {n_keep} placeholder(s) created under {local_root}")

    rows = list(in_place)
    if local_rel:
        local_paths = [os.path.join(local_root, f) for f in local_rel]
        report = dw_check_deposit(local_paths, local_root, rel_dir, teams_root=teams_root,
                                  z_root=z_root, verbose=verbose, debug=debug)
        for p, r in zip(local_paths, report.to_dict("records")):
            rows.append({
                "file": r["file"], "path": p, "sha256": r["sha256"],
                "origin": f"copied from {mirror_of(r['file'])}" if r["file"] in copied else "local",
                "teams": r["teams"], "z": r["z"],
            })
    manifest = pd.DataFrame(rows, columns=_STATUS_COLS)
    return manifest.sort_values("file", kind="stable").reset_index(drop=True)
