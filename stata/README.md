# stata/ — cso-toolkit (Stata)

Stata implementation of the [cso-toolkit](../) IO + sync contract.
Same behaviour matrix as the [R](../r/) and [Python](../python/)
siblings, scoped to the subset of helpers that fit Stata's idioms.

## Status

- **First Stata release** — `v0.2.0` (2026-05-24).
- **v0.4.0** (in flight) — adds `dw_use`, `dw_require_no_api`, and
  `dw_load_config`. The Stata side now covers the full producer /
  reviewer mode contract for `.dta` / `.csv` / `.xlsx` reads + writes;
  Parquet / RDS remain R+Python-only by design.

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
├── README.md                   # this file
└── src/
    ├── README.md               # per-helper catalogue + lineage table
    ├── dw_save.ado             # uniform save() wrapper + .provenance.json sidecar
    ├── dw_save.sthlp
    ├── dw_use.ado              # uniform read() with v0.4.0 mode-branched resolver
    ├── dw_use.sthlp
    ├── dw_compare.ado          # compare two .dta files on idvars + valuevars
    ├── dw_compare.sthlp
    ├── dw_mkdir.ado            # recursive mkdir (Stata's built-in is not)
    ├── dw_mkdir.sthlp
    ├── dw_require_no_api.ado   # reviewer-mode no-API gate
    ├── dw_require_no_api.sthlp
    ├── dw_load_config.ado      # YAML config loader (AppLocker-safe)
    ├── dw_load_config.sthlp
    ├── dw_map_drive.ado        # map the team network drive (port of datalib mapzdrive)
    └── dw_map_drive.sthlp
```

## Quick start

```stata
* 1. Bootstrap the session (v0.4.0)
adopath ++ "C:/Github/myados/cso-toolkit/stata/src"
dw_load_config                                          // reads ~/.config/user_config.yml
                                                        // -> sets $dw_mode + team* globals

* 2. (optional) Refuse live API calls in reviewer mode
dw_require_no_api , context("ed/06_pull_uis")

* 3. Read with the v0.4.0 mode-branched resolver
dw_use , filename("dw_ed_edu.dta") path("$teamsWrkData/ed")
* reviewer mode: tries Teams canonical -> Z: mirror -> repo-local + warning -> stop
* producer mode: local-first; canonical fallback when the literal is missing

* 4. ... data prep ...

* 5. Write with the producer / reviewer guard + .provenance.json sidecar
dw_save , filename("dw_ed_edu") path("$teamsWrkData/ed") ///
    idvars(REF_AREA INDICATOR)                          ///
    title("Education indicators")                       ///
    producer("01_dw_prep/012_codes/ed/example.do")      ///
    sources("UIS bulk SDG_092025")                      ///
    vintage("2026-05")
* writes dw_ed_edu.dta + dw_ed_edu.dta.provenance.json
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

Also new in the lineage table: `dw_use.ado`, `dw_require_no_api.ado`,
and `dw_load_config.ado` are cso-toolkit-native (no upstream port). The
`dw_use` resolver mirrors the R `dw_io.R::dw_use` and the Python
`dw_io.py::dw_use` contract.

## Known limitations (v0.4.0)

- **No Stata `dw_api_fetch`** yet. External API access in Stata
  pipelines should still route through R or Python and write the cache
  to a path Stata can `use`. `dw_require_no_api` enforces this for
  reviewer sessions; producer pipelines wanting Stata-native HTTP
  should call R / Python and hand back the cache via `dw_use`.
- **Stata `.parquet` / `.rds` reads are out of scope.** Auto-dispatch
  on the Stata side covers `.dta` / `.csv` / `.xlsx` only. Pipelines
  needing the binary formats route through R or Python and
  `dw_save()` to `.dta` for Stata consumption.
- **Content hash via `datasignature`**, not file-level SHA-256.
  Cross-tool integrity checks should compare content hashes, not file
  hashes.

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
