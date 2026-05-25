# r/R/ — R helpers

Vendored, not installed. Python siblings of every helper below live at
[`python/src/`](../../python/src/) — same behaviour contract, same path
routing, same provenance sidecars; pick the language that fits the
sector pipeline you are vendoring into.

**Core helpers (shipped in v0.1.0-rc1):**

- [`dw_io.R`](dw_io.R) — uniform read / write / compare / merge / isid helpers.
  Auto-dispatch by extension. Writes `.provenance.json` sidecars.
- [`dw_api.R`](dw_api.R) — cached API fetcher with reviewer-mode no-API
  enforcement.
- [`cso_toolkit_sync.R`](cso_toolkit_sync.R) — version-drift detection +
  pull / diff against the upstream tag pinned in your consumer's
  `.toolkit_manifest.yml`.

**Aggregation + scaffolding helpers (added post-v0.1.0-rc1):**

- [`aggregate_data.R`](aggregate_data.R) — original `aggregate_data()`
  (mean / weighted_mean, optional global aggregate, population + country
  coverage). Kept for back-compat.
- [`aggregate_data_v2.R`](aggregate_data_v2.R) — `aggregate_data_v2()` with
  `weighted_mean`, `mean`, `sum`, `proportion`; coverage threshold;
  metadata columns. Also ships `generate_agg_footnote()` and
  `apply_time_window()`, plus a back-compat wrapper that delegates the v1
  signature to v2.
- [`generate_markdown_report.R`](generate_markdown_report.R) — turn a CSV (or
  a folder of CSVs) into a Markdown descriptive-statistics report with
  variable details and optional country / year / indicator summaries.
- [`create_sector_script.R`](create_sector_script.R) —
  `create_sector_script(sector_name, sector_code, base_dir = ".", ...)`
  scaffolds a `<base_dir>/<code>/00_run_<code>.R` template with profile
  verification, logging, runtime tracking, and try-catch. Ships a
  DW-Production convenience wrapper `create_dw_sector_script()`.
- [`profile_helpers.R`](profile_helpers.R) —
  `create_profile(repo_name, ...)` scaffolds a `profile_<repo>.R` template
  with the standard CSO building blocks (cross-platform user identification,
  YAML config load, optional producer / reviewer `dw_mode` block, optional
  Z: drive advisory, packages block, profile sentinel).
  `review_profile(path, ...)` audits an existing profile for the same
  blocks and reports `pass` / `warn` / `fail` per check.
- [`test_scripts.R`](test_scripts.R) — `test_scripts(path, ...)` recursively
  scans a directory of `.R` scripts and flags any direct call to a raw
  file-IO or external-API command that `dw_io.R` / `dw_api.R` is meant to
  wrap (e.g. `read_csv`, `saveRDS`, `httr::GET`, `rsdmx::readSDMX`,
  `wbstats::wb_data`). Per-line escape hatch via `# cso-allow: <rule-id>`;
  CI mode via `error_on_violation = TRUE`.

## How a consumer vendors these

In the consumer repo's `00_functions/`:

```r
source(file.path(rootFolder, "00_functions", "dw_io.R"))
source(file.path(rootFolder, "00_functions", "dw_api.R"))
source(file.path(rootFolder, "00_functions", "cso_toolkit_sync.R"))
```

The consumer pins a version in `00_functions/.toolkit_manifest.yml`:

```yaml
source: "unicef-drp/cso-toolkit"
pulled_version: "v0.2.0"
pulled_date: "2026-05-25"
```

`cso_toolkit_check()` reads the manifest, asks the GitHub API for the latest
tag, and warns if the consumer is behind. See
[`templates/.toolkit_manifest.yml`](../../templates/.toolkit_manifest.yml)
for the full schema (fields, optional helpers, `local_edits` opt-out).
