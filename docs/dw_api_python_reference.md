# `dw_api.py` reference

Python port of `r/R/dw_api.R`.  Companion to
[`dw_io_python_reference.md`](dw_io_python_reference.md).

See also: [`dw_api_reference.md`](dw_api_reference.md) for the R
counterpart.

## Behaviour matrix

| Function           | Producer + cache hit | Producer + cache miss | Reviewer + cache hit | Reviewer + cache miss |
| ------------------ | -------------------- | --------------------- | -------------------- | --------------------- |
| `dw_api_fetch`     | Read cache           | Live fetch → write    | Read cache           | `PermissionError`     |
| `dw_api_cached`    | Read cache           | `FileNotFoundError`   | Read cache           | `FileNotFoundError`   |
| `dw_api_inventory` | List caches          | List caches           | List caches          | List caches           |

`refresh=True` on `dw_api_fetch` forces a live fetch even when a cache
exists (producer only).

## Supported APIs

| `api=` value         | Helper                       | Lazy-imported package | Default `ext` |
| -------------------- | ---------------------------- | --------------------- | ------------- |
| `"uis"`              | UNESCO UIS REST              | `requests`            | `csv`         |
| `"sdmx"`             | Generic SDMX                 | `sdmx1`               | `csv`         |
| `"sdmx_codelist"`    | UNICEF SDMX codelist         | `requests`            | `csv`         |
| `"wb"`               | World Bank WDI               | `wbgapi`              | `csv`         |
| `"wb_indicators"`    | World Bank indicator catalogue | `wbgapi`            | `pkl`         |
| `"ilo"`              | ILO SDMX                     | `sdmx1`               | `csv`         |
| `"unsd_sdg"`         | UNSD SDG API                 | `requests`            | `csv`         |
| `"github_raw"`       | Pinned-commit raw.githubusercontent.com | `requests` | `csv` (by ext) |
| `"http"`             | Generic HTTP GET → text      | `requests`            | `csv`         |
| `"json_get"`         | Generic JSON GET → parsed    | `requests`            | `pkl`         |

`refresh=False` (default) checks the sandbox path first, then the
canonical path as a read fallback.

## Cache layout

```text
<teamsRawData>/_apis/<api>/<cache_key>.<ext>
<teamsRawData>/_apis/<api>/<cache_key>.<ext>.provenance.json
```

The sidecar records what the cache contains and how it was obtained:

```json
{
  "path": ".../sdmx_codelist_UNICEF_CL_RESIDENCE_1_0.csv",
  "format": "csv",
  "written_at": "2026-05-25T14:23:11+0000",
  "user": "jpazvd",
  "dw_mode": "producer",
  "sha256": "...",
  "schema": {"rows": 4, "cols": 3, "columns": ["code", "name", "description"]},
  "metadata": {
    "api": "sdmx_codelist",
    "cache_key": "sdmx_codelist_UNICEF_CL_RESIDENCE_1_0",
    "fetched_at": "2026-05-25T14:23:11+0000",
    "elapsed_secs": 0.412,
    "refresh_flag": false,
    "fetch_args": {"agency": "UNICEF", "codelist": "CL_RESIDENCE", "version": "1.0"}
  }
}
```

## Reviewer-mode lockout

When `_state.dw_apis_allowed` is `False` and the cache is missing,
`dw_api_fetch` raises `PermissionError`:

```text
[cso_toolkit.dw_api] Reviewer mode forbids live API calls.
  Call:   dw_api_fetch('sdmx_codelist', cache_key='sdmx_codelist_UNICEF_CL_RESIDENCE_1_0')
  Reason: cache missing at /data/raw-canonical/_apis/sdmx_codelist/sdmx_codelist_UNICEF_CL_RESIDENCE_1_0.csv
  Fix:
    1. The expected workflow is that a Database Manager has already populated
       the cache under teamsRawDataCanonical/_apis/. Verify the cache file exists.
    2. If you ARE the producer, switch modes:
       from cso_toolkit import _state
       _state.configure(dw_mode="producer", dw_apis_allowed=True)
```

## HTTP error envelope

All fetchers route through `_http_call`, which translates
`requests.RequestException` subclasses into the same three-part
envelope (Timeout / Connection / HTTPError → wrapped with URL, status,
body snippet, and a fix hint).

## Worked example: UNICEF SDMX codelist

```python
from cso_toolkit import _state, dw_api_fetch

_state.configure(
    teamsRawData="/data/raw",
    teamsRawDataCanonical="/data/raw-canonical",
    dw_apis_allowed=True,
)

codebook = dw_api_fetch(
    api="sdmx_codelist",
    agency="UNICEF",
    codelist="CL_RESIDENCE",
    version="1.0",
    cache_key="sdmx_codelist_UNICEF_CL_RESIDENCE_1_0",
)
# codebook.columns == ["code", "name", "description"]
```

## Inventory + refresh

```python
from cso_toolkit import dw_api_inventory, dw_api_fetch

# What's cached?
inv = dw_api_inventory()
# DataFrame: api / cache_key / ext / size_bytes / mtime / fetched_at

# Refresh one cache (producer only)
new = dw_api_fetch(
    api="wb",
    indicator=["SE.LPV.PRIM"],
    start_date=2000,
    end_date=2025,
    cache_key="wb_learning_poverty_primary",
    refresh=True,
)
```

## Sector migration checklist

When porting a sector script away from raw API calls:

1. Replace every `requests.get(...)`, `httpx.get(...)`,
   `sdmx.Client(...)`, `wbgapi.data.fetch(...)`, etc. with
   `dw_api_fetch(api=..., cache_key=..., ...)`.
2. Pick a stable, snake_case `cache_key` — it becomes the cache
   filename, so prefer human-readable names like
   `wb_learning_poverty_primary` over hashes.
3. Stamp every load-bearing fetch with `metadata=`:
   `{"reason": "...", "ticket": "JIRA-123", "vintage": "2026-05"}`.
4. Run `cso_toolkit.test_scripts(<sector_folder>, error_on_violation=True)`
   to confirm no raw network calls remain.
