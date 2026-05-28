# `dw_io.R` — uniform file IO reference

Detailed per-function reference for the IO helpers shipped in
[`r/R/dw_io.R`](../r/R/dw_io.R). Companion overview lives in the top-level
[README](../README.md); the producer / reviewer mode contract these helpers
enforce is documented in
[`mode_contract_integration.md`](mode_contract_integration.md).

## `dw_save(x, ...)`

Save an object to disk. Auto-dispatches on the file extension. Two call
styles:

```r
# Path-style — used when you already have the absolute path
dw_save(df, path = file.path(teamsWrkData, "ed/dw_ed_edu.csv"))

# Structured — auto-resolves via session-mode path globals
dw_save(df, name = "dw_ed_edu.csv", sector = "ed", kind = "wrk")
```

**Supported extensions** (CSV / TSV / TXT, XLSX single + multi-sheet, RDS,
RData, DTA, Parquet, JSON, YAML); auto-compresses CSVs when `compress = TRUE`
(writes `.csv.gz`).

**Quality contract.** Pass `isid = c(...)` for Stata-style uniqueness
assertion before writing. If any duplicate rows exist on the declared keys,
the call stops with the count and the first 5 dupes printed:

```r
dw_save(df, name = "dw_ed_edu.csv", sector = "ed", kind = "wrk",
        isid = c("DATAFLOW","REF_AREA","INDICATOR","SEX",
                 "WEALTH_QUINTILE","RESIDENCE","TIME_PERIOD"))
```

**Mode contract (v0.4.0 tightening).**

- **Reviewer mode.** Writes that resolve under canonical paths
  (`teamsWrkDataCanonical`, `teamsRawDataCanonical`) OR under the
  configured `dwZDrive` root **stop** with the provenance-contract
  envelope. The Z: branch is new in v0.4.0; v0.3.0 only refused canonical
  writes. Pass `allow_canonical_write = TRUE` for deliberate Database
  Manager bootstraps (e.g., depositing a one-time cache into 060 from a
  reviewer-mode session).
- **Producer mode.** Every primary write fans out redundantly to BOTH the
  Teams canonical equivalent AND the Z: drive equivalent (whichever are
  available). The helper **hard-stops** if neither mirror is configured —
  producer outputs cannot live only on the producer's laptop.
- **Overwrite gate (breaking change).** `overwrite` now defaults to
  `FALSE` (was `TRUE` in v0.3.0). The check examines all three
  destinations (primary, Teams mirror, Z: mirror); the helper refuses if
  any of them already exists. Pass `overwrite = TRUE` to restore v0.3.0
  behaviour.

**Mirror behaviour.** v0.4.0 replaces the v0.3.0 `mirror_to_z` argument
with automatic, paired mirroring. Each successful primary write:

1. Writes the primary file (atomic rename from `.tmp`).
2. Emits the `.provenance.json` sidecar next to the primary.
3. Copies primary + sidecar to the Teams canonical equivalent (skipped
   when primary already lies under canonical).
4. Copies primary + sidecar to the Z: drive equivalent (skipped when
   `dw_z_available = FALSE`).

Steps 3 and 4 are non-blocking — they emit envelope-shaped warnings on
failure rather than rolling back the primary write.

**Provenance sidecar.** Every write emits `<path>.provenance.json` with
`written_at`, `user`, `dw_mode`, `sha256`, schema (rows/cols/columns), and
any user-supplied `metadata = list(...)`:

```r
dw_save(df, name = "dw_ed_edu.csv", sector = "ed", kind = "wrk",
        metadata = list(
          title    = "Education indicators — UNICEF DW format",
          producer = "01_dw_prep/012_codes/ed/02_aggregate_uis_sdg.R",
          sources  = c("UIS bulk SDG_092025", "WPP 2024"),
          contact  = "@karavan88",
          vintage  = "2026-05"
        ))
```

## `dw_use(...)`

Read a file. Same path resolution as `dw_save`. Auto-dispatches on extension.
Returns a tibble by default; pass `as = "data.frame"` or `as = "data.table"`
to change.

```r
edu <- dw_use(name = "dw_ed_edu.csv", sector = "ed", kind = "wrk")
edu <- dw_use(path = "C:/path/to/file.parquet", cols = c("REF_AREA","OBS_VALUE"))
```

### Column subset — strict (default) and lenient (`v0.4.3+`)

`dw_use()` accepts an optional `cols = c("a", "b", "c")` to restrict the read.
Default behaviour is **strict**: each requested column must exist in the
file's schema, otherwise the underlying reader errors. This matches the
contract of `data.table::fread(select = ...)`,
`arrow::read_parquet(col_select = ...)`, and
`haven::read_dta(col_select = ...)`.

`v0.4.3+` adds a `cols_lenient = FALSE` flag that flips the contract to
the `dplyr::any_of()` "select if present" intent — but does it inside
`dw_use()`, so the caller does NOT have to invoke tidyselect helpers at
the top level (which errors fatally under tidyselect ≥ 1.2.0):

```r
# Strict (default): errors if "MAYBE_PRESENT_COL" is missing from the schema
df <- dw_use(path = parquet_path, cols = c("REF_AREA", "OBS_VALUE", "MAYBE_PRESENT_COL"))

# Lenient: intersect with the file's actual schema; missing cols are
# silently dropped, empty intersection -> warning + read all columns
df <- dw_use(path = parquet_path,
             cols = c("REF_AREA", "OBS_VALUE", "MAYBE_PRESENT_COL"),
             cols_lenient = TRUE)
```

When `cols_lenient = TRUE`, `dw_use` introspects the file schema cheaply
(metadata-only) before the read:

- **parquet** → `arrow::open_dataset(path)$schema$names`
- **csv / tsv / txt** → `data.table::fread(path, nrows = 0)` header read
- **dta** → `haven::read_dta(path, n_max = 0)` header read
- **xlsx** → `readxl::read_xlsx(path, n_max = 0)` header read

If schema introspection fails (corrupt header etc.) it emits a warning and
passes `cols` through unchanged.

**`col_select = NULL` discipline (`v0.4.3+` fix).** Pre-`v0.4.3`,
`dw_use(parquet_path)` with no `cols` argument unconditionally passed
`col_select = NULL` to `arrow::read_parquet()`. Arrow interpreted that as
"select zero columns" rather than "select all", returning a zero-column
tibble; the dta branch via haven exhibited the analogous behaviour.
`v0.4.3` patches both branches with conditional dispatch — `col_select`
is only passed when `cols` is non-NULL. The user-facing effect:
`dw_use(path)` (without cols) now reliably returns all columns regardless
of the file format.

**Migration for sector scripts** (from the DW-Production NT audit
2026-05-27):

```r
# Before (any_of at top level errors under tidyselect >= 1.2.0):
df <- dw_use(parquet_path, cols = dplyr::any_of(c("a", "b", "c")))

# After:
df <- dw_use(parquet_path, cols = c("a", "b", "c"), cols_lenient = TRUE)

# Before (all_of at top level is deprecated and warns):
df <- dw_use(parquet_path, cols = dplyr::all_of(c("a", "b", "c")))

# After (bare character vector keeps strict semantics):
df <- dw_use(parquet_path, cols = c("a", "b", "c"))
```

**Z: integrity check.** When reading a canonical file in producer mode, the
helper compares Teams ↔ Z: by file size by default. Mismatch emits a
warning; the read still completes. Use `verify_z = "sha256"` for a deep
check; `verify_z = FALSE` to skip.

**Resolution order (v0.4.0).** Reviewer and producer sessions resolve
differently to enforce provenance:

- **Producer / unknown mode** (v0.3.0 preserved). Local-first: try the
  literal path; if missing and `fallback_canonical = TRUE`, walk the
  `teams*Data -> teams*DataCanonical` prefix map and use canonical when
  available.
- **Reviewer mode** (network-first; new in v0.4.0). Tries the Teams
  canonical equivalent first, then the Z: drive mirror, then falls back
  to the repo-local copy with an envelope-shaped `warning()` flagging the
  provenance gap. If the file is missing in all three locations, the
  helper raises an envelope-shaped error pointing the reviewer to the
  sector producer. Disable the local fallback with
  `fallback_canonical = FALSE`.

## `dw_toolkit_version()`

Return the toolkit semver as a single string. Use it to stamp logs or
to assert minimum-version requirements in consumer profiles:

```r
stopifnot(utils::compareVersion(dw_toolkit_version(), "0.4.0") >= 0)
```

## `dw_compare(current, reference, by, value_cols, ...)`

Generalised compare-vs-canonical. Normalises missingness, joins on `by`,
classifies each value column as identical / numerically-equivalent (within
`tol`) / differs. Returns a list: `summary`, `added`, `removed`, `changed`.
Optionally writes per-segment CSV reports.

```r
report <- dw_compare(
  current   = dw_use(name = "dw_ed_edu.csv", sector = "ed", kind = "wrk"),
  reference = dw_use(path = file.path(teamsWrkDataCanonical, "ed/dw_ed_edu.csv")),
  by         = c("DATAFLOW","REF_AREA","INDICATOR","SEX",
                 "WEALTH_QUINTILE","TIME_PERIOD"),
  value_cols = c("OBS_VALUE", "DATA_SOURCE"),
  numeric_value_cols = "OBS_VALUE",
  tol        = 1e-5,
  label      = "ed_dw_edu",
  write_report_to = file.path(tempdir(), "ed_compare")
)
report$summary   # row counts and diff classification
```

## `dw_merge(x, using, by, how)`

Stata-style merge with cardinality assertion. `how ∈ {"m:1","1:1","1:m","m:m"}`.
Warns if `x` or `y` duplication doesn't match the declared cardinality.
The `using` side can be a path string (auto-read via `dw_use`) or a data
frame already in memory.

```r
enriched <- dw_merge(
  edu_sdg_uis,
  using = file.path(teamsRawData, "ed/metadata/regions.csv"),
  by    = "ISO3",
  how   = "m:1"
)
```

## `dw_isid(df, keys)` and `dw_verify_z(path)`

Lower-level helpers exposed for standalone use. `dw_isid` is the uniqueness
check invoked automatically by `dw_save(..., isid = ...)`. `dw_verify_z` is
the integrity check invoked automatically by `dw_use` on canonical reads.
