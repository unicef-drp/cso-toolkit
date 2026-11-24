# 01_dw_prep/

Data-warehouse preparation, numbered by lifecycle stage as in the deposit
(Teams `060.DW-MASTER/01_dw_prep/`) and in DW-Production (The CSO Handbook,
"Roles and the mode contract" and "Profiles and the mode switch").

| Stage | Holds | In this repository | In git |
|---|---|---|---|
| `010_metadata/` | reference metadata the pipeline reads: codelists, indicator and region maps | yes | yes, through pull requests |
| `011_rawdata/<sector>/` | raw inputs and API caches (`_apis/`), frozen downloads (`_frozen/`) | local copies only; the canonical copy is the deposit's (`teamsRawData`) | only `README.md`, `.gitkeep`, sidecars, input manifests |
| `012_codes/<sector>/` | the pipeline code | yes | yes |
| `013_wrkdata/<sector>/` | work data and the outputs a run produces | local runs only; promoted outputs live in the deposit (`teamsWrkData`) | **never**: embargoed until publication |

`011_rawdata/` and `013_wrkdata/` exist here because sector scripts read
and write relative to the repository (`projectFolder`), as in
DW-Production. `.gitignore` keeps their contents out of git and
`tools/check.R` fails on anything tracked in `013_wrkdata/` (`OUTPUT_DIRS`)
or on data tracked in `011_rawdata/` (`DATA_DIRS`). `013_wrkdata/` has no
tracked file at all: a sector script creates its folder on first run.
