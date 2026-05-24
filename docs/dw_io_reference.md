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

**Mode contract.** In reviewer mode, writes that resolve under canonical
paths (`teamsWrkDataCanonical`, `teamsRawDataCanonical`) **stop** with a
provenance-contract message. Pass `allow_canonical_write = TRUE` for
deliberate Database Manager bootstraps (e.g., depositing a one-time cache
into 060 from a reviewer-mode session).

**Z: mirror.** In producer mode, every canonical write is carbon-copied to
the Z: equivalent path. Z: absence is non-blocking; the mirror is skipped
silently with the single red banner at profile load.

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

**Z: integrity check.** When reading a canonical file in producer mode, the
helper compares Teams ↔ Z: by file size by default. Mismatch emits a
warning; the read still completes. Use `verify_z = "sha256"` for a deep
check; `verify_z = FALSE` to skip.

**Fallback to canonical.** If the resolved path doesn't exist (typical in
reviewer mode if the sandbox hasn't been populated), the helper retries under
the canonical equivalent. Disable with `fallback_canonical = FALSE`.

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
