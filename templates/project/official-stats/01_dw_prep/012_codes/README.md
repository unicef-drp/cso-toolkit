# 01_dw_prep/012_codes/

Pipeline code, one folder per sector (`012_codes/<sector>/`), each driven
by `00_run_<sector>.R`. Scaffold a sector from the repository root:

```r
create_sector_script("<Sector name>", "<code>",
                     base_dir     = "01_dw_prep/012_codes",
                     profile_file = "profile_{{project_name}}.R")
```

(`create_dw_sector_script()` does the same for DW-Production itself: it
names `profile_DW-Production.R`.) The generated script reads
`01_dw_prep/011_rawdata/<code>/` and writes `01_dw_prep/013_wrkdata/<code>/`
relative to `projectFolder`; see `01_dw_prep/README.md` for what each stage
holds and what reaches git.

- Read through `dw_use()` and `dw_api_fetch()`, write through `dw_save()`:
  the helpers route to the deposit in producer mode and to the sandbox in
  reviewer mode, and write the provenance sidecars. The contract audit in
  `tools/check.R` (`AUDIT_PATHS`, `AUDIT_MODE = "blocking"`) fails on raw
  reads, writes and HTTP calls here; mark a documented exception with
  `# cso-allow: <rule>`.
- Never commit an output: `013_wrkdata/` is embargoed until publication.
