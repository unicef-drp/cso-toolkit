# 01_dw_prep/011_rawdata/

Local copies of the raw inputs, one folder per sector
(`011_rawdata/<sector>/`), read by the sector scripts. The canonical copy
is the deposit's (`teamsRawData`: Teams `060.DW-MASTER/01_dw_prep/011_rawdata/`
in producer mode, your sandbox in reviewer mode), together with the API
cache (`_apis/`, filled by `dw_api_fetch()`).

**No data are committed here.** `.gitignore` ignores everything below this
folder, then re-includes only `README.md`, `.gitkeep`, `*.provenance.json`
sidecars and `input_manifest.*`, and `tools/check.R` fails on any other
tracked file (`DATA_DIRS`). Commit an input's sidecar with the code that
first reads it, so the record of which bytes the pipeline used is in git
while the bytes stay in the deposit.
