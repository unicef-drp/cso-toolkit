# 01_dw_prep/012_codes/

Pipeline code, one folder per sector (`012_codes/<sector>/`), each driven
by `00_run_<sector>.R`. Scaffold a sector from the repository root with
`create_dw_sector_script("<Sector name>", "<code>")`.

The stage numbers follow the deposit (The CSO Handbook, "Wiring the
contract"):

| Stage | Lives in | In git |
|---|---|---|
| `011_rawdata` (inputs, API caches in `_apis/`) | the deposit: `teamsRawData` | no |
| `012_codes` (this folder) | this repository | yes |
| `013_wrkdata` (promoted outputs) | the deposit: `teamsWrkData` | never: embargoed |

- Read through `dw_use()` and `dw_api_fetch()`, write through `dw_save()`:
  the helpers route to the deposit in producer mode and to the sandbox in
  reviewer mode, and write the provenance sidecars. The contract audit in
  `tools/check.R` (`AUDIT_PATHS`) flags raw reads, writes and HTTP calls
  here; mark a documented exception with `# cso-allow: <rule>`.
- Write outputs to the deposit paths, never to a folder in this repository.
