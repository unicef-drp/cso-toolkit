# {{title}}

<!-- One paragraph: what the pipeline produces, for which sector and
indicators, where it publishes (Helix, SDMX, data.unicef.org), and who the
Database Manager is. -->

Created on {{date}} with cso-toolkit's `create_official_stats_project()`
(The CSO Handbook, chapter "Starting a new repository"). An
official-statistics repository holds **code, vendored helpers, manifests,
provenance sidecars of inputs, and release records**. Its outputs live in
the deposit (Teams `060.DW-MASTER` and its Z: mirror), then SDMX and
data.unicef.org, and **pre-release figures are embargoed**: access to this
repository is not authorization to release what it produces, so no output,
not even a small table or its sidecar, is ever committed.

## Quick start (including new team members)

1. **Clone**, then enable the local checks once:
   `git config core.hooksPath .githooks`. Work on a branch off `develop`
   (see `CONTRIBUTING.md`).
2. **Configuration.** Copy `_config_template/user_config.yml` to
   `~/.config/user_config.yml` (or add its block to the file you already
   have, for DW-Production say), rename the block to your user name and
   fill it in, with `dw_mode: "reviewer"`, your `teamsRoot` and a
   `sandboxRoot` outside the repository and outside OneDrive. Never commit
   your filled-in copy.
3. **Profile.** Every script and session starts with
   `source("profile_{{project_name}}.R")`: it reads that file, sets
   `dw_mode`, derives the deposit paths from it (`teamsRawData`,
   `teamsWrkData`: the deposit for a producer, your sandbox for a
   reviewer), checks the Z: mirror and loads the vendored helpers.
4. **Inputs.** Fill `inputs/` from the deposit with `dw_fetch_inputs()`; it
   checks every copy's sha256 against the deposit (`inputs/README.md`).
5. **Checks**, before every push, on your machine:
   `sh tools/check --record` (commits a check record when all pass).

`cso_project.yml` declares the project **{{collaboration}}**.

## Layout

```
profile_{{project_name}}.R   sourced first by every script: user, dw_mode, deposit paths, helpers
cso_project.yml          project setting: {{collaboration}} (committed, same for everyone)
_config_template/        user_config.yml template (placeholders only; your copy lives in ~/.config/)
00_documentation/        SOPs, data flows, decisions, the release checklist
00_functions/            vendored cso-toolkit helpers, pinned in .toolkit_manifest.yml
01_dw_prep/
  010_metadata/          reference metadata (codelists, maps), committed
  011_rawdata/<sector>/  local copies of raw inputs: git-ignored, sidecars committed
  012_codes/<sector>/    pipeline code, one folder per sector
  013_wrkdata/<sector>/  local work data and outputs: git-ignored, embargoed
inputs/                  README.md, input_manifest.csv and sidecars (committed); the inputs are git-ignored
releases/<vintage>/      release record: output_manifest.csv and sidecars, committed AFTER publication
tests/                   testthat suite; tests/testthat.R runs it
tools/check.R            every local check, embargo included; sh tools/check --record runs it
.checks/                 check records; .githooks/pre-push requires one before a push
```

The canonical raw data, API caches and promoted work data live in the
deposit (Teams `060.DW-MASTER/01_dw_prep/011_rawdata/` and `013_wrkdata/`):
the profile's `teamsRawData` and `teamsWrkData` point there in producer
mode and to the sandbox in reviewer mode. The folders of the same name in
this repository hold local copies only (`01_dw_prep/README.md`).

## Releases

<!-- The vintages published so far, with links to their release records
under releases/. -->
