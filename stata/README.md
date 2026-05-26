# stata/ — cso-toolkit (Stata)

Stata implementation of the [cso-toolkit](../) IO + sync contract.
Same behaviour matrix as the [R](../r/) and [Python](../python/)
siblings, scoped to the subset of helpers that fit Stata's idioms.

## Status

- **First Stata release** — `v0.2.0` (2026-05-24).
- Subset coverage: writes, comparisons, and recursive mkdir. The full
  IO + API contract is implemented on the R and Python sides; the
  Stata side currently covers the producer-write half. See **Known
  limitations** below.

## Installation

Vendoring is the **production model** (drop the `.ado` and `.sthlp`
files into the consumer's `ado/` or extend the `adopath`). Stata has
no native package install path that matters here.

### Option A — extend the adopath (development)

```stata
adopath ++ "C:/Github/myados/cso-toolkit/stata/src"
which dw_save
```

### Option B — copy into the project's personal adopath (production)

Copy the contents of [`src/`](src/) into the consumer's `ado/` (or
`PERSONAL` adopath). Stata picks them up automatically; pin the vintage
in `.toolkit_manifest.yml`:

```yaml
source: "unicef-drp/cso-toolkit"
pulled_version: "v0.2.0"
pulled_date: "2026-05-25"
```

## Layout

```text
stata/
├── README.md           # this file
└── src/
    ├── README.md       # per-helper catalogue + lineage table
    ├── dw_save.ado     # uniform save() wrapper + .provenance.json sidecar
    ├── dw_save.sthlp
    ├── dw_compare.ado  # compare two .dta files on idvars + valuevars
    ├── dw_compare.sthlp
    ├── dw_mkdir.ado    # recursive mkdir (Stata's built-in is not)
    └── dw_mkdir.sthlp
```

## Quick start

```stata
* 1. Wire the mode contract in your profile (.do sourced at session start)
global dw_mode "producer"
global teamsWrkDataCanonical "C:/Users/<you>/Teams/.../013_wrkdata"
global teamsRawDataCanonical "C:/Users/<you>/Teams/.../011_rawdata"

* 2. Use the contract
use "input.dta", clear
* ... data prep ...

dw_save using "dw_ed_edu.dta",      ///
    idvars(REF_AREA INDICATOR)      ///
    title("Education indicators")   ///
    producer("01_dw_prep/012_codes/ed/example.do") ///
    sources("UIS bulk SDG_092025")  ///
    vintage("2026-05")
* Writes dw_ed_edu.dta + dw_ed_edu.dta.provenance.json
```

## Mode contract (Stata side)

`dw_save` raises Stata error 459 when:

1. The target path lies under `$teamsWrkDataCanonical` /
   `$teamsRawDataCanonical` AND
2. `$dw_mode == "reviewer"` AND
3. The caller did NOT pass `allow_canonical_write`.

This mirrors the R `dw_save()` `stop()` and the Python
`PermissionError` envelopes. The contract is enforced at call site —
not by convention.

## Provenance sidecar

`dw_save` emits `<path>.provenance.json` alongside the `.dta`. Schema
matches the R + Python siblings: `path`, `format`, `written_at`,
`user`, `dw_mode`, `vintage`, content hash via Stata-native
`datasignature` (instead of file-level SHA-256; this keeps the
helper AppLocker-safe by not shelling out).

## Lineage

The three Stata helpers descend from the World Bank
[EduAnalyticsToolkit](https://github.com/worldbank/EduAnalyticsToolkit)
family:

| cso-toolkit      | EduAnalyticsToolkit ancestor                              |
|------------------|-----------------------------------------------------------|
| `dw_save.ado`    | `edukit_save.ado` / `savemetadata.ado` (Diana Goldemberg) |
| `dw_compare.ado` | `comparefiles.ado` / `edukit_comparefiles.ado` (Kristoffer Bjärkefur) |
| `dw_mkdir.ado`   | `rmkdir.ado` / `edukit_rmkdir.ado` (Kristoffer Bjärkefur) |

Each port keeps the upstream's algorithmic core and credits the
original author in its header. See [`src/README.md`](src/README.md) for
the full divergence rationale (naming, metadata model, scope).

## Known limitations (v0.2)

- **No Stata `dw_use`** yet. Reading is unconstrained on the Stata
  side; the reviewer-mode no-API guard exists only in R + Python.
- **No Stata `dw_api_fetch`** yet. External API access in Stata
  pipelines should still route through R or Python and write the cache
  to a path Stata can `use`.
- **Content hash via `datasignature`**, not file-level SHA-256.
  Cross-tool integrity checks should compare content hashes, not file
  hashes.
- The YAML-config loader for `$dw_mode` is documented but not yet
  shipped — projects wire it up themselves until a `dw_load_config.do`
  helper lands (planned for v0.4).

## See also

- [Top-level README](../README.md) — overview, three-role contract,
  vendoring rationale, versioning.
- [NEWS.md / Changelog](../NEWS.md) — per-release notes
  (`v0.1.0-rc1` → `v0.2.0` → `v0.3.0` → `v0.4.0`).
- [`stata/src/README.md`](src/README.md) — per-helper catalogue +
  lineage table.
- Sibling implementations of the same contract:
  - [`r/README.md`](../r/README.md) — R (full IO + API + sync)
  - [`python/README.md`](../python/README.md) — Python (full IO + API + sync)
