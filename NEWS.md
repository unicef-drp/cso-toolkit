# NEWS — cso-toolkit

## Unreleased

_Entries land here as PRs merge into `develop`.  When the next release
is cut, this header is renamed `## v0.4.0 (YYYY-MM-DD)` and a fresh
`## Unreleased` section is added back._

### Issue #15 — `dw_publish()` STUB (dry-run only)

Ships `r/R/dw_publish.R` as a deliberate STUB so DW-Production sector
scripts can wire the canonical call site today and have the live
branch light up automatically when v0.5.0 lands.

What's in:

- Public signature matching the final v0.5.0 contract:
  `dw_publish(path, indicator, vintage, sector, endpoint = "helix",
   dry_run = TRUE, ...)`.
- **Producer-only mode contract** -- reviewer-mode calls raise
  BEFORE any I/O via the same envelope shape as `dw_api_fetch()`.
- **Argument validation** -- empty / missing `path` / `indicator` /
  `vintage` / `sector` raises the envelope; `path` must exist on
  disk and not be a directory; `endpoint` must be `"helix"` (the
  only recognised value in v0.4.0).
- **`dry_run = TRUE` returns a validated payload** with `sha256`,
  `bytes`, `built_at`, `built_by`, and the toolkit-version stamp.
  Caller scripts can assert the payload shape today without ever
  hitting the network.

What's deliberately deferred:

- **Live submission (`dry_run = FALSE`) raises** with the
  envelope-shaped *"Live submission not yet implemented"* message
  and a pointer to GitHub issue #15.  Real Helix endpoint
  integration ships in **v0.5.0** once sector leads (@karavan88,
  @sbrar29, @laurenfrancis1202) finalise the submission contract.

Scope boundary -- folded into the helper's roxygen + docstring so
the long-running DW-Production confusion is finally resolved:

- `dw_save()` -- filesystem (Teams + Z: drive mirror).
- `dw_publish()` -- API (Helix submission).

Tested: 6 new asserts in
`r/tests/testthat/test-dw_publish.R` (cover the mode lockout,
argument validation, missing path, endpoint allowlist, dry-run
payload shape, and the v0.5.0-not-yet envelope).  Total R test
suite is now 235 / 0; `devtools::check()` remains 0 / 0 / 0.

### Issues #17 + #18 — `dw_pop()` and `dw_regions()` (R only)

Two convenience wrappers that almost every sector pipeline needs but
that v0.3.0 made users write themselves.  Both ship R-only in v0.4.0;
Python and Stata parity are tracked at the same GitHub issues for a
future minor.

- **`r/R/dw_pop.R`** -- `dw_pop()` wraps `dw_api_fetch(api = "wb")`
  for the World Bank total-population indicator (`SP.POP.TOTL`) and
  returns a tidy `(REF_AREA, TIME_PERIOD, OBS_VALUE)` tibble.  When
  `year` is `NULL` (default), only the latest available year per
  country is returned; pass a year (or vector of years) to subset.
  Optional `countries` filter, `refresh` to force a live fetch, and
  `cache_key` override.
- **`r/R/dw_regions.R`** -- `dw_regions()` fetches the UNICEF region
  taxonomy from `unicef-drp/Country-and-Region-Metadata`
  (default `UNICEF_REP_REG_GLOBAL.csv`) via
  `dw_api_fetch(api = "github_raw")`, joins the country -> region map
  into the caller's tibble, calls `aggregate_data_v2()` per region
  with the supplied `value` + `by` + `method`, and appends the
  regional rows to the original.  When `weight = "population"` (the
  default), denominators come from `dw_pop()` and are merged in on
  REF_AREA + TIME_PERIOD; otherwise the named column is used
  directly.

New pkgdown reference section: **Demographics**.  Both helpers are
registered with `@family demographics` and exported.

Tested: 11 new asserts for `dw_pop` + 19 for `dw_regions` (total R
suite now 191 / 0); `devtools::check()` stays at 0 / 0 / 0.

### Issue #5 — Stata helpers reaching mode-contract parity

Ships the three Stata helpers that completed the v0.4.0 producer /
reviewer contract on the Stata side, closing the gaps surfaced when
v0.3.0 landed Stata-as-a-supported-target with read + API parity still
deferred:

- **`stata/src/dw_use.ado`** + `.sthlp` — uniform Stata read wrapper
  with auto-dispatch on `.dta` / `.csv` / `.xlsx`. Implements the v0.4.0
  mode-branched resolver (producer = local-first, reviewer =
  network-first), parses sibling `.provenance.json` for the recorded
  `datasignature`, and runs a non-blocking Z: drive integrity check
  (size by default; `datasignature` deep check via
  `verify_z(sha256)`).
- **`stata/src/dw_require_no_api.ado`** + `.sthlp` — preflight gate
  that aborts (Stata error 459) when `$dw_mode == "reviewer"`. Mirrors
  the R `r/R/profile_helpers.R::dw_require_no_api` shape.
- **`stata/src/dw_load_config.ado`** + `.sthlp` — hand-rolled YAML
  reader for `~/.config/user_config.yml`. No external dependency
  (AppLocker-safe). Populates `$dw_mode` + the `teams*` and
  `sandboxRoot` globals; hard-stops with the envelope-shaped error
  when `dw_mode` is missing or set to anything other than
  `producer` | `reviewer`.

Stata-side `dw_api_fetch` and Parquet / RDS read support remain out of
scope by design (route through R or Python and `dw_save` to `.dta`).

### Issue #14 — Producer / reviewer mode contract tightening (**BREAKING**)

Refines the producer / reviewer split so that producer outputs are
provably redundant and reviewer reads are provably canonical.  R +
Python siblings ship in lock-step.

- **Producer-mode writes are now redundant.**  Every primary write
  fans out to BOTH the Teams canonical mirror AND the Z: drive mirror
  (whichever are available).  `dw_save` hard-stops with the standard
  envelope when neither mirror is configured / reachable — producer
  outputs cannot live only on the producer's laptop.
- **Reviewer-mode writes broadened.**  In addition to refusing writes
  under canonical (v0.3.0), `dw_save` now also refuses writes under
  the configured Z: drive root.  Bypass with `allow_canonical_write =
  TRUE` for deliberate DBM bootstraps as before.
- **Reviewer-mode reads are network-first.**  `dw_use` now tries
  Teams → Z: → repo-local in reviewer sessions.  When the network
  mirrors are unavailable and a local copy exists, the read still
  succeeds but emits an envelope-shaped warning flagging the
  provenance gap.  Hard-stops when the file is missing everywhere.
  Producer-mode read order is unchanged (local-first; v0.3.0
  preserved).
- **`overwrite` default flipped TRUE → FALSE.**  This is the only
  source-incompatible change in v0.4.0.  The overwrite check now
  examines ALL three destinations (primary, Teams, Z:); the helper
  refuses if any of them already exists.  Pass `overwrite = TRUE`
  explicitly to restore v0.3.0 behaviour.  (Python: same flip on the
  `overwrite: bool` argument; the legacy `mirror_to_z` keyword is
  silently dropped with a `DeprecationWarning`.)
- **New `dw_toolkit_version()`** (R + Python).  Returns the toolkit
  semver as a single string (`"0.4.0"`).  Useful for stamping logs
  and asserting minimum-version requirements in consumer profiles.

**Migration guide.**  Existing producer-mode callers that relied on
the v0.3.0 silent re-write semantics must either:

1. Set `overwrite = TRUE` explicitly when overwriting an existing
   deposit.  This is the common path for daily re-runs of the same
   vintage.
2. Or sequence the write under a fresh vintage subfolder so no prior
   deposit collides.  This is the recommended pattern for archival
   work.

Reviewer-mode callers do not need changes — the new network-first
read order is transparent when Teams/Z: are reachable; the new
warning surfaces when they are not (which used to be a silent
provenance gap).

**Regression coverage.**  9 new testthat assertions in
`r/tests/testthat/test-dw_io-mode-contract.R` (161 total R asserts;
0/0/0 from `devtools::check`) and 9 new smoke checks in
`python/tests/manual/smoke_test.py` (34 total).  Error-envelope test
file extended to keep `[cso_toolkit.<func>] WHAT / Why / Fix` shape
on every new raise.

### DW-Production backports (v0.3.0.9000 development line)

**Landed via PR adopting the four undeclared local edits found by
`docs/dw-production-alignment-2026-05-25.md`:**

- **B1 (new feature):** `dw_use("https://...")` is now a first-class
  call site.  R: new `.is_allowlisted_url()`, `.dw_frozen_root()`,
  `.url_to_frozen_path()`, `.write_remote_provenance()`,
  `.download_and_freeze()`, `.resolve_remote_url()` in `r/R/dw_io.R`,
  with `dw_use()`'s read resolver dispatching on
  `^https?://`.  Python: same shape in `python/src/dw_io.py`.
  Allowlist is **empty by default** so the toolkit ships
  consumer-neutral; the consumer's profile populates
  `dw_url_allowlist` (R global) / `_state.dw_url_allowlist` (Python).
  Reviewer mode refuses to fetch new URLs; producer mode downloads
  once and writes a `.provenance.json` with `sha256` + `bytes` +
  `fetched_at` + `fetched_by` + `dw_mode`.  Three new `_state` keys:
  `dw_url_allowlist`, `dw_frozen_root`, `githubFolder`.

- **B2 (QoL fix):** `dw_save` auto-detects gzip when the path already
  ends in `.gz` (was previously a foot-gun: passing
  `compress = FALSE` and a `.gz` path would write the file
  uncompressed under the misleading name).

- **B3 (robustness fix):** `.provenance.json` sidecar write is now
  wrapped in `tryCatch` (R) / `try/except` (Python) so a
  non-serialisable metadata value warns rather than rolling back the
  primary file.  Sidecars are metadata; the asset is what matters.

- **B4 (bug fix):** `dw_api.R` UIS-fetcher URL-encodes query keys +
  values via `utils::URLencode(reserved = TRUE)`; previously param
  values containing `&` / `=` / spaces / non-ASCII would corrupt the
  query.  Default cache extension for `http` and `github_raw` APIs
  bumped from `csv` to `rds` (R) / `pkl` (Python) so text and binary
  payloads round-trip correctly.

**Regression tests:** `python/tests/manual/smoke_test.py` now exercises
5 new B1–B4 invariants (20 total).  `R CMD check` remains 0/0/0.

## v0.3.0 (2026-05-25)

First release with full **Python parity** for every R helper, plus the
**R Roxygen-complete reference** (NAMESPACE + 26 Rd files + pkgdown
config), and a **three-part error envelope** (`[cso_toolkit.<func>]
WHAT / Why / Fix`) standardised across R and Python.

**Python helpers (new):**

- `python/src/` — full Python port of every R helper.  Same behaviour
  contract; mode-aware path routing, Z: drive mirror, provenance
  sidecars, version-drift detection.  Imports via
  `from cso_toolkit import dw_save, dw_use, dw_api_fetch, ...`.  10
  modules + foundation (`_state.py`, `__init__.py`); 26 public entries.
- `python/pyproject.toml` — optional `pip install -e python/` for
  local development; vendoring remains the production model.
- `python/src/py.typed` — PEP 561 marker so type-checkers see the
  type hints when consumers vendor the package.
- `python/tests/manual/smoke_test.py` — bootstraps `python/src/` under
  the name `cso_toolkit`, then exercises 15 invariants end-to-end
  (`dw_save` → `dw_use` roundtrip + provenance sidecar; `dw_isid`
  duplicate detection; `aggregate_data_v2` with coverage threshold;
  `dw_nestweight` preserves stratum totals; `create_profile` +
  `review_profile` pass all required checks; `test_scripts` catches a
  raw `pd.read_csv`; `cso_toolkit_check` returns `None` on missing
  manifest; plus 3 regression checks for path-prefix matching,
  secrets-redaction, and `_get` falsy-value handling).
- `python/tests/manual/error_envelope_test.py` — 30-path contract test
  asserting every public Python raise emits the
  `[cso_toolkit.<func>]` prefix + `Fix:` guidance.
- `docs/dw_io_python_reference.md` + `docs/dw_api_python_reference.md`
  — per-function references mirroring the existing R-side docs.
- Every public Python function carries a `Raises:` section enumerating
  the typed exceptions it can raise.  Every raise site emits a
  three-part **WHAT / WHY / HOW** message prefixed
  `[cso_toolkit.<func>]` so callers can grep and so library messages
  stand out from upstream traceback noise.
- HTTP, JSON-parse, CSV-parse, and YAML failures in `dw_api.py` and
  `generate_markdown_report.py` are wrapped with the same envelope —
  no bare `requests.HTTPError` / `KeyError` / `pd.errors.ParserError`
  bubbles up uncaught.
- Sensitive keys (`token`, `headers`, `api_key`, `password`, …) in
  `dw_api_fetch` kwargs are redacted before they reach the
  `.provenance.json` sidecar (`_redact_sensitive` walker in
  `dw_api.py`).
- `dw_is_canonical` now uses a path-aware descendant check so
  `/data/wrk-canary/...` no longer false-matches a root of
  `/data/wrk-can`.

**R helpers (documentation):**

- Roxygen pass across `dw_io.R`, `dw_api.R`, `cso_toolkit_sync.R`,
  `generate_markdown_report.R`, and `aggregate_data.R`. Every exported
  function now has `@param` / `@return` / `@export`; every internal
  helper carries `@keywords internal` + `@noRd`. The package now ships
  a generated `NAMESPACE` exporting 26 functions and a `man/` directory
  with one `.Rd` per export. No behaviour change.
- `@seealso` + `@family` Roxygen tags added on every export, grouped
  into eight families (`io`, `api`, `sync`, `aggregate`,
  `survey-weights`, `reporting`, `scaffolding`, `audit`).
- `r/_pkgdown.yml` — pkgdown reference site config with the eight
  grouped sections; UNICEF cyan/navy bootstrap theme.
- `r/LICENSE` — CRAN-style 2-line MIT pointer so `License: MIT + file
  LICENSE` resolves under `R CMD check`.
- `r/R/zzz.R` — single shared `.cso_require()` helper plus
  `utils::globalVariables()` declarations for dplyr / tidyr NSE
  references. Previous duplicate `.cso_require()` definitions in
  `aggregate_data_v2.R` and `generate_markdown_report.R` removed; calls
  moved into public function bodies to avoid source-time side effects.
- Every R `stop()` / `warning()` now follows the same three-part
  envelope as Python: `[cso_toolkit.<func>] WHAT.\n  Why: ...\n  Fix:
  ...` with `call. = FALSE`.
- `r/DESCRIPTION` — version bumped to `0.2.1.9000` (dev) ahead of the
  next release. `Imports:` now lists `dplyr`, `tidyr`, `tibble`,
  `rlang` (previously only `data.table` / `digest` / `jsonlite` /
  `yaml` / `readr`). `Suggests:` adds `readxl` and `writexl`.
- `R CMD check` now passes 0 errors / 0 warnings / 1 environmental
  note (was 1 error / 4 warnings / 3 notes).

**Sync / vendoring infrastructure:**

- `templates/.toolkit_manifest.yml` — header expanded with a field-by-field
  reference; `pulled_version` bumped to `v0.2.0`; sample `vendored:` list
  now mentions the seven optional helpers as commented-out entries so
  consumers can opt in without re-deriving the file list.
- `r/tests/manual/check_consumer_side.R` — manual smoke test that
  simulates a consumer repo, drops a manifest into it, sources the
  vendored helpers, and calls `cso_toolkit_check()` end-to-end against
  the live GitHub API. Use as a release-eve verification.

**Documentation:**

- `r/README.md`, `python/README.md`, `stata/README.md` — new
  per-language top-level READMEs with install paths, layout, quick
  start, mode contract, error envelope, testing.
- Top-level `README.md` Status + Versioning bullets refreshed to
  reflect the v0.2.0 / v0.3.0 release window (previously frozen on
  v0.1.0-rc1).
- `r/R/README.md` — added link to Python siblings; manifest example
  bumped `v0.1.0-rc1 → v0.2.0`.

## v0.2.0 (2026-05-24)

Stata helpers shipped; R analytical helpers expanded; rebrand as the
UNICEF Chief Statistician Office (CSO) toolkit.

**Stata helpers (new):**

- `stata/src/dw_save.ado` — uniform Stata `save` wrapper with `isid` +
  `compress` + sibling `.provenance.json` sidecar matching the R-side
  shape. Honours producer / reviewer mode via `$dw_mode`; canonical
  writes blocked in reviewer mode unless `allow_canonical_write` is
  passed. Lineage: `edukit_save` (Diana Goldemberg).
- `stata/src/dw_compare.ado` — merges two `.dta` files on `idvars` and
  classifies each value column as identical / numerically-equivalent /
  different. Lineage: `comparefiles` (Kristoffer Bjärkefur).
- `stata/src/dw_mkdir.ado` — recursive `mkdir` for Stata. Lineage:
  `rmkdir` (Kristoffer Bjärkefur).

**R helpers (additions):**

- `aggregate_data.R` — original `aggregate_data()` (mean / weighted_mean,
  optional global aggregate, population + country coverage). Lifted from
  `DW-Production/00_functions/`. Kept for back-compat.
- `aggregate_data_v2.R` — `aggregate_data_v2()` with `weighted_mean`, `mean`,
  `sum`, `proportion`; coverage threshold; metadata columns. Ships
  `generate_agg_footnote()`, `apply_time_window()`, and a v1-compatible
  wrapper that delegates the v1 signature to v2.
- `dw_nestweight.R` — port of World Bank EduAnalyticsToolkit
  `edukit_nestweight` (Diana Goldemberg). Redistributes survey weights
  from missing nested observations so per-stratum totals are
  preserved.
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
- `docs/dw_io_reference.md` — per-function reference for `dw_io.R` lifted
  out of the DW-Production `00_functions/README.md`.
- `docs/dw_api_reference.md` — per-function reference for `dw_api.R` (same
  lift; behaviour matrix, supported APIs, worked SDMX example, sector
  migration checklist).
- Workflow diagrams (`docs/workflow_*.svg`) added.

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
