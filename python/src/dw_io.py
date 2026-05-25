"""Uniform read/write helpers for DW-Production Python pipelines.

Python port of ``r/R/dw_io.R``.  Auto-dispatch by file extension; same
mode contract (reviewer sessions cannot write to canonical without an
explicit override); same Z: drive mirror semantics; same
``.provenance.json`` sidecar emission.

Mode is a SESSION property only — set by ``dw_mode`` in
``~/.config/user_config.yml`` and read by ``profile_DW-Production.py``
into :mod:`cso_toolkit._state`.  It is NOT a per-call argument on
:func:`dw_save` / :func:`dw_use`.  Path globals
(``teamsWrkData``, ``teamsRawData``, ``dwMetaData``) are already
mode-aware in the profile; helpers below resolve through them.

Public entry points:

* :func:`dw_save` — uniform write with auto-dispatch + Z: mirror
* :func:`dw_use` — uniform read with auto-dispatch + Z: integrity check
* :func:`dw_compare` — added / removed / changed comparison
* :func:`dw_merge` — Stata-style merge with cardinality assert
* :func:`dw_resolve_path` — logical → filesystem path resolution
* :func:`dw_is_canonical` — canonical-root test
* :func:`dw_verify_z` — Teams vs Z: integrity check
* :func:`dw_isid` — Stata-style uniqueness check
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
    with open(f"{path}.provenance.json", "w", encoding="utf-8") as f:
        json.dump(prov, f, indent=2, default=str)


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
    overwrite: bool = True,
    provenance: bool = True,
    vintage: Optional[str] = None,
    allow_canonical_write: bool = False,
    mirror_to_z: bool = True,
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

    Mode contract: enforced at call site.  Writes resolving to canonical
    paths in a reviewer session raise ``PermissionError`` unless
    ``allow_canonical_write=True`` (Database Manager bootstrap).

    Z: mirror: automatic.  When ``path`` resolves under canonical AND
    ``_state.dw_z_available`` is ``True``, the primary write is
    carbon-copied to the Z: equivalent.

    Quality contract: ``isid=("col1", "col2", ...)`` runs :func:`dw_isid`
    before writing.

    Provenance sidecar: ``provenance=True`` writes
    ``<path>.provenance.json`` with timestamp, user, dw_mode, sha256,
    schema, and the user-supplied ``metadata``.

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
        If ``False``, raise when the target already exists.
    provenance
        Whether to write the ``.provenance.json`` sidecar.
    vintage
        Optional vintage tag recorded in the sidecar.
    allow_canonical_write
        Bypass the reviewer-mode guard.
    mirror_to_z
        When the write lands under canonical, carbon-copy to Z:.
    **kwargs
        Format-specific arguments passed through to the underlying writer.

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

    # Mode contract — reviewer-session must not write canonical
    is_canon = dw_is_canonical(path)
    if is_canon and not allow_canonical_write:
        if _state._get("dw_mode") == "reviewer":
            raise PermissionError(
                f"[cso_toolkit.dw_save] Reviewer mode forbids writes "
                f"under canonical: {path}\n"
                "  Reviewer sessions must keep canonical deposits read-only "
                "to preserve vintage permanence; writes go to the sandbox.\n"
                "  Fix:\n"
                "    1. Resolve a sandbox path instead (the profile's "
                "teamsWrkData usually points there in reviewer mode), OR\n"
                "    2. If this is a deliberate Database Manager bootstrap, "
                "pass `allow_canonical_write=True` to bypass the guard."
            )

    if isid is not None and isinstance(x, pd.DataFrame):
        dw_isid(x, keys=isid, where=path)

    fmt = Path(path).suffix.lower().lstrip(".")
    if compress and fmt in ("csv", "tsv", "txt") and not path.lower().endswith(".gz"):
        path = path + ".gz"

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

    if not overwrite and Path(path).exists():
        Path(tmp_path).unlink()
        raise FileExistsError(
            f"[cso_toolkit.dw_save] File exists and overwrite=False: {path}\n"
            "  Fix: pass overwrite=True to replace the existing file, "
            "or write to a different path."
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

    if is_canon and mirror_to_z:
        _dw_mirror_to_z(path)

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


def _resolve_for_read(path: str, fallback_canonical: bool) -> str:
    """Resolve a read path, falling back to canonical roots when missing."""
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
