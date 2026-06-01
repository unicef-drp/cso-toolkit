# NEWS — cso-toolkit

## Unreleased

_Entries land here as PRs merge into `develop`. When the next release
is cut, this header is renamed `## v0.4.10 (YYYY-MM-DD)` and a fresh
`## Unreleased` section is added back._

## v0.4.9 (2026-06-01)

Headline feature: `dw_stage()` — reviewer-mode auto-stage with hash-
guard. Reviewer pipelines that read canonical inputs which live on
Teams or Z: but not yet in the reviewer's local sandbox can now opt
into automatic, integrity-checked staging via `dw_use(stage = TRUE)`
(per-call) or a session-level `dw_autostage <- TRUE` global. Producer-
mode is a deliberate no-op; the v0.4.0 producer write contract is
unchanged. RFC + spec at `DW-Production/docs/proposals/reviewer-
autostage-rfc.md`.

PR [#91](https://github.com/unicef-drp/cso-toolkit/pull/91).

### Five-state lifecycle (plus cross-mirror integrity branch)

`dw_stage(path, overwrite = FALSE)`:

- **First stage**: file missing → copy from first available source
  (Z: > Teams) via atomic `<path>.dw_stage.tmp` → `file.rename()` →
  re-hash the staged copy against the source hash (retry once, then
  STOP with the `[cso_toolkit.dw_stage] COPY INTEGRITY` envelope) →
  archive the hash in a `<path>.staged.json` sidecar.
- **Second run** (`overwrite = FALSE`): sandbox + sidecar both exist
  and the sandbox sha matches the archived sha → no-op, returns the
  sandbox path. The sandbox file is NEVER re-copied without an
  explicit `overwrite = TRUE`.
- **Tampered sandbox**: sandbox sha differs from archived sha →
  `[cso_toolkit.dw_stage] SANDBOX DRIFT` STOP with explicit
  `Fix: re-stage with overwrite = TRUE` guidance.
- **Forced re-stage** (`overwrite = TRUE`): unconditionally re-copy,
  re-verify, and re-archive, even if a sandbox copy already exists.
  On Windows, the existing sandbox file is removed before
  `file.rename()` so the atomic-rename pattern works cross-platform.
- **Upstream changed**: sandbox matches its archive, but the upstream
  Z:/Teams source no longer matches the archived hash (detected via
  a size+mtime fast-path with sha-only-on-change) → WARN. The
  sandbox is NOT auto-refreshed — re-stage is the reviewer's
  explicit decision.

**Cross-mirror integrity**: when both Z: and Teams hold the file,
they are sha-compared before either is used as source. Disagreement
is an envelope-shaped `[cso_toolkit.dw_stage] CANONICAL INTEGRITY`
STOP, and neither the sandbox copy nor the sidecar is written.

### Sidecar format + collision-safety

The sidecar at `<path>.staged.json` carries a `type: "dw_stage"`
discriminator field. The read path refuses to interpret sidecars
with a wrong `type` — so a sandbox file written by `dw_save()`
(which writes a `.provenance.json` sidecar with a different schema)
and later staged by `dw_stage()` keeps the two metadata blocks
side-by-side rather than overwriting each other. Sidecar I/O uses
`jsonlite::write_json` / `jsonlite::fromJSON` consistently with
`dw_save()`'s `.write_provenance`.

### `dw_use()` opt-in

Two new params, both default OFF — existing `dw_use()` callers see
no behaviour change:

- `stage = NULL`: when `TRUE`, the canonical input is staged via
  `dw_stage()` and the verified sandbox copy is read. When `NULL`,
  falls back to the session global `dw_autostage` (set via the
  profile); when that is also unset, staging is OFF. Only applies in
  reviewer mode and only to local (non-`http(s)://`) paths.
- `overwrite = FALSE`: forwarded to `dw_stage()` when `stage = TRUE`
  — forces a re-copy of the sandbox file from the canonical source
  and re-archives the hash sidecar. No effect when `stage` is not
  active.

### Test coverage

New `r/tests/testthat/test-dw_stage.R` pins the full T1–T6 lifecycle
(plus a producer-mode no-op assertion) against self-contained
sandbox/Z:/Teams tempdir fixtures per test. No real Teams sync or
Z: mount is touched.

### Origin

Prototyped on DW-Production `feat/dw_root-and-dw_stage` (commits
`88d986d` core + `67b1598` dw_use wiring + `1426f2c` hardening) and
ported here on PR #91 with code-review uplift — Windows file.rename
overwrite path, `[cso_toolkit.<func>]` envelope conformance across 6
stop/warning sites + explicit `Fix:` guidance lines.

## v0.4.8 (2026-06-01)

Same-day dashboard-hardening micro-release. Two issues land, both
exposed by the v0.4.7 dashboard refresh that failed at 13:56 UTC on
the v0.4.7 develop tip and blocked the public site from picking up
the v0.4.7 release. No R-package code or public API touched — the
substantive changes are confined to `.github/workflows/dashboard.yml`,
`docs/dashboard/collect.R`, and `docs/dashboard/render.R`.

### Leak-guard `OneDrive` over-match (issue [#85](https://github.com/unicef-drp/cso-toolkit/issues/85))

PRs [#86](https://github.com/unicef-drp/cso-toolkit/pull/86) (diagnostic uplift) + [#87](https://github.com/unicef-drp/cso-toolkit/pull/87) (substantive fix).

The 2026-06-01 dashboard refresh failed because the SOFT leak-guard
matched the bare word `OneDrive` in cso-toolkit's own public issue-#82
title (`"dw_is_canonical: derive OneDrive pattern from
teamsFolderCanonical at call time (#61.1 follow-up)"`). The workflow
comment had already anticipated this — "cso-toolkit's own public
issue/PR titles may legitimately mention them" — but the SOFT regex
still listed bare `OneDrive` while its scope still included
`docs/dashboard/index.html`.

The actually-sensitive content is the full personal OneDrive-mounted
Teams path of the form `C:\Users\<u>\UNICEF\<library> - Documents\
060.DW-MASTER\...`, which the HARD pattern `C:[\\/]Users` + the more
specific `060\.DW-MASTER` token already catch. Dropping bare
`OneDrive` from SOFT eliminates the false-positive without losing
any defensive coverage.

Discovery was unblocked by the diagnostic uplift shipped in #86:
`run_check()` now runs a second `grep -rhoE` after any match and
prints the deduplicated matched-token list inside a GHA `::group::`
(short and uncorrupted by log-line truncation), and a new
`if: failure()` step archives the regenerated `index.html` and
`state.json` as a 14-day artifact. Without #86 the original failure's
matched-line was truncated at ~23 KB in the GH Actions log (line 365
of the regenerated `index.html` is one 78 KB line), so the actual
matched token could not be identified.

### `prs_closed` semantic collision (issue [#74](https://github.com/unicef-drp/cso-toolkit/issues/74))

PR [#88](https://github.com/unicef-drp/cso-toolkit/pull/88).

`collect.R::dw_production` used `prs_closed` with two different
meanings: overall `counts$prs_closed` was closed-unmerged only
(since `counts$prs_merged` is tracked separately), but per-sector
`by_sector[..]$prs_closed` counted all non-open PRs (merged +
closed-unmerged together). Copilot's PR #72 review flagged the
collision as easy-to-misuse on a future refactor.

Fix (Option 2 from the issue body — the cheaper of the two): rename
the per-sector field to `prs_closed_total`. The renderer reads the
new field via `b$prs_closed_total %||% b$prs_closed %||% 0L` so a
stale `state.json` (rendered without re-running `collect.R`) still
surfaces the legacy field's value rather than silently showing 0.
The dashboard table column header changes from `Closed PRs` to
`Non-open PRs (merged + closed)` so the data matches the label.

### Verification

A `workflow_dispatch` against the post-merge develop tip confirms the
dashboard `refresh + leak-guard + deploy` jobs all pass cleanly. The
public site is unblocked.

## v0.4.7 (2026-06-01)

Backlog-clearing quality release. Lands all four v0.4.2-deferred
correctness bugs (issues
[#25](https://github.com/unicef-drp/cso-toolkit/issues/25),
[#26](https://github.com/unicef-drp/cso-toolkit/issues/26),
[#27](https://github.com/unicef-drp/cso-toolkit/issues/27),
[#28](https://github.com/unicef-drp/cso-toolkit/issues/28))
that had been carrying since v0.4.2 (2026-05-27), plus the two
queued v0.4.7 follow-up trackers
([#61](https://github.com/unicef-drp/cso-toolkit/issues/61),
[#63](https://github.com/unicef-drp/cso-toolkit/issues/63))
from PR #60 / PR #62 Copilot reviews. No public API breaks. Six
PRs (#75–#81) land into develop in this cycle; one deferred concern
(`dw_is_canonical` literal-regex robustness) is tracked separately
as [#82](https://github.com/unicef-drp/cso-toolkit/issues/82).

### `dw_save` mirror paths honour `.gz` suffix (issue [#25](https://github.com/unicef-drp/cso-toolkit/issues/25))

PR [#75](https://github.com/unicef-drp/cso-toolkit/pull/75).
`dw_save()` resolved the `.gz` suffix AFTER computing remote mirror
destinations via `.dw_remote_mirrors(path)`. When `compress = TRUE`
(or the path already ended in `.gz`), this caused two downstream
problems:

- Compressed bytes copied to mirror filenames WITHOUT the `.gz`
  extension (misleading filename relative to file contents).
- The overwrite check looked for the un-suffixed mirror name and
  missed any existing `.gz` mirror at the destination — overwrite
  protection silently bypassed.

Fix: move the `.gz` suffix block to BEFORE the mirrors computation
so every downstream reference to `path` / `teams_mirror` /
`z_mirror` carries the same final extension. Bug B from the
original #25 (the `mirror_to_z` keyword leaking through `dots`)
was already fixed in v0.4.0; this release closes Bug A.

New regression file `r/tests/testthat/test-dw_io-compress-mirror.R`
pins three cases — `compress = TRUE` mirror suffix, path-ends-in-
`.gz` mirror suffix, and the overwrite-check collision detection.

### `dw_save` no self-mirror when primary is canonical (issue [#26](https://github.com/unicef-drp/cso-toolkit/issues/26))

PR [#76](https://github.com/unicef-drp/cso-toolkit/pull/76).
Producer-mode `dw_save()` emitted a false `[cso_toolkit.dw_save]
Teams mirror FAILED` warning when the profile resolved `teamsWrkData`
(or any sibling local global) directly to `teamsFolderCanonical` —
the common bootstrap pattern. `.dw_remote_mirrors()` was returning
the primary path AS the Teams mirror destination, then
`.dw_mirror_to_teams(primary, primary)` ran a `file.copy()` onto
itself which on Windows triggers a tryCatch-trapped warning that
got re-emitted as the false-fail alarm. Nothing actually failed.

Fix: `.dw_remote_mirrors()` now returns `teams = NA_character_`
when the primary path is canonical. The Z: mirror behaviour is
unchanged (still derived from the canonical path).

### `dw_regions` renames `Aggregate` to caller's `value` (issue [#27](https://github.com/unicef-drp/cso-toolkit/issues/27))

PR [#77](https://github.com/unicef-drp/cso-toolkit/pull/77).
`aggregate_data_v2()` hard-codes its output value column as
`Aggregate`. `dw_regions()` renamed `REGION → REF_AREA` to make
regional rows shape-compatible with country-level rows, but never
renamed `Aggregate` back to the caller's `value` arg. Consequence:
`bind_rows(data, regional)` produced rows where country-level
rows had the value in the caller's value column and regional rows
had `NA` in that column (with the regional value stashed in a
parallel `Aggregate` column).

Fix: after the `REGION → REF_AREA` rename, also rename `Aggregate
→ value`. Guarded with an upstream check for value-arg collision
with `aggregate_data_v2`'s metadata column names (`Pop_Covered`,
`Country_Coverage`, etc.) so the conflict surfaces an envelope-
shaped error BEFORE the aggregator runs.

### `create_sector_script` DW wrapper paths + sentinel (issue [#28](https://github.com/unicef-drp/cso-toolkit/issues/28))

PR [#78](https://github.com/unicef-drp/cso-toolkit/pull/78). Two
bugs in the DW-Production wrapper inside `create_sector_script.R`:

- Wrong subpath defaults: hard-coded `c("01_dw_prep", "011_input")`
  / `c("01_dw_prep", "013_output")`, but the canonical DW layout
  uses `011_rawdata` / `013_wrkdata`. Generated sector scripts
  pointed at non-existent directories.
- Non-existent profile sentinel: generated scripts checked
  `if (!exists("profile_DW_Production") || is.null(...))`, but
  `profile_DW-Production.R` defines no global by that name.

Fix: both the generic `create_sector_script()` defaults AND the
`create_dw_sector_script()` wrapper now use `011_rawdata` /
`013_wrkdata`. Default `profile_name` switched from
`"profile_DW_Production"` to `"projectFolder"` (always set by the
profile). Roxygen + `r/man/*.Rd` files updated to match.

### `dw_is_canonical` regression coverage on canon_roots branch (issue [#61](https://github.com/unicef-drp/cso-toolkit/issues/61) — finding #61.2)

PR [#81](https://github.com/unicef-drp/cso-toolkit/pull/81). Pre-
v0.4.7 `test-dw-is-canonical.R` only exercised the OneDrive UNC
literal-regex branch (positive, both slash variants) and a generic
repo-local negative. A regression in the canon_roots loop (the
runtime-resolved `teams{Wrk,Raw,Folder}Canonical` globals) could
have shipped silently. Added six new test cases pinning the
canon_roots branch + the sibling-spoof negative + the
no-canonical-globals-set case.

Finding #61.1 (replace literal regex with a runtime-derived pattern)
is intentionally deferred — the v0.4.6 fix was empirically-driven
by the 2026-05-30 HVA + ED audit. Tracked at
[#82](https://github.com/unicef-drp/cso-toolkit/issues/82).
Finding #61.4 (pipeline phases 3-vs-4 columns) verified
self-consistent in current `render.R` and `dashboard/README.md`.

### Dashboard `dashboard.yml` paths-ignore (issue [#61](https://github.com/unicef-drp/cso-toolkit/issues/61) — finding #61.3)

PR [#80](https://github.com/unicef-drp/cso-toolkit/pull/80). Pre-
fix, the dashboard workflow's push trigger restricted refresh to
commits touching `docs/dashboard/**` or the workflow itself, but
the published payload also reflects top-level NEWS.md, README,
LICENSE, and operator snapshots elsewhere. Switched from narrow
`paths:` allow-list to `paths-ignore:` covering the three language-
package trees (`r/`, `python/`, `stata/`) that have their own
check workflows.

### Dashboard `collect.R` reachable + alias overmatch (issue [#63](https://github.com/unicef-drp/cso-toolkit/issues/63))

PR [#79](https://github.com/unicef-drp/cso-toolkit/pull/79). Two
Copilot findings from PR #62 review:

- `reachable = TRUE` was set unconditionally once the token was
  present. Captured each `gh_api()` return BEFORE `%||%` so we
  can distinguish "API failed" from "endpoint empty"; reachable is
  now true iff at least one of the four endpoints returned data.
- Sector aliases over-matched: `wt`'s `women` caught generic
  women's-health titles; `cme`'s `\bcm\b` caught `scm` and other
  bare "cm" tokens. Dropped both. Added a header comment about the
  first-hit precedence semantics.

## v0.4.6 (2026-05-30)

Quality release. Four issues land in one cycle — one HIGH-severity
canonical-recognition fix that would have allowed reviewer-mode
overwrites of canonical Teams artefacts, plus three cleanups
(re-exported `dw_root()` wrapper, uniform `.cso_require` envelope on
standalone-source `%>%` gate, and an `r/.gitattributes` pin so the R
subtree checks out with LF endings on Windows). No public API
breaks.

### `dw_is_canonical` recognises OneDrive-mounted Teams Documents path (issue [#54](https://github.com/unicef-drp/cso-toolkit/issues/54)) — **HIGH severity**

Pre-fix, `dw_is_canonical()` matched canonical paths against
`teamsFolderCanonical` and the Z: drive root only. On UNICEF laptops
where the Teams "Documents" library is mounted via OneDrive
(`C:/Users/<user>/UNICEF/<team> - Documents/...`), the canonical
prefix the helper saw at runtime did not match the literal path the
sector profile assembled when writing — so `dw_is_canonical()`
returned `FALSE` for paths that were, in fact, canonical Teams
deposits.

Combined with the v0.4.0 reviewer-mode write-refusal contract
(`dw_save` refuses canonical writes in reviewer mode unless
`allow_canonical_write = TRUE`), the false-negative meant a reviewer-
mode `dw_save()` call would have silently overwritten the canonical
Teams artefact instead of hard-stopping.

Surfaced empirically by the 2026-05-30 HVA + ED reviewer-mode
fanout runs (DW-Production): the canonical path through the
OneDrive-mounted Documents folder passed the
`!dw_is_canonical(path)` precondition and would have written to the
canonical artefact had the runs not been halted by the audit. The
fix extends `dw_is_canonical()` to also recognise the OneDrive-
mounted Documents form, so the canonical-write refusal contract
fires correctly on UNICEF-laptop reviewer sessions.

Tests in `r/tests/testthat/test-dw-is-canonical.R` extended to cover
the OneDrive-mounted form alongside the existing Z: and
`teamsFolderCanonical` cases.

### `dw_root()` public wrapper re-exported (issue [#53](https://github.com/unicef-drp/cso-toolkit/issues/53))

Several DW-Production sector scripts (carried forward from the v0.3
era) call `dw_root()` directly to derive the sector-folder anchor
for relative path resolution. `dw_root()` was never an exported entry
in the v0.4.x NAMESPACE — sector scripts that vendored v0.4.x copies
of the toolkit hit `Error: could not find function "dw_root"` the
first time they sourced the profile.

The internal helper is re-exported as a public wrapper in v0.4.6;
the existing implementation is unchanged. NAMESPACE gains an
`export(dw_root)` entry and `man/dw_root.Rd` is generated. The
helper joins `Other io:` in the family cross-references so it
surfaces in pkgdown alongside `dw_save`, `dw_use`, and friends.

### Uniform `.cso_require` envelope on `%>%` standalone-source gate (issue [#51](https://github.com/unicef-drp/cso-toolkit/issues/51))

v0.4.5's #46 fix added a local `%>%` binding gated by `exists()`. The
gate worked, but it raised a bare base-R error if `magrittr` itself
wasn't installed — without the `[cso_toolkit.<func>] WHAT / Why /
Fix` envelope the rest of the toolkit follows.

v0.4.6 wraps the local-binding fallback in `.cso_require("magrittr")`
so the envelope shape is uniform. Consumers who source the file
standalone without `magrittr` installed now see the same actionable
three-part message as every other toolkit raise.

### `r/.gitattributes` pins LF endings on the R subtree (issue [#52](https://github.com/unicef-drp/cso-toolkit/issues/52))

On Windows checkouts under default git `autocrlf` settings, R source
files in the package subtree (`*.R`, `*.Rd`, `NAMESPACE`,
`DESCRIPTION`, `*.yml`, `*.yaml`, `*.md`) were rewritten with CRLF
endings on checkout. That made local working-tree SHA-256 hashes
diverge from the LF-computed Git blob hashes — a recurring source
of spurious "drift" complaints from Windows consumers comparing
working-tree hashes against manifest entries computed on Linux.

A new `r/.gitattributes` pins LF endings on the R subtree's source
files so Windows checkouts of the package subtree are byte-identical
to Linux/macOS. This is scoped to `r/` — the rest of the repo
inherits the platform default. Per-file hash drift detection in
`cso_toolkit_check()` itself is **not** part of this release; today
the function only compares the pinned manifest version against the
upstream latest tag. The richer drift logic is planned for the
`cso_toolkit_diff()` / `cso_toolkit_pull()` work (stubbed in v0.4.6).

### Docs: third role renamed INGESTOR → PUBLISHER (DBM / DBR / DBP)

The third data-warehouse role is now **PUBLISHER** (was _INGESTOR_),
aligning the role label with the verb the code already uses
(`dw_publish()`; there is no `dw_ingest()`). **Docs-only** — no code,
no exported-API change, and no mode-contract value changed: the
contract still exposes `producer` / `reviewer`, and wiring a
`publisher` mode remains future scope (issue
[#15](https://github.com/unicef-drp/cso-toolkit/issues/15)). The role
acronyms are now spelled out across the docs — **DBM** = Database
Manager (PRODUCER), **DBR** = Database Reviewer (REVIEWER), **DBP** =
Database Publisher (PUBLISHER). Touches `docs/roles_and_workflow.md`,
`README.md`, `r/DESCRIPTION`, `templates/dbm_submission_template.md`,
`docs/git_workflow.md`, `docs/toolkit_strategy.md`.

## v0.4.5 (2026-05-29)

Closes the v0.4.5 milestone with two deliverables — standalone-source
`%>%` binding (issue [#46](https://github.com/unicef-drp/cso-toolkit/issues/46),
PR [#47](https://github.com/unicef-drp/cso-toolkit/pull/47)) and 8 new
`dw_`-prefixed aliases (issue [#42](https://github.com/unicef-drp/cso-toolkit/issues/42),
PR [#48](https://github.com/unicef-drp/cso-toolkit/pull/48)). A companion
declaration of `magrittr` as a first-class Import (with `importFrom`
in NAMESPACE) makes the dependency surface honest. No public API
breaks; both names remain exported throughout v0.4.x.

### Standalone-source `%>%` binding (issue [#46](https://github.com/unicef-drp/cso-toolkit/issues/46))

v0.4.4's #36 fix made `aggregate_data_v2.R` partially safe to source standalone by adding a local `.cso_require()` fallback. But the file still used the unqualified `%>%` operator without a binding — `.cso_require()` calls `requireNamespace()`, which loads but does NOT attach package exports, so `source("aggregate_data_v2.R")` errored at the first pipe call with `Error: could not find function "%>%"` even when magrittr was installed.

Same one-line gate pattern resolves it. Applied to both files that use `%>%` standalone:

```r
if (!exists("%>%", mode = "function", inherits = TRUE)) {
  `%>%` <- magrittr::`%>%`
}
```

In the installed-package context the local binding is a no-op (NAMESPACE's `importFrom(magrittr, "%>%")` wins). In standalone-source mode the local binding provides the same `%>%` symbol via `magrittr`'s namespace, so consumers don't have to `library(magrittr)` first.

To make this fully honest: `magrittr` is now declared in `DESCRIPTION::Imports` (previously it came in transitively via dplyr), and `zzz.R::.cso_require` carries an `@importFrom magrittr %>%` roxygen tag so `NAMESPACE` gains the explicit `importFrom(magrittr, "%>%")` entry. Both belong to the principled fix: the package's dependency declaration now matches the comments and the test claims about the installed-package no-op path.

Also corrected a misleading comment in `zzz.R::globalVariables` that referred to a non-existent `apply_time_window.R` file (`apply_time_window()` is defined inside `aggregate_data_v2.R`).

Surfaced empirically by Copilot review of DW-Production PR [#144](https://github.com/unicef-drp/DW-Production/pull/144) (WS v0.4.4 install) on 2026-05-29; Copilot review of cso-toolkit PR [#47](https://github.com/unicef-drp/cso-toolkit/pull/47) then flagged that the comment claims about NAMESPACE were aspirational, prompting the principled `magrittr` import declaration.

### `dw_`-prefixed canonical aliases for the remaining un-prefixed exports (issue [#42](https://github.com/unicef-drp/cso-toolkit/issues/42))

v0.4.4 added `dw_` aliases for `aggregate_data_v2` and `create_sector_script` (the two exports touched by #36). v0.4.5 extends the program to the remaining 8 un-prefixed exports so the toolkit's public surface consistently uses the `dw_` namespace:

| Un-prefixed | `dw_`-prefixed alias |
|---|---|
| `aggregate_data` | `dw_aggregate_data` |
| `generate_agg_footnote` | `dw_generate_agg_footnote` |
| `apply_time_window` | `dw_apply_time_window` |
| `generate_markdown_report` | `dw_generate_markdown_report` |
| `process_all_csv_files` | `dw_process_all_csv_files` |
| `create_profile` | `dw_create_profile` |
| `review_profile` | `dw_review_profile` |
| `test_scripts` | `dw_test_scripts` |

Both names continue to work and share the same `\link{}` man page via roxygen `@rdname`. **No breaking change**: consumers using the un-prefixed names see no behaviour change. The un-prefixed names remain exported and will continue to work indefinitely in v0.4.x; a future v0.5.x cycle may emit a `lifecycle::deprecate_soft()` warning on the un-prefixed forms to nudge migration, but only after sector leads confirm the migration is complete.

`create_dw_sector_script` was intentionally NOT aliased: it already carries a `dw` infix (it's a DW-Production-specific wrapper of `create_sector_script`), and `create_sector_script` got `dw_create_sector_script` in v0.4.4 anyway. The dual-naming is historical and won't be cleaned up under #42.

The `test_scripts` → `dw_test_scripts` alias also got a roxygen note: a future v0.5.x rename to `dw_audit_scripts` (to surface the audit intent and avoid the testthat-name collision) is on the design horizon. For now the prefix-only alias keeps the cleanup additive.

### Forward look

_v0.5.0 will land the live `dw_publish()` submission branch (issue
[#15](https://github.com/unicef-drp/cso-toolkit/issues/15)) and the
`dw_regions()` API redesign against the Country-and-Region-Metadata-API
package (issue [#40](https://github.com/unicef-drp/cso-toolkit/issues/40))
once sector leads finalise the Helix endpoint contract and the regions
API output schema._

## v0.4.4 (2026-05-29)

Quality release. Three v0.4.4 milestone issues land in one cycle (PRs
[#39](https://github.com/unicef-drp/cso-toolkit/pull/39),
[#41](https://github.com/unicef-drp/cso-toolkit/pull/41),
[#43](https://github.com/unicef-drp/cso-toolkit/pull/43)). All three
surfaced empirically during the DW-Production v0.4.3.1 fanout audit
(IM / WS / HVA install + reviewer-mode runs on 2026-05-28). No public
API breaks; the bumped-default behaviour stays backwards-compatible
for v0.4.3.1 consumers.

Follow-up issue [#42](https://github.com/unicef-drp/cso-toolkit/issues/42)
tracks the remaining un-prefixed exports for a single naming-cleanup
PR (proposed v0.4.5).

### Three carry-forward bugs + `dw_`-prefix aliases (issue [#36](https://github.com/unicef-drp/cso-toolkit/issues/36))

Closes two of the three sub-fixes flagged on #36 during the HVA
scaffold-install Copilot review on 2026-05-28. The third (a value-arg
propagation bug in `dw_regions.R`) is moot — `dw_regions` is being
redesigned to consume the new `unicef-drp/Country-and-Region-Metadata-API`
package in [#40](https://github.com/unicef-drp/cso-toolkit/issues/40) (v0.5.0); the affected code path is removed.

#### Sub-fix 1: `aggregate_data_v2.R` is now safe to source standalone

Pre-fix, `aggregate_data_v2.R` called `.cso_require()` from `zzz.R`.
Sourcing `aggregate_data_v2.R` directly (without sourcing `zzz.R`
first) left `.cso_require` undefined; the first call to
`aggregate_data_v2(...)` errored with `could not find function .cso_require`.

The file now defines a local fallback for `.cso_require()` at source
time, gated by `exists(".cso_require", mode = "function", inherits = TRUE)`.
When `zzz.R` has already been sourced into `.GlobalEnv`, the shared
helper wins and nothing is redefined; when only `aggregate_data_v2.R`
is sourced, the local fallback provides the same behaviour.

#### Sub-fix 2: `create_sector_script()` profile sentinel check relaxed (and aligned with `create_profile()`)

Pre-fix, the generated `00_run_<sector>.R` template checked
`isTRUE(profile_DW_Production)`. The DW-Production profile
(`profile_DW-Production.R`) does not set `profile_DW_Production`, so
the generated script errored at the sentinel check even after the
profile was sourced successfully.

The check is now relaxed from `isTRUE(<name>)` to `!is.null(<name>)`,
which accepts any non-null value — character paths, numeric values,
or the boolean sentinel that `create_profile("DW-Production")` emits
(`profile_DW_Production <- TRUE`). The default `profile_name` stays at
`"profile_DW_Production"` so the documented scaffold flow
(`create_profile()` → `create_dw_sector_script()`) works out of the
box without additional configuration.

The new error message names the missing variable so future
profile-vs-template mismatches surface a concrete fix. The roxygen
`@param` doc also clarifies that the generated template uses
`projectFolder` directly for input/output paths, so the profile MUST
set `projectFolder` for the runner to do useful work — the sentinel
check only confirms the profile was sourced.

For DW-Production consumers (whose existing `profile_DW-Production.R`
doesn't set the sentinel), the one-line `profile_DW_Production <- TRUE`
must be added to the profile. Tracked as a separate DW-Production-side
follow-up PR.

#### `dw_`-prefixed canonical aliases for the two touched exports

Toolkit-export naming consolidates around the `dw_` prefix in v0.4.x;
the non-prefixed names predate that convention. While in this PR's
files anyway, added:

- `dw_aggregate_data_v2` (alias for `aggregate_data_v2`)
- `dw_create_sector_script` (alias for `create_sector_script`)

Both names point to the same function and share the same `\\code{\\link{}}` man page (via roxygen `@rdname`). The non-prefixed names continue to work — no breaking change. Follow-up issue tracks the rest of the un-prefixed exports (`aggregate_data`, `generate_markdown_report`, `apply_time_window`, `generate_agg_footnote`, `create_profile`, `review_profile`, `test_scripts`, `create_dw_sector_script`) as a single cleanup PR.

### `dw_default_unicef_allowlist()` helper for consumers (issue [#37](https://github.com/unicef-drp/cso-toolkit/issues/37))

New exported helper returns a character vector of `^...`-anchored
regex patterns covering UNICEF DRP GitHub-raw and repository URLs.
Consumers seed `dw_url_allowlist` from this constant instead of
re-deriving the patterns per project:

```r
# In profile_<consumer>.R
dw_url_allowlist <- c(
  dw_default_unicef_allowlist(),
  # Project-specific extras:
  "^https://yourorg\\.github\\.io/"
)
```

Surfaced empirically by the DW-Production reviewer-mode audit on
2026-05-28 (IM `01_immunization.R`): every URL-using sector script
hand-wrote the same `^https://raw\\.githubusercontent\\.com/unicef-drp/`
pattern. The helper consolidates the duplication and lets future
UNICEF-DRP additions land in one place upstream rather than in each
consumer's profile.

Purely additive — consumers must opt in by composing the helper into
their `dw_url_allowlist`. The URL-freeze safety contract is unchanged
(no URL is fetchable without explicit ratification).

### `.dw_frozen_root()` resolution is now discoverable (issue [#38](https://github.com/unicef-drp/cso-toolkit/issues/38))

`.dw_frozen_root()` falls through a 3-tier resolution chain when
locating the URL-freeze cache root:

1. `dw_frozen_root` global (opt-in; preferred)
2. `<githubFolder>/_frozen` (fallback)
3. `<getwd()>/_frozen` (last-resort fallback)

Pre-v0.4.4 the helper resolved silently — consumers whose project
layout didn't match the fallback heuristic had to grep `dw_io.R` to
discover why `dw_use("https://...")` couldn't find their frozen file.

v0.4.4 adds two discoverability improvements:

- A new internal helper `.dw_frozen_root_resolved()` returns a
  `(path, source)` pair so downstream callers can surface the chosen
  tier in messages and error envelopes.
- `.dw_frozen_root_notify_once()` emits a session-scoped notice the
  first time the helper falls back beyond tier #1:
  `message()` for tier #2 (`<githubFolder>/_frozen`),
  `warning()` for tier #3 (`<getwd()>/_frozen`).
  Consumers that explicitly set `dw_frozen_root` get no notice.

The missing-frozen-copy error envelope in `.resolve_remote_url()`
now includes the resolution tier so consumers see which fallback
fired (or that the explicit global picked the path that's wrong):

```text
[cso_toolkit.dw_use:remote] Reviewer mode forbids fetching from the network.
 Missing frozen copy: <path>
 URL: <url>
 Frozen-root resolution: <chosen-root> (<tier-name>)
 Fix:
   1. If the path above is wrong, set `dw_frozen_root <- '<your-canonical-frozen-path>'` in your profile.
   2. Otherwise, a producer must call dw_use(...) once and commit the frozen file + sidecar.
```

Surfaced empirically by the DW-Production IM reviewer-mode audit on
2026-05-28: the fallback resolved to `<githubFolder>/_frozen` instead
of DW-Production's convention of `<projectFolder>/01_dw_prep/011_rawdata/_frozen/`.
Three runs (75+ min of slow Teams network) were needed to diagnose
what a single message could have surfaced at session start.

No public-API changes. The internal `.dw_frozen_root()` (path-only)
is preserved for backward compatibility with v0.4.3.1 callers.

## v0.4.3.1 (2026-05-28)

Patch release. v0.4.3 (cut earlier today) bumped `DESCRIPTION::Version`
and `NEWS.md` but missed three version stamps inside `r/R/dw_io.R`:

- header banner (`# Toolkit version: 0.4.2`)
- `dw_toolkit_version()` docstring (`Currently "0.4.2"`)
- `dw_toolkit_version()` return value (`"0.4.2"`)

Caught by Copilot review on DW-Production install PRs (#134 + #136):
`dw_toolkit_version()` was returning `"0.4.2"` while consumers had
`manifest::pulled_version = "v0.4.3"` — an inconsistency that would
have polluted `dw_publish()` provenance sidecars with the wrong
toolkit version. This patch bumps all three stamps to `0.4.3.1` so
they agree with `DESCRIPTION` and the manifest pin.

The release-cut checklist for the next minor (v0.5.0) should include
a `grep -rn '0\.[0-9]\.[0-9]' r/R/` step to catch any future stamp
drift before tagging.

No behavioural changes; safe to install as a drop-in replacement for
v0.4.3.

## v0.4.3 (2026-05-28)

Integrity release. Two `dw_use()` fixes (issues
[#30](https://github.com/unicef-drp/cso-toolkit/issues/30) +
[#31](https://github.com/unicef-drp/cso-toolkit/issues/31)) ported from
the DW-Production NT reviewer-mode reproducibility audit on 2026-05-27
(PR [#33](https://github.com/unicef-drp/cso-toolkit/pull/33); DW-Production
PR [#133](https://github.com/unicef-drp/DW-Production/pull/133)). Both
landed first on the DW-Production vendored copy as `local_edits`; this
release lets the next `cso_toolkit_pull(target_version = "v0.4.3")` drop
those local edits.

Issue [#32](https://github.com/unicef-drp/cso-toolkit/issues/32)
(provenance sidecars) is the design-foundation companion in the same
milestone; implementation ships in a follow-up PR.

### `dw_use()` — parquet / dta `col_select = NULL` conditional dispatch (issue [#30](https://github.com/unicef-drp/cso-toolkit/issues/30))

The v0.4.2 parquet branch unconditionally passed `col_select = cols`
to `arrow::read_parquet()`. When a caller invoked `dw_use(path)` without
explicit columns, `cols` defaulted to `NULL`, and
`arrow::read_parquet(path, col_select = NULL)` returned a zero-column
schema rather than all columns. The same pattern affected
`haven::read_dta(col_select = NULL)`. Both branches now use conditional
dispatch: pass `col_select` only when `cols` is non-NULL.

Surfaced empirically by DW-Production Run #6 (NT pipeline): 13+ stages
downstream of `1b_cmrs_series_import.R` failed with "object 'COLUMN'
not found" because the upstream `dw_use(out_dw_nut_*.parquet)` returned
an empty tibble. After the fix (Run #7): 24/25 stages OK.

### `dw_use(cols_lenient = FALSE)` — new flag for `any_of()`-style schema intersect (issue [#31](https://github.com/unicef-drp/cso-toolkit/issues/31))

Sector scripts that wanted "select these columns if present, ignore
the absent" semantics passed `dw_use(cols = dplyr::any_of(c(...)))`.
`any_of()` errors fatally outside a tidyselect selecting context
(tidyselect >= 1.2.0); R evaluates the helper before the call to
`dw_use`, so no lazy-eval trick inside the toolkit can save it.

New `cols_lenient = FALSE` parameter (default off for backwards compat).
When `TRUE`, dw_use introspects the file schema cheaply (parquet
metadata, csv / tsv / xlsx zero-row read, dta header) and intersects
the requested `cols` with the actual columns before the data read.
Empty intersection → warning + read all columns (forward-progress
guarantee). New internal helper `.dw_schema_cols(path, fmt)` performs
the schema-only read.

Migration:

- `dw_use(cols = dplyr::any_of(c(...)))` → `dw_use(cols = c(...), cols_lenient = TRUE)`
- `dw_use(cols = dplyr::all_of(c(...)))` → `dw_use(cols = c(...))` (strict; `all_of()` at top level is deprecated in tidyselect 1.2.0 anyway)

### Companion issue: provenance sidecars (issue [#32](https://github.com/unicef-drp/cso-toolkit/issues/32))

Issue #32 sketches the producer → reviewer → ingestor integrity chain
that `.write_remote_provenance` (v0.4.0, URL-freeze sidecars) is the
seed of. Foundational design captured; implementation deferred to a
follow-up PR within the v0.4.3 milestone.

## v0.4.2 (2026-05-27)

Patch release. Fixes a Copilot-flagged silent-CSV bug in v0.4.1's
new `dialect = "base"` dispatch on `dw_save()`. Surfaced by Copilot
review of DW-Production PR #128 (the v0.4.1 cleanup pull) before
any sector pipeline could write a corrupted `.tsv`.

### `dw_save(dialect = "base")` now honours the dispatched separator

v0.4.1 dispatched `dialect = "base"` through `utils::write.csv(x,
file = path)`, which hardcodes a comma separator. That meant
`dw_save(x, "out.tsv", dialect = "base")` silently produced
CSV-formatted content with a `.tsv` extension -- indistinguishable
from a real TSV at the filename level, but with wrong delimiters
inside.

v0.4.2 switches the dispatch to the equivalent underlying call:
`utils::write.table(x, file = path, sep = sep, col.names = NA,
qmethod = "double")`. `write.csv` is itself a wrapper around
`write.table` with those exact args plus an enforced `sep = ","`,
so:

- For `.csv` (sep = `,`) the byte output is **identical** to
  `utils::write.csv(x, file = path)`. The byte-parity guarantee
  v0.4.1 introduced for legacy callers (e.g. DW-Production NT
  `2[bcfg]_agg_*` scripts) is preserved.
- For `.tsv` / `.txt` (sep = `\t`) the file now contains actual
  **tab** separators with the same `row.names` / quoted-string
  defaults.

### Test coverage

New regression test file `r/tests/testthat/test-dw_io-dialect.R`
exercises four cases:

- `dialect = "base"` on `.csv` produces byte-identical output to
  `utils::write.csv()`.
- `dialect = "base"` on `.tsv` produces tab-separated output (the
  v0.4.2 fix).
- `dialect = "base"` with `compress = TRUE` raises the envelope-
  shaped error explaining the gzip-is-fwrite-only constraint.
- An unrecognised `dialect` value raises a base R error from
  `match.arg(dialect)` (which fires before the toolkit envelope
  wrapping kicks in -- `match.arg` is the cheap validation gate
  by design).

Existing version-stamp assertions in `test-dw_io-mode-contract.R`
and `test-dw_publish.R` updated from `"0.4.1"` to `"0.4.2"`.

### No public-API change

`dw_save()`'s signature is unchanged. Callers using `dialect =
"base"` on `.csv` see no behavioural difference. Callers passing
`.tsv` / `.txt` with `dialect = "base"` get correct tab output
instead of silent comma output (which was the bug).

## v0.4.1 (2026-05-27)

Two regressions in v0.4.0 surfaced by Copilot review of the
DW-Production pull ([DW-Production#127](https://github.com/unicef-drp/DW-Production/pull/127)).
Patches validated on the NT branch in DW-Production before backport;
see DW-Production `tests/test_v041_nt.R` for the focused harness
(tests 1-4 all PASS against this v0.4.1 head).

### `dw_save(..., dialect = ...)` parameter restored (BACKWARD COMPAT)

v0.4.0 silently dropped the `dialect` parameter that v0.3.x exposed
for byte-parity with `utils::write.csv()`. DW-Production NT scripts
(`nt/2b_agg_iod.R`, `nt/2c_agg_vas_series.R`, `nt/2f_agg_bw.R`,
`nt/2g_agg_iycf.R`) depend on `dialect = "base"` for legacy CSV byte
parity. Under v0.4.0 those calls silently lost byte parity (the arg
was forwarded via `...` into `data.table::fwrite` which doesn't
accept it).

v0.4.1 restores `dialect` as an explicit parameter on `dw_save()`:

- `dialect = "fwrite"` (default) — `data.table::fwrite` path
  (existing behaviour; row.names = FALSE, fast)
- `dialect = "base"` — `utils::write.csv(x, file = path)` (preserves
  row.names = TRUE + default-quoted strings; byte-parity with
  legacy `write.csv()`)
- `dialect = "base"` with `compress = TRUE` raises an explanatory
  error (gzip is fwrite-only).

Plumbed through CSV/TSV/TXT dispatch lines in `dw_save()` body.

### `dw_save(..., overwrite = NULL)` -- mode-aware default (DESIGN ALIGNMENT)

v0.4.0 shipped `overwrite = FALSE` uniformly across both modes
(strict). The mode-contract design discussion in issue
[#14](https://github.com/unicef-drp/cso-toolkit/issues/14) preferred
**lenient** for reviewer mode: producer-mode keeps explicit-required;
reviewer-mode keeps default-TRUE for scratch writes under
`013_wrkdata/_local/` (already gitignored; safe to re-run).

v0.4.1 changes `dw_save()` signature: `overwrite = FALSE` ->
`overwrite = NULL` (sentinel). After mode detection, the sentinel
resolves to:

- reviewer mode -> `TRUE`  (scratch is safe to re-run)
- producer mode -> `FALSE` (must be explicit)
- mode unset    -> `FALSE` (safe default; matches v0.4.0 strict)

Explicit `overwrite = TRUE` / `overwrite = FALSE` overrides the
sentinel as before.

### Migration

- **Reviewer-mode pipelines**: no action required. Default behaviour
  reverts to the pre-v0.4.0 lenient overwrite-on-re-run for scratch
  paths.
- **Producer-mode pipelines**: no change from v0.4.0 — still must
  pass `overwrite = TRUE` explicitly to re-run against existing
  artifacts.
- **Sector scripts using `dialect = "base"`**: no action; the
  argument now works again with the documented v0.3.x semantics.

### Other Copilot findings (deferred to v0.4.2)

Four canonical-side bugs surfaced by the same review but deferred
because they have zero blast radius on current DW-Production
pipelines (no sector currently calls `dw_regions()` / `dw_publish()`
/ `dw_pop()`):

- `dw_save` flow ordering: mirror destinations + `mirror_to_z` dots
  leak (issues to be filed).
- `dw_save` producer self-mirror when `teamsWrkData ==
  teamsFolderCanonical`.
- `dw_regions()` does not rename `Aggregate` -> `value` on regional
  rows.
- `create_sector_script` DW wrapper: wrong default paths + missing
  profile sentinel.

## v0.4.0 (2026-05-26)

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
  of analytics developed by the UNICEF Chief Statistician Office (CSO),
  within the Office of Strategy and Evidence (OSE). Citation block
  updated to match.
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
