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
# Secret redaction for provenance sidecars (Copilot finding on PR #7)
# ---------------------------------------------------------------------------

#: Sensitive key substrings.  When a fetch_arg key (case-insensitive)
#: contains any of these, the corresponding value is replaced with
#: ``"<redacted>"`` in the persisted ``.provenance.json`` so credentials
#: passed by the caller never reach disk.
_REDACT_SUBSTRINGS = (
    "token", "auth", "password", "passwd", "secret",
    "api_key", "apikey", "client_secret", "headers", "cookie",
    "bearer", "private",
)


def _redact_sensitive(d: Any) -> Any:
    """Return a copy of ``d`` with sensitive values replaced by ``"<redacted>"``.

    Walks dicts recursively.  Keys whose lowercased form contains any
    entry in :data:`_REDACT_SUBSTRINGS` get their value replaced.
    Lists / tuples / scalars are walked but only dict-keys drive
    redaction decisions.
    """
    if isinstance(d, dict):
        out: dict = {}
        for k, v in d.items():
            if any(s in str(k).lower() for s in _REDACT_SUBSTRINGS):
                out[k] = "<redacted>"
            else:
                out[k] = _redact_sensitive(v)
        return out
    if isinstance(d, (list, tuple)):
        return type(d)(_redact_sensitive(x) for x in d)
    return d


# ---------------------------------------------------------------------------
# Cache path resolution
# ---------------------------------------------------------------------------

def _dw_api_cache_path(api: str, cache_key: str, ext: str = "csv") -> str:
    """Sandbox cache path for an API fetch."""
    root = _state._get("teamsRawData")
    if not root:
        raise ValueError(
            "[cso_toolkit.dw_api] _state.teamsRawData is not set.\n"
            "  This means the profile script (profile_<repo>.py) has not "
            "been imported, or it didn't call cso_toolkit._state.configure("
            "teamsRawData=...).\n"
            "  Fix: import the profile first, OR set the global directly:\n"
            "    from cso_toolkit import _state\n"
            "    _state.configure(teamsRawData=\"/path/to/raw\")"
        )
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
        raise ValueError(
            "[cso_toolkit.dw_api] _state.teamsRawDataCanonical is not set.\n"
            "  Reviewer-mode reads fall back to this canonical root when "
            "the sandbox cache is missing.\n"
            "  Fix: set _state.teamsRawDataCanonical to the read-only "
            "Teams root that holds the deposit's _apis/ folder."
        )
    return str(Path(root) / "_apis" / api / f"{cache_key}.{ext}").replace("\\", "/")


# ---------------------------------------------------------------------------
# Reviewer-mode guard
# ---------------------------------------------------------------------------

def _dw_require_no_api(api_name: str, reason: str) -> None:
    """Raise the reviewer-mode lockout error.  Python analogue of R's
    ``dw_require_no_api()``."""
    raise PermissionError(
        "[cso_toolkit.dw_api] Reviewer mode forbids live API calls.\n"
        f"  Call:   {api_name}\n"
        f"  Reason: {reason}\n"
        "  Fix:\n"
        "    1. The expected workflow is that a Database Manager has "
        "already populated the cache under teamsRawDataCanonical/_apis/. "
        "Verify the cache file exists at the path above.\n"
        "    2. If you ARE the producer, switch modes:\n"
        "       from cso_toolkit import _state\n"
        "       _state.configure(dw_mode=\"producer\", dw_apis_allowed=True)"
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

    Raises
    ------
    PermissionError
        When ``dw_apis_allowed`` is ``False`` (reviewer mode) and no
        cache exists for the requested ``api`` / ``cache_key`` / ``ext``.
    ValueError
        When ``api`` is not in the dispatch table, or when one of the
        underlying state globals (``teamsRawData``,
        ``teamsRawDataCanonical``) is unset.
    ImportError
        Lazy-raised when the per-API helper needs a package
        (``requests``, ``sdmx1``, ``wbgapi``) that is not installed.
    TimeoutError, ConnectionError
        When the live HTTP call fails to reach the upstream API.
    RuntimeError
        When the upstream returns a non-success HTTP status, an
        unexpected body shape, or a body that the per-API parser
        cannot handle.

    Examples
    --------
    >>> from cso_toolkit import _state, dw_api_fetch  # doctest: +SKIP
    >>> _state.configure(  # doctest: +SKIP
    ...     teamsRawData="/data/raw",
    ...     teamsRawDataCanonical="/data/raw-canonical",
    ...     dw_apis_allowed=True,
    ... )
    >>> codebook = dw_api_fetch(  # doctest: +SKIP
    ...     api="sdmx_codelist",
    ...     agency="UNICEF", codelist="CL_RESIDENCE", version="1.0",
    ...     cache_key="sdmx_codelist_UNICEF_CL_RESIDENCE_1_0",
    ... )
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
            f"[cso_toolkit.dw_api_fetch] Unsupported api {api!r}.\n"
            f"  Supported: {', '.join(sorted(_DISPATCH))}\n"
            "  Fix: pass one of the supported strings as `api=`, or add a "
            "new entry to the _DISPATCH table in dw_api.py."
        )
    try:
        result = fetcher(**kwargs)
    except (TypeError, KeyError) as exc:
        raise RuntimeError(
            f"[cso_toolkit.dw_api_fetch] Fetcher for api={api!r} raised "
            f"{type(exc).__name__}: {exc}\n"
            f"  Cache key: {cache_key}\n"
            f"  Fetch args: {kwargs}\n"
            "  Fix: this usually means the upstream API changed its "
            "response shape, or the kwargs passed to dw_api_fetch don't "
            "match the per-API helper signature. Check the underlying "
            "fetcher in dw_api.py (_fetch_*) and update if needed."
        ) from exc
    elapsed = time.time() - t0

    api_metadata = {
        "api": api,
        "cache_key": cache_key,
        "fetched_at": _dt.datetime.now(_dt.timezone.utc).strftime(
            "%Y-%m-%dT%H:%M:%S%z"
        ),
        "elapsed_secs": round(elapsed, 3),
        "refresh_flag": bool(refresh),
        # Redact known sensitive keys so credentials passed via kwargs
        # (token=..., headers={"Authorization": ...}) never land on disk.
        "fetch_args": _redact_sensitive(dict(kwargs)),
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

    Raises
    ------
    FileNotFoundError
        When no cache exists at the canonical path for the requested
        ``api`` / ``cache_key`` / ``ext``.
    ValueError
        When ``_state.teamsRawDataCanonical`` is not set.
    """
    cache_path = _dw_api_canonical_cache_path(api, cache_key, ext)
    if not Path(cache_path).exists():
        raise FileNotFoundError(
            f"[cso_toolkit.dw_api_cached] No cache at {cache_path}\n"
            "  Reason: the cached fetch has not been produced yet (or the "
            "wrong api / cache_key / ext was passed).\n"
            "  Fix:\n"
            "    1. Ask the Database Manager to run dw_api_fetch("
            f"api={api!r}, cache_key={cache_key!r}, ...) in producer mode, "
            "or\n"
            "    2. Verify api/cache_key/ext spelling: an `ext` mismatch "
            "is a common cause."
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
            f"[cso_toolkit.dw_api] This API needs the {pkg!r} package, "
            "which is not installed.\n"
            f"  Fix: `pip install {name}`."
        ) from exc


def _http_call(method: str, url: str, **kwargs: Any) -> Any:
    """Wrap requests.{get,post} with a uniform error envelope.

    Translates ``requests.RequestException`` subclasses into the same
    "what / why / how" message format used everywhere else in the
    toolkit.  Returns the ``Response`` object on success.
    """
    requests = _require("requests")
    try:
        resp = getattr(requests, method)(url, **kwargs)
        resp.raise_for_status()
        return resp
    except requests.Timeout as exc:
        raise TimeoutError(
            f"[cso_toolkit.dw_api] HTTP {method.upper()} timed out: {url}\n"
            f"  Underlying error: {exc}\n"
            "  Fix: extend the timeout (`timeout=...` kwarg) or retry "
            "later. If this is a UNICEF-laptop corporate-network issue, "
            "try a different network — corporate proxies sometimes block "
            "long-lived API calls invisibly."
        ) from exc
    except requests.ConnectionError as exc:
        raise ConnectionError(
            f"[cso_toolkit.dw_api] HTTP {method.upper()} could not reach: {url}\n"
            f"  Underlying error: {exc}\n"
            "  Fix: verify network reachability; if on the UNICEF "
            "corporate network, try a personal hotspot or VPN. The "
            "corporate proxy may silently block this host."
        ) from exc
    except requests.HTTPError as exc:
        status = getattr(exc.response, "status_code", "?")
        body_snippet = ""
        if getattr(exc, "response", None) is not None:
            body_snippet = (exc.response.text or "")[:300]
        raise RuntimeError(
            f"[cso_toolkit.dw_api] HTTP {method.upper()} {url} returned "
            f"status {status}.\n"
            f"  Body (truncated): {body_snippet!r}\n"
            "  Fix: check the API's docs for that status code; common "
            "causes are bad query parameters (400), missing auth (401/403), "
            "missing cache_key (404), or rate limiting (429)."
        ) from exc


def _fetch_uis(endpoint: str = "indicators",
               params: Optional[Mapping[str, Any]] = None, **_: Any) -> pd.DataFrame:
    """UNESCO UIS API fetcher.  Parses JSON; unwraps ``records`` when present."""
    base = "https://api.uis.unesco.org/api/public/data/"
    url = base + endpoint
    resp = _http_call("get", url, params=dict(params or {}), timeout=120)
    try:
        body = resp.json()
    except ValueError as exc:
        raise RuntimeError(
            f"[cso_toolkit.dw_api/_fetch_uis] UIS API returned non-JSON "
            f"body (URL: {url}).\n"
            f"  First 300 chars: {(resp.text or '')[:300]!r}\n"
            "  Fix: verify the endpoint name; the UIS API redirects bad "
            "endpoints to an HTML error page."
        ) from exc
    records = body.get("records") if isinstance(body, dict) else None
    if records is not None:
        return pd.DataFrame(records)
    # Some UIS endpoints return a top-level array; coerce.
    if isinstance(body, list):
        return pd.DataFrame(body)
    # Last resort: dict-of-scalars can be one-row.  Anything else
    # (deeply nested) doesn't fit the default CSV cache and would
    # crash later inside dw_save.  Raise here with a useful hint.
    if isinstance(body, dict) and all(
        not isinstance(v, (list, dict)) for v in body.values()
    ):
        return pd.DataFrame([body])
    raise RuntimeError(
        f"[cso_toolkit.dw_api/_fetch_uis] UIS endpoint {endpoint!r} returned "
        f"a non-tabular response (top-level type {type(body).__name__}). "
        "Fix: either (a) pass ext=\"pkl\" / ext=\"json\" to dw_api_fetch() "
        "so the cache uses a non-tabular serialisation, or (b) reshape "
        "the response upstream of dw_api_fetch."
    )


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
    url = (
        "https://sdmx.data.unicef.org/ws/public/sdmxapi/rest/codelist/"
        f"{agency}/{codelist}/{version}"
        "?format=sdmx-json&detail=full&references=none"
    )
    resp = _http_call("get", url, timeout=60)
    try:
        body = resp.json()
        codes = body["data"]["codelists"][0]["codes"]
    except (ValueError, KeyError, IndexError) as exc:
        raise RuntimeError(
            f"[cso_toolkit.dw_api/_fetch_sdmx_codelist] Unexpected response "
            f"shape (agency={agency!r}, codelist={codelist!r}, "
            f"version={version!r}).\n"
            f"  Underlying error: {type(exc).__name__}: {exc}\n"
            f"  First 300 chars of body: {(resp.text or '')[:300]!r}\n"
            "  Fix: verify agency / codelist / version spelling against "
            "https://sdmx.data.unicef.org/ — a 200 OK with no codelists "
            "usually means the codelist doesn't exist at that version."
        ) from exc

    def _desc(c: dict) -> Optional[str]:
        d = c.get("description")
        if d is None:
            return None
        if isinstance(d, dict):
            return d.get("en")
        if isinstance(d, str):
            return d
        return None

    try:
        return pd.DataFrame({
            "code": [c["id"] for c in codes],
            "name": [c["names"]["en"] for c in codes],
            "description": [_desc(c) for c in codes],
        })
    except KeyError as exc:
        raise RuntimeError(
            "[cso_toolkit.dw_api/_fetch_sdmx_codelist] Code entry missing "
            f"required field: {exc}\n"
            "  Fix: this is an upstream-shape issue; the SDMX response no "
            "longer carries `id` / `names.en` on every code. File a bug "
            "and consider widening the fetcher."
        ) from exc


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
    if not series_codes:
        raise ValueError(
            "[cso_toolkit.dw_api/_fetch_unsd_sdg] `series_codes` is empty.\n"
            "  Fix: pass at least one SDG series code, e.g. "
            "series_codes=[\"SL_DOM_TSPD\"]."
        )
    body = "&".join(f"seriesCodes={s}" for s in series_codes)
    resp = _http_call(
        "post", endpoint,
        data=body,
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/octet-stream",
        },
        timeout=300,
    )
    try:
        return pd.read_csv(io.StringIO(resp.text))
    except pd.errors.ParserError as exc:
        raise RuntimeError(
            "[cso_toolkit.dw_api/_fetch_unsd_sdg] UNSD SDG API returned "
            "a body that pandas could not parse as CSV.\n"
            f"  Underlying error: {exc}\n"
            f"  First 300 chars: {(resp.text or '')[:300]!r}\n"
            "  Fix: verify the series codes — bad codes sometimes yield "
            "an HTML error page instead of CSV."
        ) from exc


def _fetch_github_raw(owner_repo: str, ref: str = "main",
                      path: Optional[str] = None, **_: Any) -> Any:
    """Pinned-commit ``raw.githubusercontent.com`` fetcher."""
    if path is None:
        raise ValueError(
            "[cso_toolkit.dw_api/_fetch_github_raw] `path` is required.\n"
            "  Fix: pass path=\"AU.csv\" (or similar) — the file path "
            "within the repo at the pinned ref."
        )
    url = f"https://raw.githubusercontent.com/{owner_repo}/{ref}/{path}"
    resp = _http_call("get", url, timeout=60)
    ext = Path(path).suffix.lower().lstrip(".")
    try:
        if ext == "csv":
            import io as _io
            return pd.read_csv(_io.StringIO(resp.text))
        if ext == "tsv":
            import io as _io
            return pd.read_csv(_io.StringIO(resp.text), sep="\t")
        if ext == "json":
            return resp.json()
        return resp.text.splitlines()
    except (pd.errors.ParserError, ValueError) as exc:
        raise RuntimeError(
            "[cso_toolkit.dw_api/_fetch_github_raw] Could not parse the "
            f"response from {url} as {ext or 'text'}.\n"
            f"  Underlying error: {type(exc).__name__}: {exc}\n"
            "  Fix: verify owner_repo / ref / path; a 404 sometimes "
            "returns an HTML error page instead of a clean body."
        ) from exc


def _fetch_http(url: str, headers: Optional[Mapping[str, str]] = None,
                **_: Any) -> str:
    """Generic HTTP GET returning text."""
    resp = _http_call("get", url, headers=dict(headers or {}), timeout=120)
    return resp.text


def _fetch_json_get(url: str, **_: Any) -> Any:
    """Generic JSON GET → parsed object."""
    resp = _http_call("get", url, timeout=120)
    try:
        return resp.json()
    except ValueError as exc:
        raise RuntimeError(
            f"[cso_toolkit.dw_api/_fetch_json_get] Body at {url} is not "
            "valid JSON.\n"
            f"  Underlying error: {exc}\n"
            f"  First 300 chars: {(resp.text or '')[:300]!r}\n"
            "  Fix: verify the URL and content-type; some endpoints "
            "redirect to HTML when bad parameters are sent."
        ) from exc


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
