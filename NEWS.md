# NEWS — cso-toolkit

## Unreleased

**R helpers (documentation):**

- Roxygen pass across `dw_io.R`, `dw_api.R`, `cso_toolkit_sync.R`,
  `generate_markdown_report.R`, and `aggregate_data.R`. Every exported
  function now has `@param` / `@return` / `@export`; every internal
  helper carries `@keywords internal` + `@noRd`. The package now ships
  a generated `NAMESPACE` exporting 26 functions and a `man/` directory
  with one `.Rd` per export. No behaviour change.
- `r/DESCRIPTION` — version bumped to `0.2.1.9000` (dev) ahead of the
  next release.

**Sync / vendoring infrastructure:**

- `templates/.toolkit_manifest.yml` — header expanded with a field-by-field
  reference; `pulled_version` bumped to `v0.2.0`; sample `vendored:` list
  now mentions the seven optional helpers as commented-out entries so
  consumers can opt in without re-deriving the file list.
- `r/tests/manual/check_consumer_side.R` — manual smoke test that
  simulates a consumer repo, drops a manifest into it, sources the
  vendored helpers, and calls `cso_toolkit_check()` end-to-end against
  the live GitHub API. Use as a release-eve verification.

**R helpers (additions):**
- `aggregate_data.R` — original `aggregate_data()` (mean / weighted_mean,
  optional global aggregate, population + country coverage). Lifted from
  `DW-Production/00_functions/`. Kept for back-compat.
- `aggregate_data_v2.R` — `aggregate_data_v2()` with `weighted_mean`, `mean`,
  `sum`, `proportion`; coverage threshold; metadata columns. Ships
  `generate_agg_footnote()`, `apply_time_window()`, and a v1-compatible
  wrapper that delegates the v1 signature to v2.
- `generate_markdown_report.R` — `generate_markdown_report()` +
  `process_all_csv_files()`. Descriptive-stats Markdown reports from CSV
  files; handles missing country / year / indicator columns gracefully.
- `create_sector_script.R` — `create_sector_script(sector_name, sector_code,
  base_dir = ".", ...)` scaffolds a `<base_dir>/<code>/00_run_<code>.R`
  template with profile verification, logging, runtime tracking, and
  try-catch. **Generalized over the DW-Production original**: `base_dir`,
  `profile_name`, `profile_file`, `input_subpath`, `output_subpath` are
  parameters. DW-Production consumers get the original behaviour via the
  convenience wrapper `create_dw_sector_script()`.
- `profile_helpers.R` — `create_profile(repo_name, ...)` scaffolds a
  `profile_<repo>.R` template with the standard CSO building blocks
  (cross-platform user identification, YAML config load, optional
  producer / reviewer `dw_mode` block, optional Z: drive advisory,
  packages block, profile sentinel). `review_profile(path, ...)` audits an
  existing profile for the same blocks and reports `pass` / `warn` /
  `fail` per check.
- `test_scripts.R` — `test_scripts(path, ...)` recursively scans a
  directory of `.R` scripts and flags any direct call to a raw file-IO or
  external-API command that `dw_io.R` / `dw_api.R` is meant to wrap.
  Built-in rule registry covers `read_csv` / `write_csv`, `fread` /
  `fwrite`, `saveRDS` / `readRDS`, `save` / `load`, `read_dta` /
  `write_dta`, `read_xlsx` / `write_xlsx`, `read_parquet` /
  `write_parquet`, `read_json` / `write_json`, `read_yaml` / `write_yaml`
  (IO family), plus `httr::GET/POST`, `fromJSON(url)`, `readSDMX`,
  `wbstats::wb_data`, `get_ilostat`, and `download.file` (API family).
  Per-line escape hatch via `# cso-allow: <rule-id>` trailing comment;
  CI mode via `error_on_violation = TRUE`.

**Documentation (additions / changes):**
- README — rebranded as the **UNICEF Chief Statistician Office (CSO)
  toolkit** and added an **Objective and motivation** section spelling out
  that the repo exists to facilitate the reproducibility and scalability
  of analytics developed by the UNICEF Data and Analytics Section in the
  Office of the Executive Director (OSE). Citation block updated to match.

**Docs (additions):**
- `docs/dw_io_reference.md` — per-function reference for `dw_io.R` lifted
  out of the DW-Production `00_functions/README.md`.
- `docs/dw_api_reference.md` — per-function reference for `dw_api.R` (same
  lift; behaviour matrix, supported APIs, worked SDMX example, sector
  migration checklist).

## v0.1.0-rc1 (2026-05-24)

First release candidate. Extracted from `unicef-drp/DW-Production` PR #89.

**R helpers (feature-complete):**
- `dw_io.R` — `dw_save`, `dw_use`, `dw_compare`, `dw_merge`, `dw_isid`,
  `dw_verify_z`, `dw_resolve_path`, `dw_is_canonical`. Auto-dispatch by
  extension. `.provenance.json` sidecars with sha256.
- `dw_api.R` — `dw_api_fetch`, `dw_api_cached`, `dw_api_inventory`. Supports
  `uis`, `sdmx`, `sdmx_codelist`, `wb`, `wb_indicators`, `ilo`, `unsd_sdg`,
  `github_raw`, `http`, `json_get`. Per-api default extension picker.
  Reviewer-mode hard-stop via `dw_require_no_api()`.
- `cso_toolkit_sync.R` — `cso_toolkit_check`, `cso_toolkit_diff`,
  `cso_toolkit_pull`. Gracefully no-ops when upstream is unreachable.

**Stata helpers (scaffolded, empty):**
- `stata/src/` placeholder. Ships in v0.2.

**Python helpers (scaffolded, empty):**
- `python/src/` placeholder. Ships in v0.2.

**Docs:**
- `docs/roles_and_workflow.md` — PRODUCER / REVIEWER / INGESTOR three-role
  model; folder layout; per-role workflow; forbidden boundaries.
- `docs/toolkit_strategy.md` — vendoring rationale; version-drift workflow;
  three-phase rollout.
- `docs/mode_contract_integration.md` — how to wire `dw_mode` into a sector
  profile (new in this repo).

**Templates:**
- `templates/dbm_submission_template.md` — eight-section pre-deposit checklist
  with the 2026-05-24 ed pilot as a worked example.

**Known limitations:**
- Stata / Python implementations not yet shipped.
- HIV and WASH sectors in DW-Production still write Stata `save` commands to
  canonical paths; mode-routing in Stata depends on v0.2.
- `cso_toolkit_pull()` does not yet patch sector-specific overrides; a vendor
  with local edits will see them reverted.
