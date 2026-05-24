# NEWS — cso-toolkit

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
