# stata/src/ — Stata helpers

Six Stata helpers covering the full IO + mode-contract surface as of
v0.4.0; they mirror the R API contract from [`r/R/`](../../r/R/) so a
sector that runs partly in Stata and partly in R uses the same producer
/ reviewer contract on both sides.

## What's here

### IO helpers (v0.2.0)

- [`dw_save.ado`](dw_save.ado) — uniform Stata `save` wrapper. Validates
  the target directory, enforces row uniqueness on declared id vars via
  `isid`, compresses, saves, and writes a sibling **`.provenance.json`**
  sidecar with the same shape the R `dw_save()` helper emits. Honours
  the producer / reviewer mode contract via `$dw_mode`; canonical writes
  in reviewer mode are BLOCKED unless `allow_canonical_write` is passed.
  Content integrity uses Stata-native `datasignature` rather than a
  file-level SHA-256 (so no shell-out, no AppLocker issues).
  Companion help: [`dw_save.sthlp`](dw_save.sthlp).
- [`dw_compare.ado`](dw_compare.ado) — `dw_compare(current, reference,
  idvars, valuevars, tol, report, label)`. Merges two `.dta` files on
  the declared id key and classifies each value column as identical,
  numerically-equivalent (within `tol()`), or different. Reports
  `added` / `removed` / `common` / `changed cells` counts plus a
  per-column breakdown. Optional Markdown summary via `report()`.
  Companion help: [`dw_compare.sthlp`](dw_compare.sthlp).
- [`dw_mkdir.ado`](dw_mkdir.ado) — recursive `mkdir` for Stata (the
  built-in `mkdir` does not accept nested paths). Idempotent.
  Companion help: [`dw_mkdir.sthlp`](dw_mkdir.sthlp).

### Mode-contract helpers (v0.4.0, new)

- [`dw_use.ado`](dw_use.ado) — uniform Stata read wrapper. Auto-dispatches
  on `.dta` / `.csv` / `.xlsx`. Applies the v0.4.0 mode-branched read
  order — producer mode is local-first with canonical fallback (v0.3.0
  preserved), reviewer mode is network-first (Teams → Z: → repo-local
  with provenance warning → hard-stop). Parses the sibling
  `.provenance.json` sidecar's `datasignature` and compares it against
  the live read; runs a non-blocking Z:-drive integrity check (size by
  default, `datasignature` deep check on request). Companion help:
  [`dw_use.sthlp`](dw_use.sthlp).
- [`dw_require_no_api.ado`](dw_require_no_api.ado) — preflight gate that
  aborts (Stata error 459) when `$dw_mode == "reviewer"`. Use at the
  top of any script that would otherwise call a live external API; the
  optional `context()` argument labels the failing call site in the
  error log. Companion help:
  [`dw_require_no_api.sthlp`](dw_require_no_api.sthlp).
- [`dw_load_config.ado`](dw_load_config.ado) — hand-rolled YAML reader
  for `~/.config/user_config.yml` (path overridable via `filepath()`).
  Populates `$dw_mode` + the `teams*` and `sandboxRoot` path globals.
  No external dependency (AppLocker-safe). Hard-stops when `dw_mode` is
  missing or not in `{producer, reviewer}`. Companion help:
  [`dw_load_config.sthlp`](dw_load_config.sthlp).

## Lineage

These helpers descend from the World Bank
[EduAnalyticsToolkit](https://github.com/worldbank/EduAnalyticsToolkit)
family:

| cso-toolkit | EduAnalyticsToolkit ancestor |
|---|---|
| `dw_save.ado` | `edukit_save.ado` / `savemetadata.ado` (Diana Goldemberg) |
| `dw_compare.ado` | `comparefiles.ado` / `edukit_comparefiles.ado` (Kristoffer Bjärkefur) |
| `dw_mkdir.ado` | `rmkdir.ado` / `edukit_rmkdir.ado` (Kristoffer Bjärkefur) |
| `dw_use.ado` | new (cso-toolkit v0.4.0; mirrors `r/R/dw_io.R::dw_use`) |
| `dw_require_no_api.ado` | new (cso-toolkit v0.4.0; mirrors `r/R/profile_helpers.R`) |
| `dw_load_config.ado` | new (cso-toolkit v0.4.0; hand-rolled YAML subset) |

Each port keeps the upstream's algorithmic core and credits the original
author in its header. The cso-toolkit versions deliberately diverge on
three axes:

1. **Naming and namespace**. Renamed `dw_*` to align with the R helper
   family and avoid clashing with installations of the upstream EduAnalyticsToolkit.
2. **Metadata model**. Upstream `edukit_save` stores metadata as Stata
   `char _dta[...]` entries inside the `.dta` file; `dw_save` writes a
   sibling `.provenance.json` sidecar that the R-side `dw_io`
   integrity checks can also read. This keeps producer / reviewer
   round-trips coherent across R and Stata.
3. **Scope**. `dw_compare` is sized for the cso-toolkit IO contract
   (publication-gate sized — row counts, per-column diff count) rather
   than full editorial diffs. For rich Markdown row-diff reports,
   continue to use the upstream `comparefiles` command directly.

## Installation

Vendored, not installed. From your project's Stata working directory,
either prepend the cso-toolkit clone to your `adopath`:

```stata
adopath ++ "C:/Github/myados/cso-toolkit/stata/src"
which dw_save
```

…or copy the `.ado` and `.sthlp` files into your project's `ado/`
folder and let Stata pick them up via the personal adopath.

## Mode contract — wiring the producer / reviewer switch in Stata

In your project profile (a `.do` file sourced at session start), call
`dw_load_config` to read `~/.config/user_config.yml` and populate the
session globals:

```stata
* --- session start: profile.do ---
adopath ++ "C:/Github/myados/cso-toolkit/stata/src"
dw_load_config
* sets $dw_mode + the team* globals; hard-stops if `dw_mode` is missing
* or set to anything other than producer | reviewer.

* any script that would otherwise call a live API runs this first:
dw_require_no_api , context("ed/06_pull_uis")
```

When `$dw_mode == "reviewer"`, any `dw_save` call whose `path()` starts
with one of the canonical roots will abort with Stata error 459 unless
the caller passes `allow_canonical_write` (DBM bootstraps only). The
same is true for any `path()` under `$dwZDrive` as of v0.4.0.

## Status (v0.4.0)

Closed by [issue #5](https://github.com/unicef-drp/cso-toolkit/issues/5):

- `dw_use.ado` ships — the Stata side now has the full read contract
  including reviewer-mode network-first resolution and the Z: drive
  integrity check.
- `dw_require_no_api.ado` ships — the reviewer-mode no-API guard now
  exists on the Stata side, matching the R + Python helpers.
- `dw_load_config.ado` ships — the YAML-config loader is now bundled,
  AppLocker-safe (no external dependency), and the documented schema is
  validated on read.

Stata-side Parquet / RDS support is intentionally out of scope: producer
pipelines needing those formats route through R or Python and
`dw_save()` the result to `.dta` for Stata consumption.

## See also

- [Top-level README](../../README.md) — toolkit overview + architecture
  diagram.
- [`stata/README.md`](../README.md) — Stata package overview (install,
  layout, mode contract, known limitations).
- [NEWS.md / Changelog](../../NEWS.md) — per-release notes.
- Sibling implementations: [`r/R/README.md`](../../r/R/README.md)
  · [`python/src/README.md`](../../python/src/README.md).
