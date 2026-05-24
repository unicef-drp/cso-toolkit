# Mode-contract integration

How to wire the `dw_mode` (producer / reviewer) contract into a sector
profile and its conductor scripts. This is the operational counterpart to
[roles_and_workflow.md](roles_and_workflow.md): roles_and_workflow.md says
*who does what*; this file says *how to make the code enforce it*.

## 1. The user_config.yml contract

Each user keeps a personal block in `~/.config/user_config.yml`:

```yaml
jpazevedo:
  githubFolder: "C:/GitHub/mytasks"
  teamsRoot: "C:/Users/jpazevedo/UNICEF/Chief Statistician Office - Documents"
  dw_mode: "reviewer"                                  # producer | reviewer
  sandboxRoot: "C:/Users/jpazevedo/dw-repro"           # only used when dw_mode = reviewer
```

`dw_mode` is **required**. Profile loading must hard-fail if it is absent —
defaulting to either side is unsafe (defaulting to producer corrupts the
deposit; defaulting to reviewer surprises a DBM mid-deposit).

## 2. profile_DW-Production.R derivation

After reading the user block, derive five globals from `dw_mode`:

| Global | Producer mode | Reviewer mode |
|---|---|---|
| `teamsFolder` | user's actual Teams sync root | `sandboxRoot` |
| `teamsRawData` | `teamsFolder/01_dw_prep/011_rawdata` | `sandboxRoot/01_dw_prep/011_rawdata` |
| `teamsWrkData` | `teamsFolder/01_dw_prep/013_wrkdata` | `sandboxRoot/01_dw_prep/013_wrkdata` |
| `teamsFolderCanonical` | identical to `teamsFolder` | user's actual Teams sync root (read-only) |
| `teamsRawDataCanonical` | identical to `teamsRawData` | `teamsFolderCanonical/01_dw_prep/011_rawdata` |
| `teamsWrkDataCanonical` | identical to `teamsWrkData` | `teamsFolderCanonical/01_dw_prep/013_wrkdata` |
| `dw_apis_allowed` | `TRUE` | `FALSE` |

The `*Canonical` aliases let reviewer-mode code *read* the deposit (for
compare-against-canonical) without ever *writing* to it. Producer mode
collapses them to the same path.

Also emit a prominent mode banner at load time:

```
⚠️ PRODUCER mode — writes will land in the Teams deposit.
   Use this mode only when you intend to promote outputs to canonical.
```

or

```
✅ REVIEWER mode — writes isolated to <sandboxRoot>.
   Canonical deposit at <teamsFolderCanonical> is read by code but never written.
```

## 3. Conductor-level shadow pattern

The single most important integration point. At the top of each sector's
`0_execute_conductor.R`, after sourcing the profile, **shadow the globals**:

```r
# After computing outputdir for this run (with branch-slug isolation):
finaldir <- file.path(outputdir, "final")

# Conductor-level shadow: redirect downstream reads/writes without per-script edits
teamsRawData    <- teamsRawDataCanonical   # reviewer-mode: read canonical inputs
teamsWrkData    <- finaldir                # reviewer-mode: writes go to sandbox final
dwWrkData       <- finaldir                # same
```

Why a shadow at conductor level and not per-script: sector codebases have 10–40
scripts each that reference these globals. Editing each one breaks the diff
audit. Shadowing once at the conductor lets every downstream script keep its
existing code and still get mode-correct paths.

## 4. Branch-slug isolation (nt-pattern, optional but recommended)

```r
branch <- tryCatch(
  system("git rev-parse --abbrev-ref HEAD", intern = TRUE),
  error = function(e) "main"
)
branch_slug <- gsub("[^A-Za-z0-9._-]", "-", branch)

canonical_outputdir <- file.path(teamsRawData, sector, "output")
outputdir <- if (branch %in% c("main", "dev", "master")) {
  canonical_outputdir
} else {
  file.path(canonical_outputdir, "branches", branch_slug)
}
```

This composes with the mode contract: in reviewer mode, `teamsRawData` is
already under `sandboxRoot`, so feature-branch outputs land under
`<sandboxRoot>/.../sector/output/branches/<slug>/` and the canonical deposit
is never touched even when the reviewer is on a feature branch.

## 5. The dw_require_no_api() defence in depth

Even with the mode contract enforced at the profile, individual API helpers
must check again. Every entry point that hits a remote calls:

```r
dw_require_no_api <- function(api_label = "API") {
  if (!isTRUE(getOption("dw.apis_allowed", default = dw_apis_allowed))) {
    stop(sprintf(
      "Reviewer-mode contract violated: %s call not permitted. ",
      api_label
    ), "All upstream inputs must be pre-deposited at:\n  ",
       teamsRawDataCanonical,
       "\nIf this input is missing, escalate to the sector DBM; do not call the API.",
       call. = FALSE)
  }
}
```

`dw_api.R::dw_api_fetch()` invokes this at the very top, before any
`httr::GET`. So does any sector-internal script that talks to a remote.

## 6. Stata side (v0.2)

`profile_DW-Production.do` will mirror the R derivation, reading the YAML and
setting equivalent globals (`$dwMode`, `$sandboxRoot`, `$teamsFolder`,
`$teamsRawData`, `$teamsWrkData`, `$teamsFolderCanonical`, etc.). HIV
(`hva/010_hiv_dw_1.do:49,61`) and WASH (`ws/01213_ws_dw_hhs.do:293-294,457,621`)
each have `save` calls that today reference `$teamsFolder` directly; once the
profile mode-routes that global, the `save` calls automatically land in the
sandbox in reviewer mode without per-call edits — same shadow trick as R.

This Stata work ships in cso-toolkit v0.2.

## 7. Verification checklist for a new sector

When a sector adopts the contract:

1. `source("profile_DW-Production.R")` with `dw_mode: "reviewer"` produces a
   green banner.
2. `<sector>/0_execute_conductor.R` writes `finaldir` and shadows the three
   globals before any other script is sourced.
3. No script inside `<sector>/` calls a remote without going through
   `dw_api_fetch()` (grep for `httr::GET`, `httr::POST`, `httr::request`,
   `RETRY`, `read.csv\("http`).
4. A reviewer-mode end-to-end run produces every artifact under
   `sandboxRoot`; `mtime` of the canonical deposit is unchanged before/after.
5. A producer-mode end-to-end run produces every artifact under the canonical
   deposit, as today.
6. `<sector>/N_compare_vs_warehouse.R` runs in reviewer mode and produces a
   per-segment report under `<sandbox>/.../<sector>/output/temp/`.

Steps 4–6 are the operational definition of "the sector adopts the mode
contract."
