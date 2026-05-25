"""Uniform mode-aware wrapper around external API fetches.

Python port of ``r/R/dw_api.R``.  Companion to :mod:`cso_toolkit.dw_io`.
Pipeline scripts call :func:`dw_api_fetch` instead of ``requests.get`` /
``sdmx1.Client`` / ``wbgapi.data.fetch`` directly.  The wrapper:

* In a **producer** session, hits the live API, caches the response to the
  deposit via :func:`cso_toolkit.dw_save` (which mirrors to Z: and emits a
  ``.provenance.json`` sidecar), and returns the result.
* In a **reviewer** session, reads from the deposit cache; if missing,
  raises :class:`PermissionError` (the Python analogue of R's
  ``dw_require_no_api()`` stop).
* Records every fetch in the cache's ``.provenance.json`` sidecar
  (endpoint, params, fetched_at, user, mode, sha256).

Cache layout in the deposit::

    teamsRawData/_apis/<api>/<cache_key>.<ext>
    teamsRawData/_apis/<api>/<cache_key>.<ext>.provenance.json

Cache freshness: never expires automatically.  Refresh is explicit
(``refresh=True``).  The DBM owns refresh cadence per cache.

Supported ``api`` values:

* ``"uis"`` — UNESCO UIS indicators / generic JSON endpoints
* ``"sdmx"`` — SDMX data fetch (any provider + flowRef)
* ``"sdmx_codelist"`` — SDMX codelist GET + JSON parse
* ``"wb"`` — World Bank ``wbgapi.data.fetch``
* ``"ilo"`` — ILO SDMX
* ``"unsd_sdg"`` — UNSD SDG API: POST with form-encoded seriesCodes
* ``"github_raw"`` — pinned-commit raw.githubusercontent.com fetch
* ``"http"`` — generic HTTP GET returning text
* ``"json_get"`` — generic JSON GET → parsed object
"""

from __future__ import annotations

import datetime as _dt
import json
import logging
import time
from pathlib import Path
from typing import Any, Iterable, Mapping, Optional, Sequence, Union

import pandas as pd

from . import _state
from .dw_io import dw_save, dw_use

_log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Cache path resolution
# ---------------------------------------------------------------------------

def _dw_api_cache_path(api: str, cache_key: str, ext: str = "csv") -> str:
    """Sandbox cache path for an API fetch."""
    root = _state._get("teamsRawData")
    if not root:
        raise ValueError("dw_api: teamsRawData state not defined (profile not loaded?)")
    return str(Path(root) / "_apis" / api / f"{cache_key}.{ext}").replace("\\", "/")


def _dw_api_default_ext(api: str) -> str:
    """Per-API default cache extension."""
    # Shapes that don't serialise cleanly to CSV go to pickle.
    if api in ("wb_indicators", "json_get"):
        return "pkl"
    return "csv"


def _dw_api_canonical_cache_path(api: str, cache_key: str, ext: str = "csv") -> str:
    """Canonical (read-fallback) cache path for an API fetch."""
    root = _state._get("teamsRawDataCanonical")
    if not root:
        raise ValueError("dw_api: teamsRawDataCanonical not defined (profile not loaded?)")
    return str(Path(root) / "_apis" / api / f"{cache_key}.{ext}").replace("\\", "/")


# ---------------------------------------------------------------------------
# Reviewer-mode guard
# ---------------------------------------------------------------------------

def _dw_require_no_api(api_name: str, reason: str) -> None:
    """Raise the reviewer-mode lockout error.  Python analogue of R's
    ``dw_require_no_api()``."""
    raise PermissionError(
        f"[dw_api] Reviewer mode forbids live API calls.\n"
        f"  Call: {api_name}\n"
        f"  Reason: {reason}\n"
        "  Switch to producer mode (`_state.dw_apis_allowed = True`) to fetch."
    )


# ---------------------------------------------------------------------------
# dw_api_fetch — main entry point
# ---------------------------------------------------------------------------

def dw_api_fetch(
    api: str,
    cache_key: str,
    *,
    refresh: bool = False,
    ext: Optional[str] = None,
    metadata: Optional[Mapping[str, Any]] = None,
    **kwargs: Any,
) -> Any:
    """Fetch from an external API, mode-aware, with deposit cache.

    Behaviour by session mode:

    * **Producer**, cache present, ``refresh=False`` — reads the cache.
    * **Producer**, ``refresh=True`` OR cache missing — hits the live
      API, writes the cache via :func:`cso_toolkit.dw_save` (which
      mirrors to Z: when mapped and emits a ``.provenance.json``
      sidecar), and returns the result.
    * **Reviewer** — reads the cache from the canonical deposit; if
      missing, raises :class:`PermissionError`.

    Parameters
    ----------
    api
        API identifier (see module docstring for supported values).
    cache_key
        Short snake_case identifier used as the cache filename basename.
    refresh
        Hit the API even when a cache exists (producer only).
    ext
        Cache file extension.  Defaults to the per-API default.
    metadata
        Mapping merged into the cache's ``.provenance.json`` sidecar.
    **kwargs
        API-specific arguments — see the per-API helpers below.

    Returns
    -------
    object
        Fetched (or cached) object, typed per the API's shape.
    """
    if ext is None:
        ext = _dw_api_default_ext(api)

    cache_path = _dw_api_cache_path(api, cache_key, ext)
    canonical_cache_path = _dw_api_canonical_cache_path(api, cache_key, ext)

    if not refresh:
        hit = None
        if Path(cache_path).exists():
            hit = cache_path
        elif Path(canonical_cache_path).exists():
            hit = canonical_cache_path
        if hit is not None:
            _log.info("[dw_api/%s/%s] cache hit: %s", api, cache_key, hit)
            return dw_use(hit)

    if not _state._get("dw_apis_allowed"):
        _dw_require_no_api(
            api_name=f"dw_api_fetch({api!r}, cache_key={cache_key!r})",
            reason=f"cache missing at {canonical_cache_path}",
        )

    _log.info("[dw_api/%s/%s] fetching live...", api, cache_key)
    t0 = time.time()

    fetcher = _DISPATCH.get(api)
    if fetcher is None:
        raise ValueError(
            f"dw_api_fetch: unsupported api {api!r}.  Supported: {', '.join(_DISPATCH)}"
        )
    result = fetcher(**kwargs)
    elapsed = time.time() - t0

    api_metadata = {
        "api": api,
        "cache_key": cache_key,
        "fetched_at": _dt.datetime.now(_dt.timezone.utc).strftime(
            "%Y-%m-%dT%H:%M:%S%z"
        ),
        "elapsed_secs": round(elapsed, 3),
        "refresh_flag": bool(refresh),
        "fetch_args": dict(kwargs),
    }
    if metadata is not None:
        api_metadata.update(metadata)

    dw_save(result, path=cache_path, metadata=api_metadata, mirror_to_z=True)
    return result


# ---------------------------------------------------------------------------
# dw_api_cached — explicit cache-only read
# ---------------------------------------------------------------------------

def dw_api_cached(api: str, cache_key: str, ext: str = "csv") -> Any:
    """Read an API cache without fetching.

    Cache-only counterpart to :func:`dw_api_fetch`.  Always reads from
    the canonical cache root and raises :class:`FileNotFoundError` if
    no cache exists — useful in analysis scripts that must remain
    reproducible without network access.

    Parameters
    ----------
    api
        API identifier.
    cache_key
        Cache filename basename.
    ext
        File extension.

    Returns
    -------
    object
        The cached object.
    """
    cache_path = _dw_api_canonical_cache_path(api, cache_key, ext)
    if not Path(cache_path).exists():
        raise FileNotFoundError(
            f"dw_api_cached: no cache at {cache_path}\n"
            "  Use dw_api_fetch() (producer mode) to populate."
        )
    return dw_use(cache_path)


# ---------------------------------------------------------------------------
# dw_api_inventory — list cached fetches
# ---------------------------------------------------------------------------

def dw_api_inventory(api: Optional[str] = None) -> pd.DataFrame:
    """List all cached API fetches under the canonical root.

    Walks ``teamsRawDataCanonical/_apis/<api>/`` and returns a row per
    cache file (excluding ``.provenance.json`` sidecars).  When a sidecar
    is present, its ``metadata.fetched_at`` is pulled into the result for
    auditability.

    Parameters
    ----------
    api
        Optional API filter.

    Returns
    -------
    pd.DataFrame
        Columns ``api``, ``cache_key``, ``ext``, ``size_bytes``,
        ``mtime``, ``fetched_at``.  Empty if no caches exist.
    """
    root_str = _state._get("teamsRawDataCanonical")
    if not root_str:
        return pd.DataFrame()
    root = Path(root_str) / "_apis"
    if not root.is_dir():
        return pd.DataFrame()

    apis = [api] if api else sorted(p.name for p in root.iterdir() if p.is_dir())

    rows = []
    for a in apis:
        dirp = root / a
        if not dirp.is_dir():
            continue
        for f in sorted(dirp.iterdir()):
            if f.name.endswith(".provenance.json"):
                continue
            fetched_at: Optional[str] = None
            prov_path = f.with_name(f.name + ".provenance.json")
            if prov_path.exists():
                try:
                    with open(prov_path, encoding="utf-8") as fh:
                        prov = json.load(fh)
                    fetched_at = (
                        prov.get("metadata", {}).get("fetched_at")
                        or prov.get("written_at")
                    )
                except (OSError, json.JSONDecodeError):
                    fetched_at = None
            st = f.stat()
            rows.append({
                "api": a,
                "cache_key": f.stem.replace(".csv", "").replace(".pkl", ""),
                "ext": f.suffix.lstrip("."),
                "size_bytes": st.st_size,
                "mtime": _dt.datetime.fromtimestamp(st.st_mtime).strftime(
                    "%Y-%m-%d %H:%M:%S"
                ),
                "fetched_at": fetched_at,
            })

    return pd.DataFrame(rows) if rows else pd.DataFrame()


# ---------------------------------------------------------------------------
# Per-API fetchers
# ---------------------------------------------------------------------------

def _require(pkg: str, install_name: Optional[str] = None) -> Any:
    """Import a package with a uniform install hint on failure."""
    import importlib
    try:
        return importlib.import_module(pkg)
    except ImportError as exc:
        name = install_name or pkg
        raise ImportError(
            f"dw_api: package {pkg!r} is required for this API. "
            f"Install via `pip install {name}`."
        ) from exc


def _fetch_uis(endpoint: str = "indicators",
               params: Optional[Mapping[str, Any]] = None, **_: Any) -> pd.DataFrame:
    """UNESCO UIS API fetcher.  Parses JSON; unwraps ``records`` when present."""
    requests = _require("requests")
    base = "https://api.uis.unesco.org/api/public/data/"
    resp = requests.get(base + endpoint, params=dict(params or {}), timeout=120)
    resp.raise_for_status()
    body = resp.json()
    records = body.get("records") if isinstance(body, dict) else None
    if records is not None:
        return pd.DataFrame(records)
    return body  # type: ignore[return-value]


def _fetch_sdmx(providerId: str, flowRef: str, key: str,
                version: str = "1.0", start: Optional[str] = None,
                end: Optional[str] = None, **_: Any) -> pd.DataFrame:
    """SDMX data fetcher via the ``sdmx1`` package."""
    sdmx = _require("sdmx", install_name="sdmx1")
    client = sdmx.Client(providerId)
    params: dict = {}
    if start is not None:
        params["startPeriod"] = start
    if end is not None:
        params["endPeriod"] = end
    msg = client.data(flowRef, key=key, params=params)
    return sdmx.to_pandas(msg).reset_index()


def _fetch_sdmx_codelist(agency: str, codelist: str, version: str = "1.0",
                         **_: Any) -> pd.DataFrame:
    """SDMX codelist fetcher (UNICEF SDMX REST + JSON parse)."""
    requests = _require("requests")
    url = (
        "https://sdmx.data.unicef.org/ws/public/sdmxapi/rest/codelist/"
        f"{agency}/{codelist}/{version}"
        "?format=sdmx-json&detail=full&references=none"
    )
    resp = requests.get(url, timeout=60)
    resp.raise_for_status()
    body = resp.json()
    codes = body["data"]["codelists"][0]["codes"]

    def _desc(c: dict) -> Optional[str]:
        d = c.get("description")
        if d is None:
            return None
        if isinstance(d, dict):
            return d.get("en")
        if isinstance(d, str):
            return d
        return None

    return pd.DataFrame({
        "code": [c["id"] for c in codes],
        "name": [c["names"]["en"] for c in codes],
        "description": [_desc(c) for c in codes],
    })


def _fetch_wb(indicator: Union[str, Sequence[str]],
              start_date: int = 2000,
              end_date: Optional[int] = None, **_: Any) -> pd.DataFrame:
    """World Bank data fetcher via the ``wbgapi`` package."""
    wb = _require("wbgapi")
    end_date = end_date or _dt.date.today().year
    return wb.data.DataFrame(
        indicator,
        time=range(start_date, end_date + 1),
        labels=True,
    ).reset_index()


def _fetch_wb_indicators(**_: Any) -> pd.DataFrame:
    """World Bank indicator catalogue via ``wbgapi``."""
    wb = _require("wbgapi")
    return wb.series.list().to_frame()


def _fetch_ilo(flowRef: str, key: str,
               start: Optional[str] = None, end: Optional[str] = None,
               **_: Any) -> pd.DataFrame:
    """ILO SDMX fetcher."""
    return _fetch_sdmx(providerId="ILO", flowRef=flowRef, key=key,
                       version="1.0", start=start, end=end)


def _fetch_unsd_sdg(series_codes: Sequence[str],
                    endpoint: str = "https://unstats.un.org/SDGAPI/v1/sdg/Series/DataCSV",
                    **_: Any) -> pd.DataFrame:
    """UNSD SDG API fetcher.  POSTs form-encoded ``seriesCodes`` and parses CSV."""
    import io
    requests = _require("requests")
    body = "&".join(f"seriesCodes={s}" for s in series_codes)
    resp = requests.post(
        endpoint,
        data=body,
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/octet-stream",
        },
        timeout=300,
    )
    resp.raise_for_status()
    return pd.read_csv(io.StringIO(resp.text))


def _fetch_github_raw(owner_repo: str, ref: str = "main",
                      path: Optional[str] = None, **_: Any) -> Any:
    """Pinned-commit ``raw.githubusercontent.com`` fetcher."""
    if path is None:
        raise ValueError("github_raw: `path` is required")
    requests = _require("requests")
    url = f"https://raw.githubusercontent.com/{owner_repo}/{ref}/{path}"
    resp = requests.get(url, timeout=60)
    resp.raise_for_status()
    ext = Path(path).suffix.lower().lstrip(".")
    if ext == "csv":
        import io as _io
        return pd.read_csv(_io.StringIO(resp.text))
    if ext == "tsv":
        import io as _io
        return pd.read_csv(_io.StringIO(resp.text), sep="\t")
    if ext == "json":
        return resp.json()
    return resp.text.splitlines()


def _fetch_http(url: str, headers: Optional[Mapping[str, str]] = None,
                **_: Any) -> str:
    """Generic HTTP GET returning text."""
    requests = _require("requests")
    resp = requests.get(url, headers=dict(headers or {}), timeout=120)
    resp.raise_for_status()
    return resp.text


def _fetch_json_get(url: str, **_: Any) -> Any:
    """Generic JSON GET → parsed object."""
    requests = _require("requests")
    resp = requests.get(url, timeout=120)
    resp.raise_for_status()
    return resp.json()


#: Dispatch table mapping ``api`` argument to internal fetcher.
_DISPATCH = {
    "uis": _fetch_uis,
    "sdmx": _fetch_sdmx,
    "sdmx_codelist": _fetch_sdmx_codelist,
    "wb": _fetch_wb,
    "wb_indicators": _fetch_wb_indicators,
    "ilo": _fetch_ilo,
    "unsd_sdg": _fetch_unsd_sdg,
    "github_raw": _fetch_github_raw,
    "http": _fetch_http,
    "json_get": _fetch_json_get,
}
