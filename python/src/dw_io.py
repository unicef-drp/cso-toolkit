"""Uniform read/write helpers for DW-Production Python pipelines.

Toolkit version: 0.5.1

Python port of ``r/R/dw_io.R``.  Auto-dispatch by file extension; same
mode contract (reviewer sessions cannot write to canonical without an
explicit override); same Z: drive + Teams mirror semantics; same
``.provenance.json`` sidecar emission.

v0.4.0 mode-contract tightening (issue #14):

* **Producer writes are redundant**: every primary write is mirrored
  to BOTH the Z: drive AND the Teams canonical deposit.  At least one
  must be available or :func:`dw_save` hard-stops.
* **Reviewer writes are forbidden** under canonical OR Z: drive paths
  (was canonical-only).
* **Reviewer reads are network-first**: Teams → Z: → repo-local
  fallback (emits ``provenance`` warning) → hard-stop.  Producer reads
  remain local-first (v0.3.0 preserved).
* **`overwrite` default flipped** ``True → False`` for :func:`dw_save`
  — protects against silent re-write of frozen deposits.  Breaking
  change; see ``NEWS.md`` migration notes.

Mode is a SESSION property only — set by ``dw_mode`` in
``~/.config/user_config.yml`` and read by ``profile_DW-Production.py``
into :mod:`cso_toolkit._state`.  It is NOT a per-call argument on
:func:`dw_save` / :func:`dw_use`.  Path globals
(``teamsWrkData``, ``teamsRawData``, ``dwMetaData``) are already
mode-aware in the profile; helpers below resolve through them.

Public entry points:

* :func:`dw_save` — uniform write with auto-dispatch + Teams + Z: mirror
* :func:`dw_use` — uniform read with auto-dispatch + Z: integrity check
* :func:`dw_compare` — added / removed / changed comparison
* :func:`dw_merge` — Stata-style merge with cardinality assert
* :func:`dw_resolve_path` — logical → filesystem path resolution
* :func:`dw_is_canonical` — canonical-root test
* :func:`dw_verify_z` — Teams vs Z: integrity check
* :func:`dw_isid` — Stata-style uniqueness check
* :func:`dw_toolkit_version` — return the version stamp ("0.5.1")
"""

from __future__ import annotations

import datetime as _dt
import getpass
import hashlib
import json
import logging
import os
import shutil
import warnings
from pathlib import Path
from typing import Any, Iterable, Mapping, Optional, Sequence, Union

import pandas as pd

from . import _state

_log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Constants and small helpers
# ---------------------------------------------------------------------------

#: Valid kinds for :func:`dw_resolve_path`.  Mirrors the R helper.
_KINDS = ("wrk", "raw", "meta")

#: Tabular formats — :func:`dw_use` coerces these to the requested ``as_``
#: return type.
_TABULAR = ("csv", "tsv", "txt", "xlsx", "dta", "parquet")


def _sha256_file(path: Union[str, Path]) -> str:
    """Compute the sha256 hexdigest of a file by streaming 64 KiB blocks."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(65536), b""):
            h.update(block)
    return h.hexdigest()


def _utc_now_iso() -> str:
    """Return the current UTC time in ISO-8601 form (``YYYY-MM-DDTHH:MM:SS+0000``)."""
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S%z")


def _normalize(p: Union[str, Path]) -> str:
    """Forward-slash, absolute path comparison form.  Equivalent to R's
    ``normalizePath(p, winslash = "/", mustWork = FALSE)``."""
    return str(Path(p).resolve(strict=False)).replace("\\", "/")


def _dw_root_for(kind: str) -> Optional[str]:
    """Return the profile-defined root for a kind (``"wrk"`` | ``"raw"`` | ``"meta"``)."""
    if kind == "wrk":
        return _state._get("teamsWrkData")
    if kind == "raw":
        return _state._get("teamsRawData")
    if kind == "meta":
        return _state._get("dwMetaData")
    raise ValueError(
        f"[cso_toolkit.dw_io] Unknown kind: {kind!r}.\n"
        f"  Expected one of {_KINDS}.\n"
        f"  Fix: pass kind=\"wrk\" (working data), \"raw\" (raw inputs), "
        "or \"meta\" (metadata)."
    )


#: IO-contract version string — names the *behaviour-contract release*
#: that this `dw_io` exposes.  This is the version vendored consumers
#: should pin against; it is set independently of the package-build
#: versions (``r/DESCRIPTION`` Version + ``python/pyproject.toml``
#: version), which roll along the development line (e.g. R
#: ``0.3.0.9000`` and Python ``0.4.0.dev0`` until the release PR bumps
#: both to ``0.4.0``).  Exposed publicly via :func:`dw_toolkit_version`
#: so callers can stamp logs / provenance and assert minimum-contract
#: requirements in profile scripts.
_TOOLKIT_VERSION = "0.5.1"


def dw_toolkit_version() -> str:
    """Return the cso-toolkit semver in sync with R and Python sides.

    Returns
    -------
    str
        Semver string (``"0.5.1"``).

    Examples
    --------
    >>> from cso_toolkit import dw_toolkit_version
    >>> dw_toolkit_version()
    '0.5.1'
    """
    return _TOOLKIT_VERSION


# ---------------------------------------------------------------------------
# Path resolution
# ---------------------------------------------------------------------------

def dw_resolve_path(
    path: Optional[Union[str, Path]] = None,
    name: Optional[str] = None,
    sector: Optional[str] = None,
    kind: str = "wrk",
    vintage: Optional[str] = None,
) -> str:
    """Resolve a logical DW path to a filesystem path.

    Two call styles are supported:

    * Path-string — ``dw_resolve_path(path="ed/dw_ed_edu.csv", kind="wrk")``
    * Structured  — ``dw_resolve_path(name="dw_ed_edu.csv", sector="ed", kind="wrk")``

    Parameters
    ----------
    path
        Literal subpath to append to the kind's root.  Mutually exclusive
        with ``name`` / ``sector`` / ``vintage``.
    name
        File basename.  Used together with ``sector`` and optionally
        ``vintage`` to build the subpath.
    sector
        Sector folder name (e.g. ``"ed"``, ``"nt"``).  Only used when
        ``name`` is supplied.
    kind
        One of ``"wrk"``, ``"raw"``, ``"meta"``.
    vintage
        Optional subfolder (e.g. ``"2026-05"``) inserted between
        ``sector`` and ``name``.

    Returns
    -------
    str
        Absolute filesystem path.

    Raises
    ------
    ValueError
        If ``kind`` is not one of ``"wrk"`` / ``"raw"`` / ``"meta"``,
        if the kind's root is not configured (profile not loaded), or
        if neither ``path`` nor ``name`` is supplied.

    Examples
    --------
    >>> from cso_toolkit import _state, dw_resolve_path
    >>> _state.configure(teamsWrkData="/tmp/wrk")
    >>> dw_resolve_path(name="ind.csv", sector="ed", kind="wrk")
    '/tmp/wrk/ed/ind.csv'
    """
    if kind not in _KINDS:
        raise ValueError(
            f"[cso_toolkit.dw_resolve_path] kind must be one of {_KINDS}, "
            f"got {kind!r}.\n"
            f"  Fix: pass kind=\"wrk\" | \"raw\" | \"meta\"."
        )

    root = _dw_root_for(kind)
    if not root:
        global_name = {"wrk": "teamsWrkData",
                       "raw": "teamsRawData",
                       "meta": "dwMetaData"}[kind]
        raise ValueError(
            f"[cso_toolkit.dw_resolve_path] _state.{global_name} is not set.\n"
            f"  This usually means the profile script "
            f"(profile_<repo>.py) has not been imported yet, "
            f"or it didn't call cso_toolkit._state.configure({global_name}=...).\n"
            f"  Fix: import the profile first, or set the global directly:\n"
            f"    from cso_toolkit import _state\n"
            f"    _state.configure({global_name}=\"/path/to/{kind}\")"
        )

    if name is not None:
        parts = [sector or "", vintage or "", name]
        subpath = "/".join(p for p in parts if p)
    elif path is not None:
        subpath = str(path).replace("\\", "/")
    else:
        raise ValueError(
            "[cso_toolkit.dw_resolve_path] Neither `path` nor `name` supplied.\n"
            "  At least one is required to build a filesystem path.\n"
            "  Fix: pass path=\"sector/file.csv\" OR name=\"file.csv\" + sector=\"...\"."
        )

    # Collapse repeated slashes and strip leading slash
    while "//" in subpath:
        subpath = subpath.replace("//", "/")
    subpath = subpath.lstrip("/")
    return str(Path(root) / subpath).replace("\\", "/")


def dw_is_canonical(path: Union[str, Path]) -> bool:
    """Test whether a path lives under a canonical deposit root.

    Checks whether ``path`` is a descendant of any of
    ``teamsWrkDataCanonical``, ``teamsRawDataCanonical``, or
    ``teamsFolderCanonical``.

    Parameters
    ----------
    path
        Filesystem path to test (need not exist).

    Returns
    -------
    bool
        ``True`` if ``path`` lies under a canonical root.
    """
    path_n = _normalize(path)
    roots = [
        _state._get("teamsWrkDataCanonical"),
        _state._get("teamsRawDataCanonical"),
        _state._get("teamsFolderCanonical"),
    ]
    roots = [r for r in roots if r]
    if not roots:
        return False
    # Path-aware descendant check: a plain `startswith` would match
    # `/data/wrk-canary/...` against root `/data/wrk-can` (Copilot
    # finding on PR #7).  Compare equality OR root-plus-separator
    # prefix so siblings of the root cannot spoof a match.
    for r in roots:
        root_n = _normalize(r).rstrip("/")
        if path_n == root_n or path_n.startswith(root_n + "/"):
            return True
    return False


# ---------------------------------------------------------------------------
# Z: drive mirror
# ---------------------------------------------------------------------------

def _dw_z_mirror_path(path: Union[str, Path]) -> Optional[str]:
    """Translate a Teams-canonical path to its Z: drive equivalent.

    Returns ``None`` when Z: is not available or ``path`` does not lie
    under canonical.
    """
    if not _state._get("dw_z_available"):
        return None
    teams_canon = _state._get("teamsFolderCanonical")
    z_root = _state._get("dwZDrive")
    if not teams_canon or not z_root:
        return None
    tn = _normalize(teams_canon)
    zn = _normalize(z_root)
    pn = _normalize(path)
    if not pn.startswith(tn):
        return None
    rel = pn[len(tn):].lstrip("/")
    return f"{zn}/{rel}".replace("//", "/")


def _dw_mirror_to_z(primary_path: Union[str, Path], verbose: bool = True) -> Optional[str]:
    """Carbon-copy a canonical write to the Z: drive (non-blocking)."""
    z_path = _dw_z_mirror_path(primary_path)
    if z_path is None:
        return None
    try:
        Path(z_path).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(primary_path, z_path)
        if verbose:
            _log.info("[dw_save] Z: mirror -> %s", z_path)
        return z_path
    except OSError as exc:
        warnings.warn(
            f"[dw_save] Z: mirror FAILED for: {z_path} ({exc!s}) "
            "(write to Teams primary succeeded; Z: is now out of sync)",
            stacklevel=2,
        )
        return None


# ---------------------------------------------------------------------------
# v0.4.0 mirror helpers (Teams + Z: redundant writes; reviewer-mode guards)
# ---------------------------------------------------------------------------

def _dw_path_is_under_z(path: Union[str, Path]) -> bool:
    """Test whether ``path`` lies under the configured Z: drive root.

    Used by the v0.4.0 reviewer-mode write guard, which forbids reviewer
    sessions from writing under the canonical Teams deposit OR the Z:
    drive mirror (was canonical-only in v0.3.0).
    """
    z_root = _state._get("dwZDrive")
    if not z_root:
        return False
    pn = _normalize(path)
    zn = _normalize(z_root).rstrip("/")
    return pn == zn or pn.startswith(zn + "/")


def _dw_teams_mirror_path(primary_path: Union[str, Path]) -> Optional[str]:
    """Translate a repo-local primary path to its Teams-canonical equivalent.

    Walks the ``teamsWrkData -> teamsWrkDataCanonical`` and
    ``teamsRawData -> teamsRawDataCanonical`` prefix maps.  Returns
    ``None`` when none of the configured roots match (e.g. the primary
    path already lies under canonical, or it lies entirely outside any
    configured Teams root — typical of an ad-hoc / sandbox write).

    The R sibling helper is ``.dw_teams_mirror_path`` in ``dw_io.R``.
    """
    pn = _normalize(primary_path)
    pairs = [
        (_state._get("teamsWrkData"), _state._get("teamsWrkDataCanonical")),
        (_state._get("teamsRawData"), _state._get("teamsRawDataCanonical")),
    ]
    for src, dst in pairs:
        if not (src and dst):
            continue
        src_n = _normalize(src).rstrip("/")
        dst_n = _normalize(dst).rstrip("/")
        if src_n == dst_n:
            continue
        if pn == src_n or pn.startswith(src_n + "/"):
            rel = pn[len(src_n):].lstrip("/")
            return f"{dst_n}/{rel}".replace("//", "/")
    return None


def _dw_remote_mirrors(primary_path: Union[str, Path]) -> dict:
    """Derive the Teams-canonical and Z: drive paths for a primary write.

    Returns
    -------
    dict
        Keys ``"teams"`` and ``"z"``.  Each is a ``str`` filesystem path
        or ``None`` when the corresponding mirror is not available /
        configured.  In the canonical case (``primary_path`` is already
        under canonical), ``"teams"`` is the primary itself so the
        producer logic still writes Z: from it.
    """
    pn = _normalize(primary_path)
    if dw_is_canonical(pn):
        # primary IS canonical — Z: derived from primary, Teams = primary
        z = _dw_z_mirror_path(pn) if _state._get("dw_z_available") else None
        return {"teams": pn, "z": z}
    teams = _dw_teams_mirror_path(pn)
    z = None
    if teams is not None and _state._get("dw_z_available"):
        z = _dw_z_mirror_path(teams)
    return {"teams": teams, "z": z}


def _dw_mirror_to_teams(primary_path: Union[str, Path],
                        teams_path: str,
                        verbose: bool = True) -> Optional[str]:
    """Carbon-copy a producer write from its primary path to Teams canonical.

    Non-blocking: emits an envelope-shaped warning on failure but does
    NOT abort the calling :func:`dw_save`.  Mirrors the R helper
    ``.dw_mirror_to_teams``.
    """
    if teams_path == _normalize(primary_path):
        # primary already IS the Teams write — nothing to mirror
        return teams_path
    try:
        Path(teams_path).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(primary_path, teams_path)
        if verbose:
            _log.info("[dw_save] Teams mirror -> %s", teams_path)
        return teams_path
    except OSError as exc:
        warnings.warn(
            f"[cso_toolkit.dw_save] Teams mirror FAILED for: "
            f"{teams_path} ({exc!s})\n"
            "  Reason: Teams sync may be paused, the folder may be "
            "locked, or the network share is unreachable.\n"
            "  Fix: confirm the Teams folder is reachable / synced and "
            "retry; the local primary write succeeded so no data is "
            "lost — only the canonical deposit is out of sync.",
            stacklevel=2,
        )
        return None


def dw_verify_z(path: Union[str, Path], compare: str = "size") -> dict:
    """Verify a canonical Teams file matches its Z: drive mirror.

    Non-blocking: callers act on the returned ``status`` rather than
    seeing an immediate exception.

    Parameters
    ----------
    path
        Path to a file under ``teamsFolderCanonical``.
    compare
        ``"size"`` (default, fast) or ``"sha256"`` (deep).

    Returns
    -------
    dict
        Keys ``status`` plus supporting fields.  ``status`` is one of:
        ``"no_z_mirror"``, ``"z_missing"``, ``"match_size"``,
        ``"size_mismatch"``, ``"match_sha256"``, ``"sha256_mismatch"``,
        ``"verify_unavailable"``.

    Raises
    ------
    ValueError
        If ``compare`` is not ``"size"`` or ``"sha256"``.
    """
    if compare not in ("size", "sha256"):
        raise ValueError(
            f"[cso_toolkit.dw_verify_z] compare must be 'size' or 'sha256', "
            f"got {compare!r}.\n"
            "  Fix: pass compare=\"size\" (fast, default) or "
            "compare=\"sha256\" (deep, requires the file to be read)."
        )

    z_path = _dw_z_mirror_path(path)
    if z_path is None:
        return {"status": "no_z_mirror", "path": str(path), "z_path": None}
    if not Path(z_path).exists():
        return {"status": "z_missing", "path": str(path), "z_path": z_path}

    if compare == "size":
        ps = Path(path).stat().st_size
        zs = Path(z_path).stat().st_size
        return {
            "status": "match_size" if ps == zs else "size_mismatch",
            "path": str(path), "z_path": z_path,
            "primary_size": ps, "z_size": zs,
        }
    # sha256
    psha = _sha256_file(path)
    zsha = _sha256_file(z_path)
    return {
        "status": "match_sha256" if psha == zsha else "sha256_mismatch",
        "path": str(path), "z_path": z_path,
        "primary_sha": psha, "z_sha": zsha,
    }


# ---------------------------------------------------------------------------
# isid uniqueness check
# ---------------------------------------------------------------------------

def dw_isid(
    df: pd.DataFrame,
    keys: Sequence[str],
    where: str = "<unknown>",
) -> bool:
    """Stata-style uniqueness check on a key tuple.

    Raises ``ValueError`` if ``df`` has duplicate rows on the supplied
    key columns.  Inspired by Stata's ``isid`` and World Bank's
    ``edukit_save``.

    Parameters
    ----------
    df
        Data frame to check.
    keys
        Column names that should uniquely identify rows.
    where
        Context label included in the error message (typically the
        resolved output path).

    Returns
    -------
    bool
        ``True`` when the check passes.  Raises on duplicates.

    Raises
    ------
    ValueError
        When one or more ``keys`` are missing from ``df.columns``, or when
        any ``(keys)`` tuple appears more than once.  The error message
        includes a sample of up to five duplicate rows.

    Examples
    --------
    >>> import pandas as pd
    >>> from cso_toolkit import dw_isid
    >>> df = pd.DataFrame({"REF_AREA": ["AGO", "BFA"], "value": [1, 2]})
    >>> dw_isid(df, keys=["REF_AREA"])
    True
    """
    missing = [k for k in keys if k not in df.columns]
    if missing:
        present = ", ".join(df.columns[:10]) + ("..." if len(df.columns) > 10 else "")
        raise ValueError(
            f"[cso_toolkit.dw_isid] ({where}) keys not in data: "
            f"{', '.join(missing)}.\n"
            f"  Data columns are: {present}\n"
            "  Fix: check spelling / casing on the key columns, or drop "
            "non-existent keys from your isid= argument."
        )
    if len(df) == 0:
        return True
    dups = df[df.duplicated(subset=list(keys), keep=False)]
    if len(dups) > 0:
        sample = dups.sort_values(list(keys)).head(5).to_string()
        raise ValueError(
            f"[cso_toolkit.dw_isid] ({where}) {len(dups)} duplicate row(s) "
            f"on key ({', '.join(keys)}).\n"
            f"  First duplicates:\n{sample}\n"
            "  Fix: deduplicate before saving "
            "(`df = df.drop_duplicates(subset=keys)`) "
            "or extend the key set so the rows become unique."
        )
    return True


# ---------------------------------------------------------------------------
# dw_save — uniform write
# ---------------------------------------------------------------------------

def _write_csv(x: pd.DataFrame, path: str, sep: str = ",",
               na: str = "", compress: bool = False, **kwargs: Any) -> None:
    """CSV/TSV/TXT writer (pandas wrapper).  Defaults match the R helper."""
    compression: Optional[str] = "gzip" if compress else None
    x.to_csv(path, sep=sep, na_rep=na, index=False, compression=compression, **kwargs)


def _write_xlsx(x: Any, path: str, sheet: str = "Sheet1", **kwargs: Any) -> None:
    """XLSX writer.  Handles single data frame, named-dict-of-frames, or
    a pre-built ``openpyxl.Workbook`` instance."""
    try:
        from openpyxl import Workbook as _OpenpyxlWorkbook
    except ImportError as exc:  # pragma: no cover
        raise ImportError(
            "[cso_toolkit.dw_save] Writing .xlsx requires the 'openpyxl' "
            "package, which is not installed.\n"
            "  Fix: `pip install openpyxl`."
        ) from exc

    if isinstance(x, _OpenpyxlWorkbook):
        x.save(path)
        return
    if isinstance(x, dict) and all(isinstance(v, pd.DataFrame) for v in x.values()):
        with pd.ExcelWriter(path, engine="openpyxl") as writer:
            for nm, df in x.items():
                df.to_excel(writer, sheet_name=str(nm)[:31], index=False, **kwargs)
        return
    if isinstance(x, pd.DataFrame):
        with pd.ExcelWriter(path, engine="openpyxl") as writer:
            x.to_excel(writer, sheet_name=sheet, index=False, **kwargs)
        return
    raise TypeError(
        f"[cso_toolkit.dw_save] (.xlsx) Got `x` of type {type(x).__name__!r}, "
        "but .xlsx accepts only:\n"
        "  - a pandas.DataFrame (single sheet)\n"
        "  - a dict mapping sheet name -> DataFrame (multi sheet)\n"
        "  - an openpyxl.Workbook (pre-built workbook)\n"
        "  Fix: convert `x` to one of the above before calling dw_save."
    )


def _write_dta(x: pd.DataFrame, path: str, **kwargs: Any) -> None:
    """Stata .dta writer (pandas wrapper)."""
    x.to_stata(path, write_index=False, **kwargs)


def _write_parquet(x: pd.DataFrame, path: str, **kwargs: Any) -> None:
    """Parquet writer (pyarrow via pandas)."""
    x.to_parquet(path, index=False, **kwargs)


def _write_json(x: Any, path: str, **kwargs: Any) -> None:
    """JSON writer.  Pretty-prints; falls back to ``str()`` for non-JSON-able values."""
    if isinstance(x, pd.DataFrame):
        x.to_json(path, orient="records", indent=2, **kwargs)
        return
    with open(path, "w", encoding="utf-8") as f:
        json.dump(x, f, indent=2, default=str, **kwargs)


def _write_yaml(x: Any, path: str, **kwargs: Any) -> None:
    """YAML writer (PyYAML)."""
    try:
        import yaml
    except ImportError as exc:  # pragma: no cover
        raise ImportError(
            "[cso_toolkit.dw_save] Writing .yaml requires the 'PyYAML' "
            "package, which is not installed.\n"
            "  Fix: `pip install PyYAML`."
        ) from exc
    with open(path, "w", encoding="utf-8") as f:
        yaml.safe_dump(x, f, sort_keys=False, **kwargs)


def _write_pickle(x: Any, path: str, **kwargs: Any) -> None:
    """Pickle writer.  Python's analogue to R's ``saveRDS``."""
    import pickle
    with open(path, "wb") as f:
        pickle.dump(x, f, **kwargs)


def _write_provenance(
    path: str, x: Any, fmt: str,
    vintage: Optional[str], metadata: Optional[Mapping[str, Any]],
    isid: Optional[Sequence[str]],
) -> None:
    """Emit a ``.provenance.json`` sidecar alongside a saved file."""
    schema: dict = {}
    if isinstance(x, pd.DataFrame):
        schema = {"rows": int(len(x)), "cols": int(len(x.columns)),
                  "columns": list(x.columns)}
    prov = {
        "path": path,
        "format": fmt,
        "written_at": _utc_now_iso(),
        "user": os.environ.get("USERNAME") or getpass.getuser(),
        "dw_mode": _state._get("dw_mode"),
        "vintage": vintage,
        "sha256": _sha256_file(path),
        "isid": list(isid) if isid else None,
        "schema": schema,
    }
    if metadata is not None:
        prov["metadata"] = dict(metadata)
    # Wrap the sidecar write so a non-JSON-serialisable metadata value
    # (rare but possible — e.g. a numpy scalar or custom class) emits a
    # warning rather than rolling back the primary file write.  Sidecar
    # is metadata; the asset is what matters.  Backported from
    # DW-Production; see B3 in docs/dw-production-alignment-2026-05-25.md.
    try:
        with open(f"{path}.provenance.json", "w", encoding="utf-8") as f:
            json.dump(prov, f, indent=2, default=str)
    except (TypeError, OSError) as exc:
        warnings.warn(
            f"[cso_toolkit.dw_save] Provenance sidecar write failed for "
            f"{path}: {exc}\n"
            "  Primary file unaffected; metadata may contain "
            "non-serialisable objects.\n"
            "  Fix: ensure all metadata values are JSON-serialisable "
            "(atomic types, lists of atomics, or dicts thereof).",
            stacklevel=2,
        )


def dw_save(
    x: Any,
    path: Optional[Union[str, Path]] = None,
    *,
    name: Optional[str] = None,
    sector: Optional[str] = None,
    kind: str = "wrk",
    isid: Optional[Sequence[str]] = None,
    metadata: Optional[Mapping[str, Any]] = None,
    compress: bool = False,
    overwrite: bool = False,
    provenance: bool = True,
    vintage: Optional[str] = None,
    allow_canonical_write: bool = False,
    **kwargs: Any,
) -> str:
    """Save an object to disk, dispatching on the file extension.

    Supported extensions:

    ===========================  =======================================
    Extension                    Writer
    ===========================  =======================================
    ``.csv`` / ``.tsv`` / ``.txt``  ``pandas.DataFrame.to_csv``
    ``.csv.gz`` / ``.tsv.gz``       ``to_csv(compression="gzip")``
    ``.xlsx``                       ``openpyxl`` (DF or dict of DFs)
    ``.pkl`` / ``.pickle``          ``pickle.dump``
    ``.dta``                        ``pandas.DataFrame.to_stata``
    ``.parquet``                    ``pandas.DataFrame.to_parquet``
    ``.json``                       ``json.dump`` (pretty)
    ``.yml`` / ``.yaml``            ``yaml.safe_dump``
    ===========================  =======================================

    Path resolution — pick one:

    * ``path=...`` — used as-is (absolute or relative).
    * ``name=...`` + ``sector`` / ``kind`` / ``vintage`` — resolved via
      :func:`dw_resolve_path`.

    Mode contract (v0.4.0): enforced at call site.

    * **Reviewer mode** — writes resolving to canonical Teams paths OR
      Z: drive paths raise ``PermissionError`` unless
      ``allow_canonical_write=True`` (Database Manager bootstrap).
    * **Producer mode** — at least one of Teams (preferred) or Z: drive
      must be available; otherwise :func:`dw_save` hard-stops.  Every
      successful write fans out to BOTH mirrors when both are available.

    Overwrite gate (v0.4.0, breaking): ``overwrite=False`` is the new
    default.  The check examines ALL three destinations (primary, Teams
    mirror, Z: mirror) — :func:`dw_save` raises ``FileExistsError`` if
    ANY of them exists.  Pass ``overwrite=True`` for the v0.3.0
    behavior.

    Quality contract: ``isid=("col1", "col2", ...)`` runs :func:`dw_isid`
    before writing.

    Provenance sidecar: ``provenance=True`` writes
    ``<path>.provenance.json`` with timestamp, user, dw_mode, sha256,
    schema, and the user-supplied ``metadata``.  The sidecar is also
    carbon-copied to each remote mirror so reviewer sessions can verify
    provenance without round-tripping through the producer.

    Parameters
    ----------
    x
        Object to write.
    path
        Literal output path.  Mutually exclusive with ``name``.
    name
        File basename, resolved via :func:`dw_resolve_path`.
    sector, kind, vintage
        Forwarded to :func:`dw_resolve_path`.
    isid
        Key columns for the uniqueness check.
    metadata
        Mapping merged into the ``.provenance.json`` sidecar.
    compress
        Gzip CSV/TSV/TXT writes; appends ``.gz``.
    overwrite
        If ``False`` (the v0.4.0 default), raise when ANY of the three
        destinations already exists.  Set ``True`` to replace.
    provenance
        Whether to write the ``.provenance.json`` sidecar.
    vintage
        Optional vintage tag recorded in the sidecar.
    allow_canonical_write
        Bypass the reviewer-mode guard.
    **kwargs
        Format-specific arguments passed through to the underlying writer.

        .. note::
           The legacy ``mirror_to_z`` keyword (v0.3.0 and earlier) is no
           longer accepted — Z: mirror is now automatic and paired with
           the Teams mirror.  Passing it emits a deprecation warning and
           is otherwise ignored.

    Returns
    -------
    str
        The resolved output path.

    Raises
    ------
    PermissionError
        When the resolved path lands under a canonical root and the
        session is in reviewer mode without ``allow_canonical_write=True``.
        Also raised when the output directory cannot be created
        (filesystem permissions / Teams sync lock).
    ValueError
        When neither ``path`` nor ``name`` is supplied, or the file
        extension is not in the supported set.
    FileExistsError
        When the target file exists and ``overwrite=False``.
    OSError
        When the atomic rename of the tmp file to the final path fails
        (commonly because the destination is open in another process —
        e.g. Excel locking an .xlsx).

    Examples
    --------
    >>> import pandas as pd
    >>> from cso_toolkit import _state, dw_save
    >>> _state.configure(teamsWrkData="/tmp/wrk")
    >>> df = pd.DataFrame({"a": [1, 2], "b": ["x", "y"]})
    >>> out = dw_save(df, name="example.csv", sector="t", kind="wrk",
    ...               isid=["a"], metadata={"vintage": "2026-05"})
    >>> out.endswith("/wrk/t/example.csv")
    True
    """
    if path is None:
        path = dw_resolve_path(name=name, sector=sector, kind=kind, vintage=vintage)
    path = str(path)

    # v0.3.0 -> v0.4.0 deprecation: mirror_to_z used to be a kwarg, now
    # automatic.  Silently swallow + warn if a caller still passes it
    # so old client code does not break hard.
    if "mirror_to_z" in kwargs:
        kwargs.pop("mirror_to_z")
        warnings.warn(
            "[cso_toolkit.dw_save] The `mirror_to_z` keyword is deprecated "
            "as of v0.4.0 (Z: mirror is now automatic and paired with the "
            "Teams mirror).  Ignoring.",
            DeprecationWarning,
            stacklevel=2,
        )

    # --- Mode contract (v0.4.0: broadened reviewer guard) ---
    is_canon = dw_is_canonical(path)
    is_under_z = _dw_path_is_under_z(path)
    dw_mode = _state._get("dw_mode")
    is_reviewer = dw_mode == "reviewer"
    is_producer = dw_mode == "producer"

    if is_reviewer and not allow_canonical_write and (is_canon or is_under_z):
        where = "Z: drive" if is_under_z else "canonical (Teams) deposit"
        raise PermissionError(
            f"[cso_toolkit.dw_save] Reviewer mode forbids writes to "
            f"{where}: {path}\n"
            "  Reviewer sessions must keep canonical + Z: deposits "
            "read-only to preserve vintage permanence; writes go to "
            "the sandbox.\n"
            "  Fix:\n"
            "    1. Resolve a sandbox path instead (the profile's "
            "teamsWrkData usually points there in reviewer mode), OR\n"
            "    2. If this is a deliberate Database Manager bootstrap, "
            "pass `allow_canonical_write=True` to bypass the guard."
        )

    # --- Producer pre-flight (v0.4.0: at least one mirror required) ---
    mirrors = _dw_remote_mirrors(path)
    teams_mirror = mirrors["teams"]
    z_mirror = mirrors["z"]
    if is_producer and not allow_canonical_write and not is_canon:
        if teams_mirror is None and z_mirror is None:
            raise PermissionError(
                f"[cso_toolkit.dw_save] Producer-mode write requires at "
                f"least one of Teams (preferred) or Z: drive to be "
                f"available, but neither is configured / reachable "
                f"for: {path}\n"
                "  Producer outputs are redundant by design: every "
                "deposit fans out to BOTH mirrors when possible, and "
                "we refuse to ship a write that lives only on the "
                "producer's laptop.\n"
                "  Fix:\n"
                "    1. Configure _state.teamsWrkDataCanonical / "
                "teamsRawDataCanonical and ensure Teams is synced, AND/OR\n"
                "    2. Mount the Z: drive and set _state.dwZDrive + "
                "_state.dw_z_available=True, THEN re-run."
            )

    if isid is not None and isinstance(x, pd.DataFrame):
        dw_isid(x, keys=isid, where=path)

    # Compression: append .gz for CSV/TSV/TXT, and auto-enable
    # compression when the path ALREADY ends in .gz (no caller foot-gun).
    # Backported from DW-Production; see B2 in
    # docs/dw-production-alignment-2026-05-25.md.
    fmt = Path(path).suffix.lower().lstrip(".")
    path_ends_in_gz = path.lower().endswith(".gz")
    if compress and fmt in ("csv", "tsv", "txt") and not path_ends_in_gz:
        path = path + ".gz"
    elif not compress and path_ends_in_gz:
        compress = True

    try:
        Path(path).parent.mkdir(parents=True, exist_ok=True)
    except PermissionError as exc:
        raise PermissionError(
            f"[cso_toolkit.dw_save] Cannot create output directory "
            f"{Path(path).parent}.\n"
            f"  Underlying error: {exc.strerror or exc}\n"
            "  Fix: check filesystem permissions; on Windows, the Teams "
            "sync client sometimes locks folders during sync — wait or "
            "pause sync before retrying."
        ) from exc

    tmp_path = path + ".tmp"
    if Path(tmp_path).exists():
        Path(tmp_path).unlink()

    # Strip .gz for dispatch
    fmt_dispatch = Path(path.removesuffix(".gz")).suffix.lower().lstrip(".")

    if fmt_dispatch == "csv":
        _write_csv(x, tmp_path, sep=",", compress=compress, **kwargs)
    elif fmt_dispatch == "tsv":
        _write_csv(x, tmp_path, sep="\t", compress=compress, **kwargs)
    elif fmt_dispatch == "txt":
        _write_csv(x, tmp_path, sep="\t", compress=compress, **kwargs)
    elif fmt_dispatch == "xlsx":
        _write_xlsx(x, tmp_path, **kwargs)
    elif fmt_dispatch in ("pkl", "pickle"):
        _write_pickle(x, tmp_path, **kwargs)
    elif fmt_dispatch == "dta":
        _write_dta(x, tmp_path, **kwargs)
    elif fmt_dispatch == "parquet":
        _write_parquet(x, tmp_path, **kwargs)
    elif fmt_dispatch == "json":
        _write_json(x, tmp_path, **kwargs)
    elif fmt_dispatch in ("yml", "yaml"):
        _write_yaml(x, tmp_path, **kwargs)
    else:
        Path(tmp_path).unlink(missing_ok=True)
        supported = "csv, tsv, txt, xlsx, pkl, dta, parquet, json, yml, yaml"
        raise ValueError(
            f"[cso_toolkit.dw_save] Unsupported file extension "
            f"{fmt_dispatch!r} (path: {path}).\n"
            f"  Supported extensions: {supported}\n"
            "  Fix: rename the output so it has one of the supported "
            "extensions, or extend dw_save's dispatch table."
        )

    # v0.4.0 overwrite gate: refuse if ANY of primary / Teams / Z: exists.
    # The mirror destinations only count when this write will actually fan
    # out to them (producer mode + canonical / DBM bootstrap).  Reviewer
    # writes are sandbox-only, so we should not block them on the
    # existence of an unrelated Teams/Z: file at the derived path.
    will_fan_out = is_producer or (is_canon and allow_canonical_write)
    if not overwrite:
        existing = []
        if Path(path).exists():
            existing.append(("primary", path))
        if will_fan_out:
            if (teams_mirror is not None and teams_mirror != path
                    and Path(teams_mirror).exists()):
                existing.append(("Teams mirror", teams_mirror))
            if (z_mirror is not None and z_mirror != path
                    and Path(z_mirror).exists()):
                existing.append(("Z: mirror", z_mirror))
        if existing:
            Path(tmp_path).unlink(missing_ok=True)
            where = "\n    ".join(f"{label}: {p}" for label, p in existing)
            raise FileExistsError(
                f"[cso_toolkit.dw_save] Refusing to overwrite existing "
                f"deposit (overwrite=False):\n    {where}\n"
                "  Fix: pass overwrite=True to replace the deposit, or "
                "write to a different path / vintage."
            )
    try:
        Path(tmp_path).replace(path)
    except OSError as exc:
        Path(tmp_path).unlink(missing_ok=True)
        raise OSError(
            f"[cso_toolkit.dw_save] Atomic rename {tmp_path} -> {path} failed.\n"
            f"  Underlying error: {exc.strerror or exc}\n"
            "  Fix: make sure the destination is not open in another "
            "process (Excel locks .xlsx files), then retry."
        ) from exc

    if provenance and fmt_dispatch not in ("",):
        _write_provenance(path, x, fmt=fmt_dispatch,
                          vintage=vintage, metadata=metadata, isid=isid)

    # --- v0.4.0 redundant mirror fan-out ---
    # Only producer-mode writes (and DBM-bootstrap canonical writes) fan
    # out to Teams + Z:.  Reviewer-mode writes land only in the sandbox.
    if not will_fan_out:
        return path

    sidecar = f"{path}.provenance.json"
    if is_canon:
        # DBM bootstrap path: primary IS canonical, mirror to Z: only.
        if _state._get("dw_z_available"):
            mirrored = _dw_mirror_to_z(path)
            if mirrored and provenance and Path(sidecar).exists():
                try:
                    shutil.copy2(sidecar, f"{mirrored}.provenance.json")
                except OSError as exc:
                    warnings.warn(
                        f"[cso_toolkit.dw_save] Z: sidecar mirror FAILED "
                        f"for: {mirrored}.provenance.json ({exc!s})",
                        stacklevel=2,
                    )
    else:
        # Standard producer write: fan out to BOTH mirrors.
        if teams_mirror is not None:
            teams_done = _dw_mirror_to_teams(path, teams_mirror)
            if teams_done and provenance and Path(sidecar).exists():
                try:
                    shutil.copy2(sidecar, f"{teams_done}.provenance.json")
                except OSError as exc:
                    warnings.warn(
                        f"[cso_toolkit.dw_save] Teams sidecar mirror "
                        f"FAILED for: {teams_done}.provenance.json "
                        f"({exc!s})",
                        stacklevel=2,
                    )
        if z_mirror is not None:
            # Carbon-copy directly from primary (Z: structure is derived
            # from Teams canonical; we DO NOT want a stale teams_mirror
            # to seed the Z: copy).
            try:
                Path(z_mirror).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, z_mirror)
                _log.info("[dw_save] Z: mirror -> %s", z_mirror)
                if provenance and Path(sidecar).exists():
                    shutil.copy2(sidecar, f"{z_mirror}.provenance.json")
            except OSError as exc:
                warnings.warn(
                    f"[cso_toolkit.dw_save] Z: mirror FAILED for: "
                    f"{z_mirror} ({exc!s})\n"
                    "  Reason: Z: drive may be unmounted or unreachable.\n"
                    "  Fix: confirm the Z: drive is mounted and writable; "
                    "the Teams + local writes succeeded so no data is lost.",
                    stacklevel=2,
                )

    return path


# ---------------------------------------------------------------------------
# dw_use — uniform read
# ---------------------------------------------------------------------------

def _read_csv(path: str, sep: str, cols: Optional[Sequence[str]] = None,
              **kwargs: Any) -> pd.DataFrame:
    """CSV/TSV/TXT reader (pandas wrapper)."""
    return pd.read_csv(path, sep=sep, usecols=list(cols) if cols else None, **kwargs)


def _read_xlsx(path: str, sheet: Union[str, int] = 0,
               cols: Optional[Sequence[str]] = None, **kwargs: Any) -> pd.DataFrame:
    """XLSX reader (pandas → openpyxl)."""
    x = pd.read_excel(path, sheet_name=sheet, engine="openpyxl", **kwargs)
    if cols is not None:
        keep = [c for c in cols if c in x.columns]
        x = x[keep]
    return x


def _read_pickle(path: str, **kwargs: Any) -> Any:
    """Pickle reader.  Python analogue to R's ``readRDS``."""
    import pickle
    with open(path, "rb") as f:
        return pickle.load(f, **kwargs)


def _read_json(path: str, **kwargs: Any) -> Any:
    """JSON reader."""
    with open(path, encoding="utf-8") as f:
        return json.load(f, **kwargs)


def _read_yaml(path: str, **kwargs: Any) -> Any:
    """YAML reader (PyYAML)."""
    try:
        import yaml
    except ImportError as exc:  # pragma: no cover
        raise ImportError("dw_use (yaml): the 'PyYAML' package is required.") from exc
    with open(path, encoding="utf-8") as f:
        return yaml.safe_load(f, **kwargs)


# ---------------------------------------------------------------------------
# Remote-URL freeze (B1 from DW-Production alignment audit, 2026-05-25)
# ---------------------------------------------------------------------------

def _is_allowlisted_url(url: str) -> bool:
    """Return ``True`` if ``url`` matches any pattern in
    ``_state.dw_url_allowlist``.  Empty allowlist => never matches."""
    import re
    allow = _state._get("dw_url_allowlist", ())
    if not allow:
        return False
    return any(re.search(p, url) for p in allow)


def _dw_frozen_root() -> str:
    """Resolve the frozen-cache root.

    Order: ``_state.dw_frozen_root`` -> ``_state.githubFolder/_frozen``
    -> ``<cwd>/_frozen``.
    """
    root = _state._get("dw_frozen_root")
    if root:
        return str(root)
    gh = _state._get("githubFolder")
    if gh:
        return str(Path(gh) / "_frozen")
    return str(Path.cwd() / "_frozen")


def _url_to_frozen_path(url: str) -> str:
    """Map a remote URL to its filesystem path under the frozen-cache root."""
    import re
    rel = re.sub(r"^https?://", "", url)
    return str(Path(_dw_frozen_root()) / rel).replace("\\", "/")


def _write_remote_provenance(url: str, frozen_path: str) -> str:
    """Write a `.provenance.json` sidecar for a frozen remote file."""
    prov = {
        "url": url,
        "sha256": _sha256_file(frozen_path),
        "bytes": Path(frozen_path).stat().st_size,
        "fetched_at": _utc_now_iso(),
        "fetched_by": os.environ.get("USERNAME") or getpass.getuser(),
        "dw_mode": _state._get("dw_mode") or "unknown",
    }
    sidecar = f"{frozen_path}.provenance.json"
    try:
        with open(sidecar, "w", encoding="utf-8") as f:
            json.dump(prov, f, indent=2, default=str)
    except (TypeError, OSError) as exc:
        warnings.warn(
            f"[cso_toolkit.dw_use] Remote-freeze sidecar write failed for "
            f"{frozen_path}: {exc}",
            stacklevel=2,
        )
    return sidecar


def _download_and_freeze(url: str, frozen_path: str) -> str:
    """Download a URL once and freeze it under the local cache root."""
    import urllib.request
    Path(frozen_path).parent.mkdir(parents=True, exist_ok=True)
    _log.info("[dw_use:remote] Downloading: %s", url)
    urllib.request.urlretrieve(url, frozen_path)  # noqa: S310 (allowlisted)
    sidecar = _write_remote_provenance(url, frozen_path)
    _log.info("[dw_use:remote] Frozen to: %s", frozen_path)
    _log.info(
        "[dw_use:remote] COMMIT the frozen file + %s so subsequent runs are deterministic.",
        Path(sidecar).name,
    )
    return frozen_path


def _resolve_remote_url(url: str) -> str:
    """Resolve a remote URL to a frozen local path.

    Producer mode: downloads once if not already frozen.  Reviewer
    mode: refuses with the standard envelope when the frozen copy
    isn't on disk yet.
    """
    if not _is_allowlisted_url(url):
        allow = _state._get("dw_url_allowlist", ())
        allow_str = ", ".join(allow) if allow else "<empty>"
        raise PermissionError(
            f"[cso_toolkit.dw_use] URL not in `dw_url_allowlist`: {url}\n"
            f"  Configured allowlist: {allow_str}\n"
            "  Fix: extend dw_url_allowlist in the consumer's profile, "
            "e.g.\n"
            "    _state.configure(dw_url_allowlist=[\n"
            "        r'^https://raw\\.githubusercontent\\.com/your-org/',\n"
            "    ])"
        )
    frozen_path = _url_to_frozen_path(url)
    if Path(frozen_path).exists():
        _log.info("[dw_use:remote] Reading frozen: %s",
                  frozen_path.replace(_dw_frozen_root(), "<dw_frozen_root>"))
        return frozen_path
    if _state._get("dw_mode") == "reviewer":
        raise PermissionError(
            f"[cso_toolkit.dw_use:remote] Reviewer mode forbids fetching "
            f"from the network.\n"
            f"  Missing frozen copy: {frozen_path}\n"
            f"  URL:                 {url}\n"
            f"  Fix: a producer must call dw_use({url!r}) once and commit "
            "the frozen file + sidecar before the reviewer pipeline can "
            "read it."
        )
    _download_and_freeze(url, frozen_path)
    return frozen_path


def _resolve_for_read_producer(path: str, fallback_canonical: bool) -> str:
    """Producer / unknown-mode read resolution.

    Local-first: try ``path`` as-is; if missing and ``fallback_canonical``
    is ``True``, walk the ``teamsWrkData -> teamsWrkDataCanonical``
    (etc.) prefix map.  Preserves v0.3.0 behaviour exactly.
    """
    if Path(path).exists():
        return path
    if not fallback_canonical:
        raise FileNotFoundError(
            f"[cso_toolkit.dw_use] File not found and fallback_canonical=False:\n"
            f"  {path}\n"
            "  Fix: drop the fallback_canonical=False argument, "
            "or verify the path exists."
        )
    # Normalise both sides (Copilot finding on PR #7): the profile may
    # supply Windows-style roots with backslashes while `path` from
    # dw_resolve_path() has been forward-slashed.  Without
    # normalisation the prefix check would never trigger.
    path_n = _normalize(path)
    swaps = [
        (_state._get("teamsRawData"), _state._get("teamsRawDataCanonical")),
        (_state._get("teamsWrkData"), _state._get("teamsWrkDataCanonical")),
        (_state._get("teamsFolder"),  _state._get("teamsFolderCanonical")),
    ]
    attempted = [path]
    for src, dst in swaps:
        if not (src and dst and src != dst):
            continue
        src_n = _normalize(src).rstrip("/")
        dst_n = _normalize(dst).rstrip("/")
        if path_n == src_n or path_n.startswith(src_n + "/"):
            alt = dst_n + path_n[len(src_n):]
            attempted.append(alt)
            if Path(alt).exists():
                _log.info("[dw_use] Falling back to canonical: %s", alt)
                return alt
    attempted_str = "\n    ".join(attempted)
    raise FileNotFoundError(
        f"[cso_toolkit.dw_use] File not found at literal path or under "
        f"any configured canonical root.\n"
        f"  Attempted:\n    {attempted_str}\n"
        "  Fix: confirm the file was produced by the upstream pipeline, "
        "or that _state.team*Canonical globals are set to the right roots."
    )


def _resolve_for_read_reviewer(path: str, fallback_canonical: bool) -> str:
    """Reviewer-mode read resolution — network-first.

    Order (v0.4.0): Teams canonical → Z: drive mirror → repo-local
    fallback (with provenance warning) → hard-stop with envelope-shaped
    ``FileNotFoundError``.  Reviewers should never silently pick up a
    local artefact that diverged from the canonical deposit; the
    warning makes the fallback auditable.
    """
    # If the literal path IS canonical AND it exists, use it directly.
    # Otherwise derive Teams + Z: mirrors and try those first.
    pn = _normalize(path)
    if dw_is_canonical(pn) and Path(pn).exists():
        return pn

    mirrors = _dw_remote_mirrors(pn)
    teams_path = mirrors["teams"]
    z_path = mirrors["z"]

    attempted: list[str] = []

    # 1. Teams canonical
    if teams_path is not None:
        attempted.append(teams_path)
        if Path(teams_path).exists():
            _log.info("[dw_use:reviewer] Reading from Teams canonical: %s",
                      teams_path)
            return teams_path

    # 2. Z: drive mirror
    if z_path is not None:
        attempted.append(z_path)
        if Path(z_path).exists():
            _log.info("[dw_use:reviewer] Reading from Z: drive mirror: %s",
                      z_path)
            return z_path

    # 3. Repo-local fallback (with warning)
    if fallback_canonical and Path(path).exists():
        warnings.warn(
            f"[cso_toolkit.dw_use] Reviewer mode: falling back to local "
            f"copy because Teams + Z: mirrors are unavailable.\n"
            f"  Local:  {path}\n"
            f"  Teams:  {teams_path or '<not configured>'}\n"
            f"  Z:     {z_path or '<not configured>'}\n"
            "  WARNING: this local file's provenance is unverified — "
            "it may diverge from the canonical deposit.  Reconnect to "
            "Teams / Z: before publishing reviewer output.",
            stacklevel=3,
        )
        return path

    # 4. Hard stop
    attempted.append(path)
    attempted_str = "\n    ".join(attempted)
    raise FileNotFoundError(
        f"[cso_toolkit.dw_use] Reviewer mode could not resolve a read "
        f"path: file is missing in Teams, Z:, and locally.\n"
        f"  Attempted:\n    {attempted_str}\n"
        "  Fix: confirm the file exists on Teams / Z:, OR contact the "
        "sector producer to publish the missing artefact."
    )


def _resolve_for_read(path: str, fallback_canonical: bool) -> str:
    """Resolve a read path, dispatching on session mode.

    v0.4.0: reviewer sessions are network-first; producer / unknown
    sessions are local-first (v0.3.0 preserved).  Remote URLs continue
    to route through the freeze resolver regardless of mode.
    """
    # Remote URL?  Hand off to the freeze resolver.
    if path.startswith("http://") or path.startswith("https://"):
        return _resolve_remote_url(path)

    if _state._get("dw_mode") == "reviewer":
        return _resolve_for_read_reviewer(path, fallback_canonical)
    return _resolve_for_read_producer(path, fallback_canonical)


def dw_use(
    path: Optional[Union[str, Path]] = None,
    *,
    name: Optional[str] = None,
    sector: Optional[str] = None,
    kind: str = "wrk",
    cols: Optional[Sequence[str]] = None,
    as_: str = "dataframe",
    fallback_canonical: bool = True,
    verify_z: Union[bool, str] = True,
    **kwargs: Any,
) -> Any:
    """Read a file from disk, dispatching on the file extension.

    Same extension matrix and path resolution as :func:`dw_save`.  Adds a
    non-blocking Z: integrity check for canonical reads.

    Parameters
    ----------
    path
        Literal input path.  Mutually exclusive with ``name``.
    name
        File basename, resolved via :func:`dw_resolve_path`.
    sector, kind
        Forwarded to :func:`dw_resolve_path`.
    cols
        Optional column subset (for ``.csv`` / ``.tsv`` / ``.xlsx`` /
        ``.parquet``).
    as_
        Return type for tabular formats.  Currently ``"dataframe"`` is
        the only supported value; kept as a parameter for parity with
        the R helper.
    fallback_canonical
        If the literal path is missing, retry under the canonical root.
    verify_z
        ``True``, ``False``, or ``"sha256"``.  Controls the Z: integrity
        check for canonical reads.
    **kwargs
        Format-specific arguments passed through to the underlying reader.

    Returns
    -------
    object
        The loaded object.  Tabular formats are returned as a
        :class:`pandas.DataFrame`.

    Raises
    ------
    FileNotFoundError
        When the file is missing both at the literal path and (if
        ``fallback_canonical=True``) under canonical.
    ValueError
        When the file extension is not in the supported set.
    ImportError
        Lazy-raised when the format-specific reader's package
        (``openpyxl`` for .xlsx, ``PyYAML`` for .yaml) is not installed.

    Examples
    --------
    >>> from cso_toolkit import _state, dw_use  # doctest: +SKIP
    >>> _state.configure(teamsWrkData="/tmp/wrk")  # doctest: +SKIP
    >>> df = dw_use(name="example.csv", sector="t", kind="wrk")  # doctest: +SKIP
    """
    if path is None:
        path = dw_resolve_path(name=name, sector=sector, kind=kind)
    path = str(path)

    resolved = _resolve_for_read(path, fallback_canonical=fallback_canonical)

    # Z: integrity check (non-blocking)
    if verify_z and dw_is_canonical(resolved) and _state._get("dw_z_available"):
        cmp = "sha256" if verify_z == "sha256" else "size"
        res = dw_verify_z(resolved, compare=cmp)
        if res["status"] not in ("match_size", "match_sha256", "no_z_mirror"):
            warnings.warn(
                f"[dw_use] Z: integrity check failed: {res['status']}\n"
                f"  Teams: {res['path']}\n  Z:    {res.get('z_path')!s}",
                stacklevel=2,
            )

    fmt = Path(resolved.removesuffix(".gz")).suffix.lower().lstrip(".")
    if fmt == "csv":
        x = _read_csv(resolved, sep=",", cols=cols, **kwargs)
    elif fmt == "tsv":
        x = _read_csv(resolved, sep="\t", cols=cols, **kwargs)
    elif fmt == "txt":
        x = _read_csv(resolved, sep="\t", cols=cols, **kwargs)
    elif fmt == "xlsx":
        x = _read_xlsx(resolved, cols=cols, **kwargs)
    elif fmt in ("pkl", "pickle"):
        x = _read_pickle(resolved, **kwargs)
    elif fmt == "dta":
        x = pd.read_stata(resolved, columns=list(cols) if cols else None, **kwargs)
    elif fmt == "parquet":
        x = pd.read_parquet(resolved, columns=list(cols) if cols else None, **kwargs)
    elif fmt == "json":
        x = _read_json(resolved, **kwargs)
    elif fmt in ("yml", "yaml"):
        x = _read_yaml(resolved, **kwargs)
    else:
        supported = "csv, tsv, txt, xlsx, pkl, dta, parquet, json, yml, yaml"
        raise ValueError(
            f"[cso_toolkit.dw_use] Unsupported file extension {fmt!r} "
            f"(path: {resolved}).\n"
            f"  Supported extensions: {supported}\n"
            "  Fix: ensure the file has one of the supported extensions."
        )

    return x


# ---------------------------------------------------------------------------
# dw_compare — added / removed / changed
# ---------------------------------------------------------------------------

def _norm_str(s: pd.Series) -> pd.Series:
    """Trim, coerce to string, normalise missing-equivalents to ``""``."""
    out = s.astype(str).str.strip()
    out = out.where(~out.isin({"NA", "N/A", "NULL", ".", "nan", "None"}), "")
    out = out.where(~s.isna(), "")
    return out


def dw_compare(
    current: Union[pd.DataFrame, str, Path],
    reference: Union[pd.DataFrame, str, Path],
    by: Sequence[str],
    value_cols: Optional[Sequence[str]] = None,
    numeric_value_cols: Optional[Sequence[str]] = None,
    tol: float = 1e-5,
    label: str = "compare",
    write_report_to: Optional[Union[str, Path]] = None,
) -> dict:
    """Compare a current dataset against a reference.

    Three-way comparison of two data frames keyed on ``by``, returning the
    rows added on the current side, removed on the reference side, and
    value-changed rows on the intersection.  Numeric value columns use a
    tolerance-based equality; string columns normalise to trimmed strings
    with missing-equivalents (``""``, ``"NA"``, ``"N/A"``, ``"NULL"``,
    ``"."``) folded to ``""``.

    Parameters
    ----------
    current
        ``pd.DataFrame`` or path to a file (passed through :func:`dw_use`).
    reference
        Same as ``current``.
    by
        Key columns.
    value_cols
        Columns to value-compare.  Default ``None`` = all non-key columns
        present on both sides.
    numeric_value_cols
        Subset of ``value_cols`` to treat as numeric (uses ``tol``).
    tol
        Numeric tolerance.
    label
        Label used in the summary row and report filenames.
    write_report_to
        Directory to write ``<label>_summary.csv``,
        ``<label>_added_rows.csv``, ``<label>_removed_rows.csv``,
        ``<label>_changed_rows.csv``.

    Returns
    -------
    dict
        Keys ``"summary"``, ``"added"``, ``"removed"``, ``"changed"``.

    Raises
    ------
    ValueError
        When none of the supplied ``by`` columns are present in both
        ``current`` and ``reference``.
    """
    if not isinstance(current, pd.DataFrame):
        current = dw_use(current)
    if not isinstance(reference, pd.DataFrame):
        reference = dw_use(reference)

    common = [c for c in current.columns if c in reference.columns]
    by = [k for k in by if k in common]
    if not by:
        cur_cols = ", ".join(current.columns[:8]) + ("..." if len(current.columns) > 8 else "")
        ref_cols = ", ".join(reference.columns[:8]) + ("..." if len(reference.columns) > 8 else "")
        raise ValueError(
            "[cso_toolkit.dw_compare] No `by` columns are present in both "
            "sides.\n"
            f"  Current columns:   {cur_cols}\n"
            f"  Reference columns: {ref_cols}\n"
            "  Fix: pass at least one column name that appears in BOTH "
            "DataFrames as a join key."
        )

    if value_cols is None:
        value_cols = [c for c in common if c not in by]
    else:
        value_cols = [c for c in value_cols if c in common]
    numeric_value_cols = [c for c in (numeric_value_cols or []) if c in value_cols]

    # Normalise common columns
    cur = current.copy()
    ref = reference.copy()
    for c in common:
        cur[c] = _norm_str(cur[c])
        ref[c] = _norm_str(ref[c])

    # Anti-joins via indicator merge
    added = (cur.merge(ref[by].assign(_present=True), on=by, how="left")
                .query("_present.isna()", engine="python")
                .drop(columns=["_present"]))
    removed = (ref.merge(cur[by].assign(_present=True), on=by, how="left")
                  .query("_present.isna()", engine="python")
                  .drop(columns=["_present"]))

    # Inner join with suffixes on value columns
    joined = ref[by + list(value_cols)].merge(
        cur[by + list(value_cols)], on=by, how="inner",
        suffixes=("_reference", "_current"),
    )

    def _values_equal(a: pd.Series, b: pd.Series, is_numeric: bool) -> pd.Series:
        both_missing = (a == "") & (b == "")
        if is_numeric:
            an = pd.to_numeric(a, errors="coerce")
            bn = pd.to_numeric(b, errors="coerce")
            both_num = an.notna() & bn.notna()
            num_eq = both_num & ((an - bn).abs() <= tol)
            both_str = an.isna() & bn.isna()
            str_eq = both_str & (a == b)
            return both_missing | num_eq | str_eq
        return both_missing | (a == b)

    for vc in value_cols:
        joined[f"changed_{vc}"] = ~_values_equal(
            joined[f"{vc}_reference"], joined[f"{vc}_current"],
            is_numeric=vc in numeric_value_cols,
        )

    changed_mask = joined[[c for c in joined.columns if c.startswith("changed_")]].any(axis=1)
    changed = joined[changed_mask]

    summary = pd.DataFrame([{
        "label": label,
        "reference_rows": len(reference),
        "current_rows": len(current),
        "row_delta": len(current) - len(reference),
        "added": len(added),
        "removed": len(removed),
        "changed": len(changed),
        "completed_at": _dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    }])

    if write_report_to is not None:
        out = Path(write_report_to)
        out.mkdir(parents=True, exist_ok=True)
        summary.to_csv(out / f"{label}_summary.csv", index=False)
        added.to_csv(out / f"{label}_added_rows.csv", index=False)
        removed.to_csv(out / f"{label}_removed_rows.csv", index=False)
        changed.to_csv(out / f"{label}_changed_rows.csv", index=False)

    return {"summary": summary, "added": added, "removed": removed, "changed": changed}


# ---------------------------------------------------------------------------
# dw_merge — Stata-style merge
# ---------------------------------------------------------------------------

def dw_merge(
    x: pd.DataFrame,
    using: Union[pd.DataFrame, str, Path],
    by: Sequence[str],
    how: str = "m:1",
    **kwargs: Any,
) -> pd.DataFrame:
    """Stata-style merge with cardinality assertion.

    Thin wrapper around ``pd.DataFrame.merge(how="left")`` that warns
    when the actual cardinality of ``by`` on the left or right side
    disagrees with the declared ``how``.  Inspired by Stata's
    ``merge m:1 / 1:1 / 1:m / m:m``.

    Parameters
    ----------
    x
        Left-hand data frame.
    using
        Right-hand data frame, OR a path passed through :func:`dw_use`.
    by
        Join keys.
    how
        One of ``"m:1"``, ``"1:1"``, ``"1:m"``, ``"m:m"``.
    **kwargs
        Passed to ``pd.DataFrame.merge``.

    Returns
    -------
    pd.DataFrame

    Warns
    -----
    UserWarning
        When the observed cardinality of ``by`` on either side disagrees
        with the declared ``how``.

    Raises
    ------
    ValueError
        When ``how`` is not one of ``"m:1"`` / ``"1:1"`` / ``"1:m"`` /
        ``"m:m"``.
    """
    if how not in ("m:1", "1:1", "1:m", "m:m"):
        raise ValueError(
            f"[cso_toolkit.dw_merge] `how` must be one of "
            "'m:1', '1:1', '1:m', 'm:m'; "
            f"got {how!r}.\n"
            "  Fix: pass the Stata-style cardinality string matching your "
            "data — most commonly 'm:1' (left has many rows, right has one "
            "per key, e.g. attaching country metadata)."
        )
    y = dw_use(using) if not isinstance(using, pd.DataFrame) else using

    x_dup = x[list(by)].duplicated().any()
    y_dup = y[list(by)].duplicated().any()
    expected_x = how in ("m:1", "m:m")
    expected_y = how in ("1:m", "m:m")
    if bool(x_dup) != expected_x:
        warnings.warn(
            f"dw_merge: left-side duplicates on `by` ({','.join(by)}) "
            f"do not match how={how!r}",
            stacklevel=2,
        )
    if bool(y_dup) != expected_y:
        warnings.warn(
            f"dw_merge: right-side duplicates on `by` ({','.join(by)}) "
            f"do not match how={how!r}",
            stacklevel=2,
        )

    return x.merge(y, on=list(by), how="left", **kwargs)
