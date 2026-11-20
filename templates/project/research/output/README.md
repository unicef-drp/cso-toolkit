# output/

The results the paper uses: small tables (`output/tables/`) and figures
(`output/figures/`). In a research project git is the canonical store for
results, so they are committed, each table with the `.provenance.json`
sidecar `dw_save()` writes next to it.

- Scratch output goes in `output/tmp/` or `output/cache/` (git-ignored).
- Data formats (`.rds`, `.dta`, `.parquet`, ...) and files over 50 MB stay
  out wherever they are written; `tools/check.R` fails on them.
- Every number in the paper traces to a file here.
