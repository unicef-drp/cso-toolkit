# R/

Analysis scripts, numbered in the order they run (`01_extract.R`,
`02_describe.R`, `03_models.R`, ...). Run them from the repository root
with `Rscript --no-init-file R/<script>.R`; a master script at the root
(`run.R`) can run them in order.

- Read inputs and write results through the toolkit (`dw_use()`,
  `dw_api_fetch()`, `dw_save()`), so every result gets its provenance
  sidecar and a reviewer session cannot overwrite it. The contract audit in
  `tools/check.R` flags raw reads, writes and HTTP calls in this folder; mark
  a documented exception with `# cso-allow: <rule>`.
- Put the functions you want tested in `R/functions/`: files that only
  define functions. `tests/testthat.R` sources that folder, never the
  numbered scripts, which read data when sourced.
