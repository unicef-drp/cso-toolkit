# {{title}}

<!-- One paragraph: the question, the authors and their affiliation, the
target outlet, and whether the repository is public or private. -->

Created on {{date}} with cso-toolkit's `create_research_project()` (The CSO
Handbook, chapter "Starting a new repository"). The rules in one line:
**data never enter git; the provenance sidecars that say exactly which bytes
each result came from always do.**

## Quick start (including co-authors joining)

1. **Clone**, then enable the local checks once:
   `git config core.hooksPath .githooks`. Work on a branch off `develop`
   (see `CONTRIBUTING.md`).
2. **Session mode.** In your `~/.config/user_config.yml`, in the block
   named after your user name, set `dw_mode: "reviewer"` (no network
   refreshes, no writes outside your sandbox). Switch to `producer` only
   for a session in which you deliberately produce or refresh results, or
   for this project alone with `dw_mode_by_project:` /
   `{{project_name}}: "producer"`. `cso_project.yml` declares the project
   **{{collaboration}}**.
3. **Profile.** Every script and session starts with
   `source("profile_{{project_name}}.R")`: it reads that file, sets
   `dw_mode`, loads the vendored helpers and stops, saying what to add,
   when something is missing.
4. **Data.** The data are never in the repository. Obtain each input under
   your own licence; `data/README.md` says where each comes from and where
   it goes.
5. **Verify** that your copies are byte-identical to the inputs the results
   were built from (`data/README.md`, "Verify") before running anything.
6. **Checks**, before every push, on your machine:
   `Rscript --no-init-file tools/check.R`.

## Layout

```
profile_{{project_name}}.R   sourced first by every script: user, dw_mode, helpers
cso_project.yml   project setting: {{collaboration}} (committed, same for everyone)
00_functions/     vendored cso-toolkit helpers, pinned in .toolkit_manifest.yml
R/                analysis scripts, numbered in run order; R/functions/ for tested functions
data/             README.md, input_manifest.csv, provenance/ (committed); the data are git-ignored
output/           tables and figures the paper uses, each with its .provenance.json sidecar
paper/            the manuscript (paper/main.tex)
references/       bibliography and notes on sources
docs/             analysis plan, notes, decisions
tests/            testthat suite; tests/testthat.R runs it
tools/check.R     every local check; .githooks/pre-push runs it before a push
```

## Results

<!-- Where the main tables and figures are, which script writes each, and
the date of the last full run. -->
