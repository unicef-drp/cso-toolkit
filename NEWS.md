# NEWS — cso-toolkit

## Unreleased

_Entries land here as PRs merge into `develop`. When the next release
is cut, this header is renamed `## v0.4.4 (YYYY-MM-DD)` and a fresh
`## Unreleased` section is added back._

_v0.5.0 will land the live `dw_publish()` submission branch (issue
[#15](https://github.com/unicef-drp/cso-toolkit/issues/15)) once
sector leads finalise the Helix endpoint contract._

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
