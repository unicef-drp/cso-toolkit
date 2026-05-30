# Toolkit strategy — `unicef-drp/cso-toolkit`

> Canonical source. The book chapter at
> `book/chapters/<NNN>-toolkit-strategy.qmd` includes this file via Quarto's
> `{{< include >}}` shortcode — don't edit two places.

## Why a separate toolkit repo

The helpers in `00_functions/` (`dw_io.R`, `dw_api.R`, `cso_toolkit_sync.R`, the DBM submission template, the roles document) are **not specific to DW-Production**. They encode a shared workflow:

- Producer / reviewer mode contract + publisher publication boundary
- Mode-aware file IO with provenance sidecars
- Mode-aware API caching with deposit-side persistence
- Sector-comparison reporting
- The DBM pre-deposit checklist

Other DAPM-CSO repositories — `unicef-drp/UNPD-Population`, `unicef-drp/datalib-dev`, and any future deposit-bearing repository — need the same primitives. Today, each would have to vendor its own copy of these files, with the same drift risk that the cross-sector API audit (2026-05-23) found in the GitHub-regional-metadata fetches (4 CSVs read independently in 5 sectors with no shared vintage record).

**`unicef-drp/cso-toolkit`** will be the single source of truth for these primitives. Consuming repositories vendor copies at a specific tagged version, with explicit producer-driven refresh.

## What lives in cso-toolkit

| Subtree | Content |
|---|---|
| `R/` | Canonical helper source files (`dw_io.R`, `dw_api.R`, future siblings) |
| `stata/` | Future Stata equivalents (e.g., `dw_save.ado`, `dw_use.ado`) |
| `templates/` | Repo-neutral templates: `dbm_submission_template.md`, sector-script scaffolds |
| `docs/` | Canonical operational docs: `roles_and_workflow.md`, `mode_contract.md` |
| `tests/testthat/` | Unit tests for the R helpers |
| `DESCRIPTION` | Version + dependencies (CRAN-style, even if never published to CRAN) |
| `NEWS.md` | Per-version release notes — what changed between v0.1.0 and v0.2.0 |
| Git tags `v0.1.0`, `v0.2.0`, ... | Semantic versioning |

## What does NOT live in cso-toolkit

- DW-Production's profile or sector code
- DW-Production's `_config_template/user_config.yml`
- Sector-specific data, indicator lists, or pipeline conductors
- Anything that references a specific sector's domain

## Vendoring (not sourcing)

Each consuming repository **copies** the cso-toolkit files into its own
`00_functions/` directory. The copies are tracked in git for that repo;
they freeze the vintage. There is no live `source()` from a network
location at session start.

This pattern was chosen over `devtools::install_github("unicef-drp/cso-toolkit")` because:

1. **Reproducibility**: every consuming repo's git history shows exactly which helper code was in effect at any commit. No "the repo's pinned version was X but the running R session installed Y".
2. **Producer-controlled refresh**: cso-toolkit updates are not automatically pulled. The producer reviews release notes, decides if the new vintage is appropriate, and explicitly refreshes.
3. **Reviewer offline reproducibility**: A reviewer with no network access can still re-run the full pipeline because the vendored helpers are right there in the repo.
4. **Cross-language symmetry**: Stata equivalents follow the same model (the `cso-toolkit/stata/` ado-files get copied into a consuming repo's `99_ado/` or similar). A package model wouldn't fit Stata well.

The `00_functions/.toolkit_manifest.yml` file records the vendored vintage. `00_functions/cso_toolkit_sync.R` provides the check / diff / pull workflow.

## Workflow when cso-toolkit updates

```
                  cso-toolkit (upstream)
                  ┌────────────────────────┐
                  │  v0.1.0  v0.2.0  v0.3.0│
                  └──────────┬─────────────┘
                             │
                  (producer runs cso_toolkit_check() at session start)
                             │
                             ▼
              ┌──────────────────────────────────┐
              │  Newer tag detected?             │
              ├──────────────────────────────────┤
              │  YES: Log a yellow alert with:   │
              │   * pinned version               │
              │   * upstream version             │
              │   * pointer to NEWS.md           │
              │   * suggested cso_toolkit_pull() │
              │  NO: stay silent                 │
              └──────────────────────────────────┘
                             │
            (producer decides; reviewer never sees this branch
             because the check is gated by dw_apis_allowed)
                             │
                ┌────────────┴────────────┐
                ▼                         ▼
      cso_toolkit_pull("v0.2.0")    do nothing (keep pinned)
       * fetch files at tag
       * sha256-diff vs vendored
       * prompt per-file: overwrite | skip | show-diff
       * update manifest
       * log summary
```

The check is a **producer-mode-only** operation. The reviewer-mode contract forbids external network calls (`dw_apis_allowed = FALSE` blocks the GitHub lookup). Reviewers run against whatever vintage the producer has pinned; if they want to validate against a different vintage, they do it through a separate producer-mode session.

## Phasing

**Phase 1** (this PR cluster): helpers live in DW-Production's `00_functions/` as if they had been vendored from a yet-to-exist v0.0.0. The manifest records `pulled_version: "0.0.0-inrepo-2026-05-24"`; `cso_toolkit_sync.R` exists as a stub that gracefully no-ops because the upstream repo doesn't exist yet.

**Phase 2** (next workstream, scoped separately):
1. Create `unicef-drp/cso-toolkit`
2. Lift `dw_io.R`, `dw_api.R`, `roles_and_workflow.md`, `dbm_submission_template.md` into the new repo
3. Tag `v0.1.0-rc1` (per `feedback_rc_tag_for_first_workflow_run`)
4. Smoke-test the `cso_toolkit_pull("v0.1.0-rc1")` flow on DW-Production
5. Tag `v0.1.0` once smoke passes
6. Update DW-Production's `.toolkit_manifest.yml` to record `pulled_version: v0.1.0`

**Phase 3** (later): UNPD-Population, datalib-dev, and other consumers adopt the same vendoring pattern.

## See also

- `00_functions/README.md` — what's in each helper
- `00_functions/.toolkit_manifest.yml` — current vendored vintage
- `00_functions/cso_toolkit_sync.R` — check / diff / pull helpers
- `00_documentation/roles_and_workflow.md` — the broader role model the toolkit serves
- World Bank `EduAnalyticsToolkit` (Stata equivalent of the same pattern): <https://github.com/worldbank/EduAnalyticsToolkit>
