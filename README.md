# cso-toolkit — UNICEF Chief Statistician Office toolkit

Shared helpers, templates, and operating-model documentation for the **UNICEF
Chief Statistician Office (CSO)** — used by Database Managers (DBMs),
reviewers, and ingestors working with the DW-Production indicator data
warehouse and adjacent CSO-led pipelines.

## Objective and motivation

`cso-toolkit` exists to **facilitate the reproducibility and scalability of
analytics developed by the UNICEF Data and Analytics Section in the Office of
the Executive Director (OSE)**.

Concretely it does three things:

1. **Encodes a single IO + API contract.** One way to read, write, compare,
   and merge data; one way to hit external APIs (UIS, SDMX, World Bank, ILO,
   UNSD-SDG, GitHub-raw). Every call routes through wrappers that enforce
   provenance sidecars, uniqueness checks, and the producer / reviewer mode
   contract — so any analytics product can be rerun by someone other than
   its original author and yield the same numbers.
2. **Separates producer and reviewer mode at the session level.** The
   Database Manager (producer) pulls live APIs and deposits canonical
   artefacts; the reviewer reruns from those frozen artefacts and is
   physically prevented from touching the network. The contract is enforced
   by the toolkit at every wrapped call site, not by convention.
3. **Scales across sectors and projects.** The same helpers, the same
   templates, and the same audit functions are vendored into every sector
   codebase under the CSO, which means new sectors and new projects inherit
   the reproducibility floor for free instead of re-inventing it.

**Status.** Pre-release. Current tag is `v0.2.0` (R + Stata helpers
feature-complete, Python port shipping in `v0.3.0`). Public so reviewers
and external collaborators can read and cite the contract; production
adoption is via **vendoring** (see [Vendoring](#vendoring)), not
`source()` over the network.

---

## What's in the box

| Path | Purpose |
|---|---|
| [`r/R/dw_io.R`](r/R/dw_io.R) | Uniform IO helpers: `dw_save`, `dw_use`, `dw_compare`, `dw_merge`, `dw_isid`, `dw_verify_z`. Auto-dispatches by extension (CSV/TSV/XLSX/RDS/RData/DTA/Parquet/JSON/YAML). Writes a `.provenance.json` sidecar with `sha256`, schema, user, timestamp, metadata. Per-function reference: [`docs/dw_io_reference.md`](docs/dw_io_reference.md). |
| [`r/R/dw_api.R`](r/R/dw_api.R) | Cached API fetcher: `dw_api_fetch(api, cache_key, ...)`. Supports `uis`, `sdmx`, `sdmx_codelist`, `wb`, `wb_indicators`, `ilo`, `unsd_sdg`, `github_raw`, `http`, `json_get`. Cache lives in `<rawdata>/_apis/<api>/<cache_key>.<ext>`. Enforces the **reviewer mode no-API** contract. Per-function reference: [`docs/dw_api_reference.md`](docs/dw_api_reference.md). |
| [`r/R/cso_toolkit_sync.R`](r/R/cso_toolkit_sync.R) | `cso_toolkit_check()` / `cso_toolkit_diff()` / `cso_toolkit_pull()` — version-drift detection and update workflow for vendored consumers. |
| [`r/R/aggregate_data.R`](r/R/aggregate_data.R) | Original `aggregate_data()`: mean / weighted_mean, optional global aggregate, population + country coverage. Kept for back-compat. |
| [`r/R/aggregate_data_v2.R`](r/R/aggregate_data_v2.R) | `aggregate_data_v2()` with `weighted_mean`, `mean`, `sum`, `proportion`; coverage threshold; metadata columns. Ships `generate_agg_footnote()`, `apply_time_window()`, and a v1-compatible wrapper. |
| [`r/R/generate_markdown_report.R`](r/R/generate_markdown_report.R) | `generate_markdown_report()` + `process_all_csv_files()` — descriptive-stats Markdown reports from CSV files. |
| [`r/R/create_sector_script.R`](r/R/create_sector_script.R) | `create_sector_script(sector_name, sector_code, base_dir = ".", ...)` — scaffold a sector run-script template (profile check, logging, try-catch). DW-Production convenience wrapper: `create_dw_sector_script()`. |
| [`r/R/profile_helpers.R`](r/R/profile_helpers.R) | `create_profile(repo_name, ...)` — scaffold a `profile_<repo>.R` with the standard CSO building blocks (user identification, YAML config, optional `dw_mode`, packages, profile sentinel). `review_profile(path, ...)` — audit an existing profile for the blocks the toolkit's contract relies on. |
| [`r/R/test_scripts.R`](r/R/test_scripts.R) | `test_scripts(path, ...)` — recursively scan `.R` scripts and flag any direct calls to file-IO or external-API commands wrapped by `dw_io.R` / `dw_api.R` (e.g. `read_csv`, `httr::GET`, `rsdmx::readSDMX`). Per-line escape hatch via `# cso-allow: <rule-id>`; CI mode via `error_on_violation = TRUE`. |
| [`r/R/dw_nestweight.R`](r/R/dw_nestweight.R) | `dw_nestweight(data, value, by, weight, ...)` — redistributes survey weights from missing nested observations so per-stratum totals are preserved. R port of `edukit_nestweight` (Diana Goldemberg). |
| [`stata/src/dw_save.ado`](stata/src/dw_save.ado) | Stata sibling of R `dw_save()`. `isid` + `compress` + `save` + sibling `.provenance.json` sidecar matching the R-side shape. Honours producer / reviewer mode via `$dw_mode`; canonical writes blocked in reviewer mode unless `allow_canonical_write` is passed. Content hash via Stata-native `datasignature`. Lineage: `edukit_save` / `savemetadata` (Diana Goldemberg). |
| [`stata/src/dw_compare.ado`](stata/src/dw_compare.ado) | Stata sibling of R `dw_compare()`. Merges two `.dta` files on `idvars` and classifies each value column as identical / numerically-equivalent (within `tol()`) / different; optional Markdown report. Lineage: `comparefiles` / `edukit_comparefiles` (Kristoffer Bjärkefur). |
| [`stata/src/dw_mkdir.ado`](stata/src/dw_mkdir.ado) | Recursive `mkdir` for Stata (the built-in is non-recursive). Idempotent. Lineage: `rmkdir` / `edukit_rmkdir` (Kristoffer Bjärkefur). |
| [`stata/src/`](stata/src/) | See [`stata/src/README.md`](stata/src/README.md) for the full Stata-side helper docs (lineage table, install via adopath, mode-contract wiring, known limitations). |
| [`python/src/`](python/src/) | Python siblings of every R helper above. `dw_save`, `dw_use`, `dw_api_fetch`, `aggregate_data_v2`, `dw_nestweight`, `create_sector_script`, `create_profile`, `review_profile`, `test_scripts`, and the rest — same behaviour contract, same mode-aware path routing, same provenance sidecars, same Z: drive mirror. Imports via `from cso_toolkit import dw_save, dw_use, ...`. Per-function reference: [`docs/dw_io_python_reference.md`](docs/dw_io_python_reference.md) and [`docs/dw_api_python_reference.md`](docs/dw_api_python_reference.md). Vendoring layout in [`python/src/README.md`](python/src/README.md). |
| [`python/pyproject.toml`](python/pyproject.toml) | Optional `pip install -e python/` for local development. Vendoring (copy into `00_functions/`) is still the production model. |
| [`docs/dw_io_python_reference.md`](docs/dw_io_python_reference.md) | Per-function reference for the Python `dw_io.py` (parity matrix with R, extension dispatch, mode contract, error envelope, migration checklist). |
| [`docs/dw_api_python_reference.md`](docs/dw_api_python_reference.md) | Per-function reference for the Python `dw_api.py` (behaviour matrix, supported APIs, cache layout, reviewer-mode lockout, worked example). |
| [`docs/roles_and_workflow.md`](docs/roles_and_workflow.md) | Canonical PRODUCER / REVIEWER / INGESTOR role definitions + folder layout + per-role workflow + forbidden boundaries. |
| [`docs/toolkit_strategy.md`](docs/toolkit_strategy.md) | Why this repo exists, the vendoring model, the version-drift detection workflow, the three-phase rollout. |
| [`docs/mode_contract_integration.md`](docs/mode_contract_integration.md) | How to wire `dw_mode` (producer/reviewer) into a sector profile. |
| [`docs/dw_io_reference.md`](docs/dw_io_reference.md) | Per-function reference for `dw_io.R` (call styles, isid contract, mode contract, Z: mirror, provenance sidecar). |
| [`docs/dw_api_reference.md`](docs/dw_api_reference.md) | Per-function reference for `dw_api.R` (behaviour matrix, supported APIs, worked example, migration checklist). |
| [`templates/dbm_submission_template.md`](templates/dbm_submission_template.md) | Eight-section pre-deposit checklist that DBMs complete before a deposit goes canonical. |

---

## Three roles, one contract

| Role | What they do | Where they write |
|---|---|---|
| **PRODUCER** (DBM) | Runs the sector pipeline, pulls upstream APIs, deposits final `dw_<sector>.<ext>` into the warehouse, writes a submission template. | The canonical deposit (`060.DW-MASTER`). |
| **REVIEWER** | Re-runs the sector pipeline from pre-deposited inputs, compares against the canonical deposit, files issues. **Must never call external APIs.** | A sandbox (`sandboxRoot`). Never touches canonical. |
| **INGESTOR** | Pulls signed-off deposits into `data.unicef.org`, SDMX, and downstream products. | Internal infrastructure outside this repo. |

The mode contract is enforced at `source("profile_DW-Production.R")` time and
again at every API call site via `dw_require_no_api()`. See
[`docs/mode_contract_integration.md`](docs/mode_contract_integration.md).

---

## Vendoring

Consumers (DW-Production sector codebases) **vendor** these helpers — they copy
files into their own `00_functions/` and pin a version. A `.toolkit_manifest.yml`
records the pinned version. `cso_toolkit_check()` warns when upstream has moved.

Why vendoring and not `source()` or `remotes::install_github()`:

- **Vintage permanence.** A 2026-05 release re-run must use the helper code as
  it stood in 2026-05. Network sourcing breaks that.
- **AppLocker reality.** UNICEF laptops block many script-installable paths;
  copy-into-`00_functions/` always works.
- **Offline reproducibility.** Reviewers on planes / customs / corporate
  networks need the helpers locally.

See [`docs/toolkit_strategy.md`](docs/toolkit_strategy.md) for the full
rationale and the upgrade flow.

---

## Versioning

Semantic versioning (MAJOR.MINOR.PATCH).

- `v0.x` — pre-release; API may still change.
- `v0.1.0-rc1` (2026-05-24) — first tagged release candidate. R helpers
  feature-complete; Stata / Python directories scaffolded but empty.
- `v0.2.0` (2026-05-24) — Stata helpers shipped (`dw_save.ado`,
  `dw_compare.ado`, `dw_mkdir.ado`); R `dw_nestweight.R` ported from
  EduAnalyticsToolkit; workflow diagrams added.
- `v0.3.0` (planned) — full Python port at [`python/src/`](python/src/)
  with parity to every R helper; Roxygen-complete R reference (26 Rd
  files + pkgdown site); graceful three-part error envelopes
  (`[cso_toolkit.<func>] WHAT / Why / Fix`) across R + Python; consumer-
  side smoke tests; secrets-redaction in `.provenance.json`.
- `v1.0.0` — committed API; will be cut after the ed sector pilot lands
  and a second sector vendors the helpers without modification.

See [NEWS.md](NEWS.md) for per-release notes.

---

## License

CC BY 4.0 (docs) + MIT (code). See [LICENSE](LICENSE).

---

## How to cite

> UNICEF Chief Statistician Office, *cso-toolkit: Shared helpers and operating
> model for child-indicator data warehousing*, v0.1.0-rc1 (2026),
> <https://github.com/unicef-drp/cso-toolkit>
