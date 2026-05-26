# python/src/ — Python helpers

Python port of the R helpers in [`r/R/`](../../r/R/).  Same behaviour
contract; mode-aware path routing, cached external-API access,
provenance sidecars, and version-drift detection.

## Layout

Vendored, not pip-installed (mirrors the R "copy into `00_functions/`"
pattern).  Drop the entire `python/src/` directory into your consumer
repo as `00_functions/cso_toolkit/`, then:

```python
import sys
sys.path.insert(0, "00_functions")           # makes `cso_toolkit` importable
from cso_toolkit import dw_save, dw_use      # core IO
from cso_toolkit import dw_api_fetch         # cached external API
from cso_toolkit import _state as cso_state
```

Configure session state once at profile load:

```python
cso_state.configure(
    teamsWrkData="/path/to/wrk",
    teamsRawData="/path/to/raw",
    teamsWrkDataCanonical="/path/to/wrk-canonical",
    teamsRawDataCanonical="/path/to/raw-canonical",
    teamsFolderCanonical="/path/to/teams-canonical",
    dw_mode="reviewer",                       # or "producer"
    dw_apis_allowed=False,                    # True in producer
)
```

## Modules

| Module                          | Public entry points |
| ------------------------------- | ------------------- |
| `dw_io.py`                      | `dw_save`, `dw_use`, `dw_compare`, `dw_merge`, `dw_isid`, `dw_verify_z`, `dw_resolve_path`, `dw_is_canonical` |
| `dw_api.py`                     | `dw_api_fetch`, `dw_api_cached`, `dw_api_inventory` |
| `cso_toolkit_sync.py`           | `cso_toolkit_check`, `cso_toolkit_diff`, `cso_toolkit_pull` |
| `aggregate_data.py`             | `aggregate_data`, `aggregate_data_v2`, `generate_agg_footnote`, `apply_time_window` |
| `dw_nestweight.py`              | `dw_nestweight` |
| `generate_markdown_report.py`   | `generate_markdown_report`, `process_all_csv_files` |
| `create_sector_script.py`       | `create_sector_script`, `create_dw_sector_script` |
| `profile_helpers.py`            | `create_profile`, `review_profile` |
| `test_scripts.py`               | `test_scripts` (audits Python scripts for raw IO / HTTP calls) |
| `_state.py`                     | `configure`, `_get` (session-level state) |

## Behaviour parity with the R helpers

Each `.py` module mirrors its `.R` counterpart in:

- **Path resolution** — same `kind = "wrk" | "raw" | "meta"` matrix,
  same `name` / `sector` / `vintage` keyword arguments.
- **Mode contract** — `dw_save` raises `PermissionError` (Python analogue
  of R's `stop()`) when a reviewer-mode write would land under canonical
  without `allow_canonical_write=True`.
- **Z: drive mirror** — automatic carbon-copy on canonical writes;
  non-blocking size-check on canonical reads.
- **Provenance sidecar** — same JSON schema (`path`, `format`,
  `written_at`, `user`, `dw_mode`, `vintage`, `sha256`, `isid`,
  `schema`, optional `metadata`).
- **Auto-dispatch on extension** — `.csv` / `.tsv` / `.txt` / `.xlsx` /
  `.parquet` / `.dta` / `.json` / `.yaml`, plus the Python additions
  `.pkl` / `.pickle` (Python analogue of R's `.rds`).

## Dependency matrix

Core (always required):

```text
pandas>=2.0
numpy>=1.24
```

Format-specific (lazy-imported; only loaded when you call the
corresponding writer / reader):

| Format       | Package        |
| ------------ | -------------- |
| `.xlsx`      | `openpyxl`     |
| `.parquet`   | `pyarrow`      |
| `.yaml`      | `PyYAML`       |

API-specific (lazy-imported by `dw_api_fetch`):

| `api=` value         | Package         |
| -------------------- | --------------- |
| `"uis"` / `"http"` / `"json_get"` / `"sdmx_codelist"` / `"unsd_sdg"` / `"github_raw"` | `requests` |
| `"sdmx"` / `"ilo"`   | `sdmx1` (provides the `sdmx` import name) |
| `"wb"` / `"wb_indicators"` | `wbgapi`  |

## See also

- [Top-level README](../../README.md) — toolkit overview + architecture
  diagram.
- [`python/README.md`](../README.md) — Python package overview (install,
  layout, quick start, testing).
- [NEWS.md / Changelog](../../NEWS.md) — per-release notes.
- Sibling implementations: [`r/R/README.md`](../../r/R/README.md)
  · [`stata/src/README.md`](../../stata/src/README.md).
