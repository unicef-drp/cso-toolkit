# Inputs

**No data are committed to this repository.** Inputs live in the deposit
(Teams `060.DW-MASTER` and its Z: mirror) or the microdata archive; this
folder holds local copies of them, which are git-ignored, and their
provenance, which is committed.

| What | Where | Committed? |
|---|---|---|
| Local copies of deposit inputs | `inputs/<path>` | No (git-ignored) |
| Their sidecars | next to each file: `inputs/<path>.provenance.json` | **Yes** |
| Microdata read in place (archive, Z:) | wherever they live | No |
| Their sidecars | `inputs/provenance/<path>/<file>.provenance.json`, mirroring where the file lives | **Yes** |
| Input manifest | `inputs/input_manifest.csv` (`file`, `sha256`, `bytes`, `origin`, `sidecar`) | **Yes** |

`.gitignore` ignores everything under any `inputs/` folder, re-includes the
directories, then only `README.md`, `.gitkeep`, `*.provenance.json` and
`input_manifest.*`.

## Filling and verifying

`dw_fetch_inputs()` copies deposit inputs that are missing locally, checks
every copy's sha256 against Teams and Z:, and returns the manifest
(`file`, `sha256`, `origin`, ...); pass it to `dw_save()`'s `metadata` so
each output's sidecar names the exact inputs it was built from. Keep
`inputs/input_manifest.csv` in step with it and commit the manifest and the
sidecars in the same pull request as the code that first uses an input.

`tests/testthat/test-project.R` checks, without the data, that every
manifest row has a sidecar carrying the same sha256.

## Inputs

<!-- One row per input. -->

| Input | Deposit path | Source | Terms |
|---|---|---|---|
| | | | |
