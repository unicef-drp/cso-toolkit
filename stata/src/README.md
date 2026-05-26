# stata/src/ — Stata helpers

First three Stata helpers shipping in the v0.2 line; they mirror the R API
contract from [`r/R/`](../../r/R/) so a sector that runs partly in Stata and
partly in R can use the same producer / reviewer mode contract on both
sides.

## What's here

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

## Lineage

These helpers descend from the World Bank
[EduAnalyticsToolkit](https://github.com/worldbank/EduAnalyticsToolkit)
family:

| cso-toolkit | EduAnalyticsToolkit ancestor |
|---|---|
| `dw_save.ado` | `edukit_save.ado` / `savemetadata.ado` (Diana Goldemberg) |
| `dw_compare.ado` | `comparefiles.ado` / `edukit_comparefiles.ado` (Kristoffer Bjärkefur) |
| `dw_mkdir.ado` | `rmkdir.ado` / `edukit_rmkdir.ado` (Kristoffer Bjärkefur) |

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

In your project profile (a `.do` file sourced at session start) read
`dw_mode` from `~/.config/user_config.yml` and expose it plus the
canonical-root globals that `dw_save` checks:

```stata
* --- read dw_mode and canonical roots from user_config.yml ---
* (use any YAML helper or simple grep; here a minimal sketch:)
global dw_mode = "producer"
global teamsWrkDataCanonical "C:/Users/<you>/Teams/...DW-MASTER/01_dw_prep/013_wrkdata"
global teamsRawDataCanonical "C:/Users/<you>/Teams/...DW-MASTER/01_dw_prep/011_rawdata"
```

When `$dw_mode == "reviewer"`, any `dw_save` call whose `path()` starts
with one of the canonical roots will abort with Stata error 459 unless
the caller passes `allow_canonical_write` (DBM bootstraps only).

## Known limitations (v0.2)

- No Stata equivalent of `dw_use()` yet. Reading is unconstrained for
  now; the reviewer-mode no-API guard does not exist on the Stata side.
- `dw_save` records `datasignature` (content hash) but not a
  file-level SHA-256; cross-tool integrity checks should compare
  content hashes, not file hashes.
- The YAML-config loader for `$dw_mode` is documented but not shipped
  — projects wire it up themselves until a `dw_load_config.do` helper
  lands.

These three gaps are tracked in
[issue #5](https://github.com/unicef-drp/cso-toolkit/issues/5) for
the v0.4.0 release window.

## See also

- [Top-level README](../../README.md) — toolkit overview + architecture
  diagram.
- [`stata/README.md`](../README.md) — Stata package overview (install,
  layout, mode contract, known limitations).
- [NEWS.md / Changelog](../../NEWS.md) — per-release notes.
- Sibling implementations: [`r/R/README.md`](../../r/R/README.md)
  · [`python/src/README.md`](../../python/src/README.md).
