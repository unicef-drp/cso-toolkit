# DW-Production ↔ cso-toolkit alignment audit (2026-05-25)

Comparison of `C:\GitHub\mytasks\DW-Production\00_functions\` against
`c:\GitHub\myados\cso-toolkit\r\R\` at toolkit head **v0.3.0**.

## TL;DR

DW-Production has **substantive undeclared local edits** on top of the
toolkit's `v0.1.0-rc1` baseline (the version pinned in its
`.toolkit_manifest.yml`).  Despite the manifest saying
`local_edits: []`, four real changes need to flow **into** the toolkit:

1. **`dw_io.R`** — entire **remote-URL freeze** pattern
   (`dw_use("https://...")` with allowlist + one-time download + frozen
   sidecar + reviewer-mode lockout).  ~70 lines.  **Net-new feature.**
2. **`dw_io.R`** — gzip-extension auto-detection on
   `dw_save(compress = ...)`.  ~5 lines.  **Quality-of-life fix.**
3. **`dw_io.R`** — `tryCatch` around the `.provenance.json` write so
   sidecar failure only warns, never fails the primary write.  ~13 lines.
   **Robustness fix.**
4. **`dw_api.R`** — URL-encoded UIS query params + correct default
   extension (`rds`) for `http` and `github_raw` APIs (was silently
   broken for text/binary payloads).  ~8 lines.  **Bug fix.**

Conversely, the toolkit has accumulated three releases of work
(`v0.1.0-rc1 → v0.2.0 → v0.3.0`) that DW-Production must pull in
order to stay current.  Five toolkit-only helpers (`dw_nestweight.R`,
`profile_helpers.R`, `test_scripts.R`, `zzz.R`, and the
`create_dw_sector_script()` wrapper) didn't exist when DW-Production
last pulled.

## Manifest reality check

`DW-Production/00_functions/.toolkit_manifest.yml`:

```yaml
pulled_version: "v0.1.0-rc1"     # ← two releases behind (current: v0.3.0)
pulled_at:      "2026-05-24"
local_edits:    []               # ← actually FOUR substantive local edits
```

The empty `local_edits:` list is incorrect — `cso_toolkit_pull("v0.3.0")`
would silently overwrite real work.  This audit's first
recommendation is to populate the list before any pull.

## File-by-file diff matrix

Legend: **→ toolkit-side ahead** (DW needs to update);
**← DW-side ahead** (toolkit needs to backport);
**↔ both directions** (split work).

| File | Vendored direction | Lines DW / toolkit | Diff direction | What it means |
|------|---------------------|---------------------|----------------|---------------|
| `dw_io.R` | toolkit → DW | 779 / 1104 | ↔ | Toolkit added Roxygen + envelope; DW added remote-URL freeze + 2 fixes |
| `dw_api.R` | toolkit → DW | 418 / 628 | ↔ | Toolkit added Roxygen + envelope; DW added URL-encoding + http/github_raw ext fix |
| `cso_toolkit_sync.R` | toolkit → DW | 184 / 284 | → | Toolkit added Roxygen + envelope; DW unchanged |
| `aggregate_data.R` | DW → toolkit | 99 / 110 | → | Toolkit fixed a multi-column "World" assignment bug |
| `aggregate_data_v2.R` | DW → toolkit | 240 / 291 | ↔ | Toolkit removed top-level `library()` calls; DW kept the `aggregate_data()` back-compat wrapper |
| `create_sector_script.R` | DW → toolkit | 121 / 220 | → | Toolkit GENERALIZED the function (parameters), added `create_dw_sector_script()` wrapper for back-compat |
| `generate_markdown_report.R` | DW → toolkit | 213 / 288 | → | Toolkit namespace-qualified all calls, renamed misleading `N_Unique` → `N` |

## Inbound backport candidates (DW → toolkit)

### B1. Remote-URL freeze in `dw_io.R` 🟢 NEW FEATURE

DW-Production added a complete pattern for treating `dw_use(url)` as a
first-class call site, freezing the response on first download so the
reviewer can re-run deterministically:

```r
# Already shipped in DW-Production, ABSENT from cso-toolkit:
.dw_url_allowlist     # currently: raw.githubusercontent.com/unicef-drp/*
.is_allowlisted_url() # gate against arbitrary URLs
.dw_frozen_root()     # resolves to githubFolder/.../011_rawdata/_frozen
.url_to_frozen_path()
.write_remote_provenance()   # frozen-file sha256 + url + fetched_at
.download_and_freeze()
.resolve_remote_url()        # main entry; reviewer-mode lockout when not frozen
```

`dw_use("https://raw.githubusercontent.com/unicef-drp/...")` now:

- in **producer mode**: downloads if not already frozen, writes
  `<frozen>.provenance.json`, returns the local frozen path;
- in **reviewer mode**: refuses with a 4-line "commit the frozen file
  first" error if the frozen copy isn't already on disk.

**Recommendation:** lift verbatim into `cso-toolkit/r/R/dw_io.R`
behind a new entry point (e.g. `dw_use_remote(url)`) plus the
`dw_use("https://...")` dispatch.  The allowlist should become
configurable via `_state` / globals rather than hard-coded to UNICEF,
so external consumers can use this without forking.

**Effort:** ~1 day.  Mostly verbatim port + add Python sibling +
docs + Roxygen.

### B2. Gzip auto-detect in `dw_save` 🟡 QoL FIX

DW-Production:

```r
path_ends_in_gz <- grepl("\\.gz$", path, ignore.case = TRUE)
if (isTRUE(compress) && fmt %in% c("csv", "tsv", "txt") && !path_ends_in_gz) {
  # append .gz
} else if (!isTRUE(compress) && path_ends_in_gz) {
  compress <- TRUE   # auto-enable when path already says .gz
}
```

Toolkit currently only handles the first half (append `.gz` when
`compress=TRUE`); doesn't auto-enable gzip when path *already* ends in
`.gz`.  Small but useful — eliminates one foot-gun.

**Effort:** ~10 min.  3-line patch + 1 test.

### B3. `.provenance.json` write wrapped in `tryCatch` 🟡 ROBUSTNESS

DW-Production wraps the sidecar write so a non-JSON-serialisable
metadata value (rare but possible: e.g. a `Date` class from some
upstream package) emits a warning, **doesn't** fail the primary
`dw_save`:

```r
tryCatch(
  jsonlite::write_json(prov, ...),
  error = function(e) {
    warning(sprintf("[dw_save] provenance sidecar write failed ..."), call. = FALSE)
  }
)
```

Toolkit version lets the error propagate and roll back the whole
write.  DW-Production's behaviour is closer to "primary write is
sacred; sidecar is best-effort".

**Recommendation:** adopt DW-Production's tryCatch.  Sidecars are
metadata, not the asset; never lose data over a missing sidecar.

**Effort:** ~10 min.  Drop-in replacement.

### B4. `dw_api.R` URL-encoding + http/github_raw default ext 🔴 BUG FIX

Two real bugs DW-Production already fixed:

- **URL-encode UIS query params** —  toolkit currently does:
  ```r
  qs <- paste(names(params), unlist(params), sep = "=", collapse = "&")
  ```
  No URL encoding; any param value containing `&` / `=` / spaces /
  non-ASCII breaks the query.  DW-Production fix:
  ```r
  qs <- paste(
    utils::URLencode(names(params), reserved = TRUE),
    vapply(unlist(params), utils::URLencode, character(1), reserved = TRUE),
    sep = "=", collapse = "&"
  )
  ```

- **Default cache extension for `http` / `github_raw` should be `rds`,
  not `csv`** — text/binary responses don't round-trip through CSV.
  DW-Production already sets `rds` for both; toolkit still defaults
  to `csv` for `http` and dispatches via per-extension parsing in
  `github_raw`, which can silently corrupt non-CSV payloads.

**Effort:** ~30 min.  Includes Python parity + a regression test
for each.

## Outbound (toolkit → DW-Production)

DW-Production needs to pull v0.3.0 to gain:

| What | Why it matters |
|------|----------------|
| Roxygen-complete reference (NAMESPACE + 26 Rd files + pkgdown config) | `?dw_save` etc. now resolves to a man page; pkgdown site builds |
| Graceful three-part error envelope `[cso_toolkit.<func>] WHAT/Why/Fix` | Every `stop()` / `warning()` is grep-friendly and actionable |
| `dw_nestweight.R` | Survey-weight redistribution (ported from EduAnalyticsToolkit), unblocks MAR-within-strata workflows |
| `profile_helpers.R` (`create_profile`, `review_profile`) | Auto-scaffold a `profile_<repo>.R` and audit it against the toolkit contract |
| `test_scripts.R` | CI-mode auditor that flags raw `read_csv` / `httr::GET` / `rsdmx::readSDMX` etc. in sector code |
| `create_dw_sector_script()` wrapper | Drop-in for the existing hardcoded `create_sector_script()` call site in DW-Production |
| `aggregate_data.R` multi-column global-row fix | The `World` label currently lands only on the first `by` column in DW-Production; toolkit's loop fixes it |
| `generate_markdown_report.R` namespace qualification + `N_Unique → N` rename | Toolkit version no longer attaches `dplyr` at source-time |
| Python siblings of every helper | Sector pipelines that use Python (CCRI, geospatial) get the same contract |

## Cross-direction (split work)

`aggregate_data_v2.R` is the only file where both sides have made
deliberate, divergent choices:

- **DW-Production kept** the `aggregate_data()` back-compat wrapper
  inside `aggregate_data_v2.R` that delegates v1 calls to v2 with
  `validate=FALSE, global_label="World"`.  Useful for existing
  sector code that calls the v1 signature but wants the v2 logic.
- **Toolkit removed** the wrapper (with a comment explaining the
  source-order fragility risk if `aggregate_data.R` is sourced
  after `aggregate_data_v2.R`).

**Recommendation:** leave both behaviours documented.  Add a new
exported function `aggregate_data_v2_v1signature()` (or
`aggregate_data_legacy_via_v2()`) to the toolkit that does what
DW-Production's wrapper does, but with an explicit name so source
order doesn't matter.  Document the source-order caveat in the
function's Roxygen.

## Recommended workflow

A staged plan, smallest reversible step first.

### Stage 1 — fix the manifest (30 min, no code)

Update `DW-Production/00_functions/.toolkit_manifest.yml`:

```yaml
local_edits:
  - dw_io.R          # remote-URL freeze, gzip auto-detect, tryCatch sidecar
  - dw_api.R         # URLencode UIS params, rds default for http/github_raw
```

This unblocks `cso_toolkit_pull()` — without it, the next pull would
silently clobber the four local edits.

### Stage 2 — backport DW edits into toolkit (1 PR, ~1.5 days)

Open a single PR on `cso-toolkit` titled
`feat: adopt DW-Production-side improvements (remote-URL freeze + 4 fixes)`:

- B1: remote-URL freeze in `dw_io.R` + `dw_io.py` parity + tests + docs
- B2: gzip auto-detect in `dw_save` (R + Python)
- B3: `tryCatch` around `.provenance.json` (R + Python)
- B4: URL-encoded UIS params + `http`/`github_raw` rds default (R + Python)
- NEWS.md: list under `## Unreleased`
- Tag the next minor release as `v0.4.0`

### Stage 3 — DW-Production pulls v0.4.0 (1 PR on DW side, ~1 hour)

Run `cso_toolkit_pull("v0.4.0")` in DW-Production:

- `dw_io.R`, `dw_api.R`, `cso_toolkit_sync.R` refreshed to v0.4.0.
- Vendor `dw_nestweight.R`, `profile_helpers.R`, `test_scripts.R`,
  `zzz.R` (currently absent from DW-Production).
- Switch the existing DW-Production `create_sector_script()` call sites
  to `create_dw_sector_script()` (it preserves the hardcoded layout).
- Run `r/tests/manual/check_consumer_side.R`-equivalent smoke test
  inside DW-Production.

### Stage 4 — adopt new toolkit helpers in DW-Production (incremental)

Once v0.4.0 is in DW-Production:

- Wire `test_scripts(error_on_violation = TRUE)` into DW-Production CI
  so any future regression to raw `read_csv` / `httr::GET` etc. fails
  the build.
- Use `review_profile("profile_DW-Production.R")` to check the
  existing profile against the toolkit contract; address any
  `fail` / `warn` rows.
- Adopt `dw_nestweight()` for the MICS-FLS / DHS pipelines that
  currently work around the missing-not-at-random pattern by hand.

## Open questions for the maintainer

1. **Remote-URL freeze allowlist** — is `raw.githubusercontent.com/unicef-drp/*`
   the right default for the toolkit, or should the toolkit ship a
   strictly-empty allowlist that consumers populate via `_state`?
2. **`aggregate_data_v2` back-compat wrapper** — keep the source-order
   caveat in the toolkit, or land DW-Production's wrapper under a
   different name?
3. **Tag cadence** — should the four backports go out as `v0.3.1`
   (patch) or `v0.4.0` (minor)?  The remote-URL freeze is a new
   feature, which argues for minor; the other three are fixes.
   Recommend `v0.4.0`.

## Appendix — toolkit-only files DW-Production does not have

| File | Purpose | Effort to vendor |
|------|---------|------------------|
| `r/R/dw_nestweight.R` | Survey-weight redistribution (MAR within strata) | Drop-in |
| `r/R/profile_helpers.R` | `create_profile`, `review_profile` | Drop-in |
| `r/R/test_scripts.R` | Contract auditor for raw IO / HTTP calls | Drop-in + CI wiring |
| `r/R/zzz.R` | Single shared `.cso_require()` + `globalVariables` | Drop-in |
| `python/src/*` | Python parity (10 modules) | Vendor under `00_functions/cso_toolkit/` |

## Provenance of this audit

- Source: cso-toolkit branch `chore/compare-dw-production-2026-05-25`,
  comparing against
  `C:\GitHub\mytasks\DW-Production\00_functions\` (working copy).
- Method: file-by-file diff vs cso-toolkit `r/R/` at HEAD (post-v0.3.0)
  AND vs cso-toolkit `r/R/` at tag `v0.1.0-rc1` (the DW-Production-
  pinned vintage), with comments + blank lines stripped to surface
  substantive logic only.
- Date: 2026-05-25.
