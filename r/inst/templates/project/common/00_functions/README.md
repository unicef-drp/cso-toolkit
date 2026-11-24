# 00_functions/

Vendored cso-toolkit helpers: pinned copies of files from
[`unicef-drp/cso-toolkit`](https://github.com/unicef-drp/cso-toolkit)
`r/R/`, committed with the code that uses them, so every commit records the
exact helper code it ran with and a reviewer can re-run it offline (The CSO
Handbook, chapter "Vendoring and updates").

- **`.toolkit_manifest.yml`** records the toolkit release (`pulled_version`)
  and the files copied (`vendored:`). `tools/check.R` (check `vintage`)
  confirms every listed file is here, and `cso_toolkit_check()` warns when
  the copy is behind `target_version`.
- **Do not edit these files.** A change to a helper goes to cso-toolkit as a
  pull request; once released, a producer re-vendors the new release here and
  updates the manifest in one pull request. If a local edit is unavoidable,
  list the file under `local_edits:` and say why in the pull request.
- **Not vendored yet?** Copy the helpers from a cso-toolkit clone at a release
  tag (`dw_io.R`, `dw_api.R`, `cso_toolkit_sync.R`, `dw_provenance.R`,
  `dw_deposit.R`, `dw_project.R`, `test_scripts.R`, `zzz.R`), write the
  manifest (template: cso-toolkit `templates/.toolkit_manifest.yml`), then add
  `contract-audit` and `vintage` back to `CHECKS` at the top of
  `tools/check.R`.

Project code of your own does not go here.
