# 01_dw_prep/010_metadata/

Reference metadata the pipeline reads and keeps under version control:
codelists, indicator definitions, country and region maps. Changes arrive
through pull requests, like code.

- Public, non-embargoed reference tables only; never data or figures.
- Prefer plain text (`.csv`, `.yml`): it diffs in review. Binary data
  formats (`.dta`, `.rds`, `.parquet`, ...) are ignored everywhere by
  `.gitignore` and fail `tools/check.R`.
- A table copied from another repository (Country-and-Region-Metadata, for
  instance) is better read from its pinned URL with `dw_use()`, which
  freezes the download and writes its sidecar.
