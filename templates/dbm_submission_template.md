# Pre-Deposit Review Checklist — `{{sector}}` / `{{vintage}}`

> Canonical template. Copy to `00_documentation/deposit_reviews/{{sector}}_{{vintage}}.md` per submission.
> Once `unicef-drp/cso-toolkit` exists, the canonical source is
> `cso-toolkit/templates/dbm_submission_template.md`; this file is a vendored
> copy under that repo's manifest.
>
> Placeholders to replace before sharing: `{{sector}}`, `{{vintage}}`,
> `{{dbm_handle}}`, `{{date_start}}`, `{{date_end}}`, `{{git_sha}}`,
> all metric blocks below.

## 0. Submission metadata

| Field | Value |
|---|---|
| Sector code | `{{sector}}` |
| Vintage label | `{{vintage}}` (e.g., `2026-Q2`, `WPP-2024-rev1`) |
| Producer (DBM) | @{{dbm_handle}} |
| Review window | {{date_start}} — {{date_end}} |
| Pipeline branch | `{{branch_or_tag}}` |
| Commit at submission | `{{git_sha}}` |
| Prior vintage compared against | `{{prior_vintage}}` (label + commit if known) |
| dw_io / dw_api versions | from `00_functions/.toolkit_manifest.yml` |
| `dw_mode` of submission run | `producer` (required for deposit) |
| Z: drive mounted during run? | `{{yes_no}}` (if no: no Z: mirror; flag at §6) |

## 1. Upstream provenance — what changed since the prior vintage

For each cached API source in `060.DW-MASTER/01_dw_prep/011_rawdata/_apis/`,
record what changed since `{{prior_vintage}}`. Use `dw_api_inventory()` to
list all caches; then for each, read `<cache_path>.provenance.json` and
inspect the `fetched_at` timestamp.

| api / cache_key | prior `fetched_at` | this `fetched_at` | upstream-publisher vintage | refresh decision |
|---|---|---|---|---|
| `wb / wb_lp_primary_2000_{{year}}` | `{{prior}}` | `{{this}}` | WB Open Data {{wb_release}} | refresh / keep / N/A |
| `wb_indicators / wb_indicator_catalogue` | `{{prior}}` | `{{this}}` | wbstats {{wbstats_ver}} | refresh / keep / N/A |
| `sdmx_codelist / {{n}} codelists` | `{{prior}}` | `{{this}}` | UNICEF SDMX | refresh / keep / N/A |
| `uis / *` | ... | ... | UIS Bulk SDG_{{yyyymm}} | ... |
| `github_raw / unicef_regions_*` | ... | ... | unicef-drp/Country-and-Region-Metadata@{{sha}} | ... |
| ... | | | | |

Bullet-list any upstream API endpoint that is known to be unreliable from
the corporate net (e.g., UNICEF SDMX 403 — `unicef-drp/UNPD-Population#9`).
For those, the cache MUST come from a working upstream run; producer-mode
fetches on UNICEF-laptop will not work.

## 2. Known pre-existing bugs gating this deposit

These are bugs surfaced by the reproducibility audit. **A submission must
either resolve, accept-with-rationale, or defer with a linked sign-off
comment for each item below.**

### P0 (must resolve or explicit sector-lead sign-off)

- [ ] `unicef-drp/UNPD-Population#3` — committed UNPD API bearer token
      (security; private repo only but rotate anyway)
- [ ] `unicef-drp/UNPD-Population#4` — trailing-pipe NULL bug in
      `processing_WPP.r:423`; `wpp.pop.single.age` is silently NULL;
      affects `DM_POP_TOT_AGE` downstream of UNPD-Production
- [ ] `unicef-drp/UNPD-Population#5` — 8 projection indicators write to
      estimates CSV in `compile_DM_indicator_data.R:389,394-400`
- [ ] `unicef-drp/UNPD-Population#8` — `projectFolder2` undefined in
      `school-age_children.R`; script unrunnable upstream

### P1 (resolve before scaling beyond pilot sectors)

- [ ] `unicef-drp/UNPD-Population#6` — single-user `palma` gating in
      profile.R
- [ ] `unicef-drp/UNPD-Production#7` — reproducibility envelope (tests,
      CI, renv.lock, schema)
- [ ] `unicef-drp/UNPD-Production#9` — reviewer-mode cached fallback
      for UNICEF SDMX
- [ ] `unicef-drp/DW-Production#85` — `pop_school_age.csv` cache deposit
      cadence (was: blocker; now: cadence question)
- [ ] `unicef-drp/DW-Production#86` — `year_results` typo (RESOLVED in
      DW-Production v0.X)

Append any new findings filed during this deposit cycle.

## 3. Per-sector adoption status

Status of dw_io.R / dw_api.R adoption per sector (the cross-sector
adoption tracker is `unicef-drp/DW-Production#88`). A sector at
"flat" status has its outputs in this deposit but they were produced
by code that bypasses the mode contract; document the consequence.

| Sector | dw_io adoption | dw_api adoption | Reproducibility status (Appendix D) | This deposit covers? |
|---|---|---|---|---|
| `nt` | partial (helpers added; sector scripts pending) | **DONE** (codebook via `sdmx_codelist`) | reference | yes |
| `ed` | conductor + 03 adopted; 04/05 pending | **DONE** (LP via `wb` + `wb_indicators`) | partial (was: flat) | yes |
| `gn` | not started | not started | stub | {{yes_no}} |
| `spp` | not started | not started | deferred | {{yes_no}} |
| `im` | not started | not started | stub | {{yes_no}} |
| `wt` | not started | not started | stub | {{yes_no}} |
| `pv` | not started | not started | stub | {{yes_no}} |
| `mnch` | n/a (file-based) | n/a | stub | {{yes_no}} |
| `ecd` | n/a | n/a | stub | {{yes_no}} |
| `cme`, `dm`, `fd`, `mg`, `pt`, `cl` | n/a | n/a | stub / carve-out / upstream-consumed / deferred | usually no |
| `hva` | n/a (Stata) | n/a | flat (Stata) | {{yes_no}} |
| `ws` | n/a (Stata) | n/a | flat (Stata) | {{yes_no}} |
| `econ` | not started | partial | deferred | {{yes_no}} |

Sectors marked `flat` in Appendix D have outputs in this deposit but
their producing code does not honour the mode contract. Document the
reproducibility consequence: a reviewer cannot re-run those sectors
end-to-end without writing into canonical paths.

## 4. Pipeline run record

For each sector's conductor run during this deposit cycle:

```
Sector: {{sector}}
Conductor: {{path/to/0_execute_conductor.R or 00_run_<sector>.R}}
Started:  {{ts}}
Finished: {{ts}}
Elapsed:  {{minutes}} min
dw_mode at run: producer
Z: mirror active: {{yes_no}}

Output files written (relative to outputdir):
  - final/<sector>_tocopy.csv  ({{rows}} rows × {{cols}} cols, {{bytes}} bytes)
  - final/<sector>_aux_*.xlsx  (...)
  - temp/<sector>_compare_*    (compare reports — see §5)

API caches refreshed (from dw_api_inventory()):
  - <api>/<cache_key>  ({{new_rows}} rows; was {{old_rows}})
  - ...
```

If a sector's conductor failed mid-run, paste the last 20 lines of
output. Common patterns surfaced during the 2026-05 pilot:

- "Column `_T` doesn't exist" — usually a pivot on a regional aggregate
  with NA TIME_PERIOD; check the relevant aggregation logic
- "object '<x>' not found" — typo / incomplete rename (compare with
  upstream merge state; resolve any committed `<<<<<<<` markers)
- "Reviewer mode forbids API calls..." — should not appear in a
  producer-mode run; if it does, `dw_mode` is mis-set

## 5. Compare-vs-prior-vintage report

For each output file in this deposit, run:

```r
report <- dw_compare(
  current   = file.path(finaldir, "<sector>", "<file>_tocopy.csv"),
  reference = file.path(teamsWrkDataCanonical, "<sector>", "<file>.csv"),
  by                  = c(<the SDMX key columns for this sector>),
  value_cols          = c("OBS_VALUE", "DATA_SOURCE", ...),
  numeric_value_cols  = c("OBS_VALUE", ...),
  tol                 = 1e-5,
  label               = "<sector>_<file>",
  write_report_to     = file.path(tempdir, "<sector>_compare_warehouse")
)
report$summary
```

Paste the resulting summary table here:

| label | repro_rows | canonical_rows | added | removed | changed | completed_at |
|---|---|---|---|---|---|---|
| `{{label_1}}` | {{n}} | {{n}} | {{n}} | {{n}} | {{n}} | {{ts}} |
| `{{label_2}}` | {{n}} | {{n}} | {{n}} | {{n}} | {{n}} | {{ts}} |

Example from the 2026-05-24 ed pilot:

| label | repro_rows | canonical_rows | added | removed | changed | completed_at |
|---|---|---|---|---|---|---|
| `dw_ed_edu` | 107,770 | 109,449 | 526 | 2,205 | 702 | 2026-05-24 08:46 |
| `dw_ed_ln`  | 1,902 | 2,241 | 1,638 | 1,977 | 0 | 2026-05-24 08:46 |

## 6. Triage decisions

For each non-zero `added` / `removed` / `changed` row above, classify
the cause. Use this taxonomy:

| Class | Meaning | Example |
|---|---|---|
| `stale-cache` | API cache hasn't been refreshed since upstream changed | wb_data 2026 vintage but cache still on 2025 |
| `retired-upstream-indicator` | An indicator that existed in prior vintage was retired upstream | `SE.LPV.PRIM.SD*` at WB (2026 audit) |
| `methodology-change` | Sector script logic changed; new outputs are correct | aggregate_uis_sdg.R `edu_uis_year_indicator` join (DW-Production v0.X) |
| `rounding` | Float-precision differences below tolerance | regional weighted means rounded differently |
| `bug` | New finding; needs an issue | column reference typo; NA propagating wrongly |
| `uninvestigated` | DBM hasn't classified yet | (block deposit if any remain at submission) |

Fill in:

| File | Class | Linked issue / PR / sign-off | Notes |
|---|---|---|---|
| `{{file_1}}` | {{class}} | `#{{NNN}}` | {{1-line}} |
| ... | | | |

## 7. Z: mirror integrity

If Z: was mounted during the run:

```r
# For each canonical write in this deposit:
res <- dw_verify_z(
  path = file.path(teamsWrkDataCanonical, "<sector>", "<file>.csv"),
  compare = "sha256"
)
```

| file | status | primary_size | z_size | sha256_match |
|---|---|---|---|---|
| `{{file}}` | `match_sha256` | {{n}} | {{n}} | TRUE |
| `{{file}}` | `size_mismatch` | {{n}} | {{n}} | n/a |

Mismatches: investigate before sign-off. The Z: drive can lag by minutes
on large writes; a second sha256 check after a 5-minute wait usually
resolves transient mismatches.

If Z: was NOT mounted: this deposit goes to Teams only. Flag explicitly
so the next producer can re-mirror.

## 8. Sign-off

Pre-deposit gate. Producer cannot promote `<sector>_tocopy.csv` →
`dw_<sector>.csv` until every item below is `true` (or explicitly
accepted with a rationale).

- [ ] Every P0 bug in §2 is resolved or explicitly accepted (link the sign-off comment per item).
- [ ] Every non-zero diff in §5 is classified in §6 (no `uninvestigated` remaining).
- [ ] Sector lead has signed off on the §5 deltas they own (`@karavan88` for ed; etc.).
- [ ] `dw_verify_z` shows Teams == Z: byte-equal for every canonical write (§7), or Z: state explicitly flagged.
- [ ] `dw_api_inventory()` shows every cache used by this run was either fresh or knowingly kept.
- [ ] `00_functions/.toolkit_manifest.yml` is on a tagged cso-toolkit version (no `inrepo` or `unreleased` suffixes).
- [ ] `CHANGELOG.md` has an entry for this vintage.
- [ ] Promotion done: `cp finaldir/<sector>_tocopy.csv teamsWrkData/dw_<sector>.csv`
- [ ] (Optional) `git tag` cut and `gh release create` posted.

Sign-off comment on the PR / issue tracking this deposit:

> Pre-deposit checklist complete; promotion authorised.
> — @{{dbm_handle}}, {{iso_timestamp}}

## See also

- `00_documentation/roles_and_workflow.md` — the role model behind PRODUCER / REVIEWER / INGESTOR
- `00_documentation/toolkit_strategy.md` — why helpers live in cso-toolkit; vendoring contract
- `book/appendices/d-sector-coverage.qmd` — per-sector reproducibility status
- `00_functions/README.md` — what each helper does
- `unicef-drp/DW-Production#85` — the cache-deposit issue that prompted this template
- `unicef-drp/DW-Production#88` — cross-sector adoption tracker
