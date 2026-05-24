# cso-toolkit

Shared helpers, templates, and operating-model documentation for UNICEF Data &
Analytics Database Managers (DBMs), reviewers, and ingestors working with the
DW-Production indicator data warehouse.

**Status.** Pre-release. First tag is `v0.1.0-rc1`. Public so reviewers and
external collaborators can read and cite the contract; production adoption is
via **vendoring** (see [Vendoring](#vendoring)), not `source()` over the network.

---

## What's in the box

| Path | Purpose |
|---|---|
| [`r/R/dw_io.R`](r/R/dw_io.R) | Uniform IO helpers: `dw_save`, `dw_use`, `dw_compare`, `dw_merge`, `dw_isid`, `dw_verify_z`. Auto-dispatches by extension (CSV/TSV/XLSX/RDS/RData/DTA/Parquet/JSON/YAML). Writes a `.provenance.json` sidecar with `sha256`, schema, user, timestamp, metadata. |
| [`r/R/dw_api.R`](r/R/dw_api.R) | Cached API fetcher: `dw_api_fetch(api, cache_key, ...)`. Supports `uis`, `sdmx`, `sdmx_codelist`, `wb`, `wb_indicators`, `ilo`, `unsd_sdg`, `github_raw`, `http`, `json_get`. Cache lives in `<rawdata>/_apis/<api>/<cache_key>.<ext>`. Enforces the **reviewer mode no-API** contract. |
| [`r/R/cso_toolkit_sync.R`](r/R/cso_toolkit_sync.R) | `cso_toolkit_check()` / `cso_toolkit_diff()` / `cso_toolkit_pull()` — version-drift detection and update workflow for vendored consumers. |
| [`stata/src/`](stata/src/) | Stata mirrors (placeholder for v0.1; Stata-side helpers ship in v0.2). |
| [`python/src/`](python/src/) | Python mirrors (placeholder for v0.1; Python-side helpers ship in v0.2). |
| [`docs/roles_and_workflow.md`](docs/roles_and_workflow.md) | Canonical PRODUCER / REVIEWER / INGESTOR role definitions + folder layout + per-role workflow + forbidden boundaries. |
| [`docs/toolkit_strategy.md`](docs/toolkit_strategy.md) | Why this repo exists, the vendoring model, the version-drift detection workflow, the three-phase rollout. |
| [`docs/mode_contract_integration.md`](docs/mode_contract_integration.md) | How to wire `dw_mode` (producer/reviewer) into a sector profile. |
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
- `v0.1.0-rc1` — first tagged release candidate (this tag). R helpers feature-
  complete; Stata / Python directories scaffolded but empty.
- `v1.0.0` — committed API; will be cut after the ed sector pilot lands and a
  second sector vendors the helpers without modification.

See [NEWS.md](NEWS.md) for per-release notes.

---

## License

CC BY 4.0 (docs) + MIT (code). See [LICENSE](LICENSE).

---

## How to cite

> UNICEF Data & Analytics, *cso-toolkit: Shared helpers and operating model for
> child-indicator data warehousing*, v0.1.0-rc1 (2026), https://github.com/unicef-drp/cso-toolkit
