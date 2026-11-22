# Contributing

How to work in this repository. Start with `README.md`; the toolkit's
conventions are in The CSO Handbook (unicef-drp/cso-toolkit).

## Ground rules

- **Never commit data; always commit their provenance.** No microdata,
  extracts, caches or external datasets, and no secrets.
  - `.gitignore` enforces this for `data/`, `inputs/`, the API caches and
    common data formats; `tools/check.R` checks it again before every push.
  - Every input has a committed `.provenance.json` sidecar (with its sha256)
    and a row in `data/input_manifest.csv`. Commit a new input's sidecar and
    row in the same pull request as the code that first uses it.
  - Results in `output/` are committed, each with its sidecar: write them
    with `dw_save()`.
- **Do not edit vendored code** in `00_functions/`. A change to a toolkit
  helper is a pull request to cso-toolkit; the new release is then
  re-vendored here with the manifest updated.
- **Stage by path** (`git add -- <files>`), never `git add -A` or `git add .`,
  and read `git diff --cached --stat` before committing.
- **Ask before** sharing files outside the team, adding collaborators or
  changing repository settings.

## Joining the project (first clone)

1. Clone, then `git config core.hooksPath .githooks` so every push needs a
   passing check record.
2. In `~/.config/user_config.yml`, under your user name, set
   `dw_mode: reviewer`. Use `producer` only in a session in which you
   deliberately produce or refresh results; what that session changes goes
   through a pull request like any other change.
3. Obtain the inputs under your own licence (`data/README.md`) and verify
   them. Every input must match its manifest row: then your bytes are the
   ones the results were built from. A mismatch means a different release or
   vintage; raise it before running anything.
4. Run `sh tools/check`. Every line must pass.
5. In a multi-producer project, add your handle under `members:` in
   `cso_project.yml` in your first pull request.

## Collaboration model

`cso_project.yml` declares the project **{{collaboration}}**.

- `single-producer`: one person produces the results; the others review
  them in reviewer mode.
- `multi-producer`: every co-author may produce results, always on a branch
  and through a pull request. `dw_save()` then refuses to replace an output
  that was changed outside `dw_save()` or written by someone else during
  your session, unless you pass `takeover = TRUE` after checking, and it
  records the lineage in each sidecar.

Change the setting with `dw_set_collaboration()` (it also baselines the
existing sidecars), never by editing the file alone, and commit the result
as one reviewed pull request (handbook, "Roles and the mode contract",
"Collaboration model").

## Workflow

Two trunks: `develop` is the default branch, `main` holds submitted or
circulated versions. Protect both, so changes reach them only through pull
requests.

1. Branch from an up-to-date `develop`:
   `git switch develop && git pull && git switch -c <type>/<short-name>`.
   Types: `feature/`, `fix/`, `docs/`, `data-prep/`, `analysis/`.
2. Commit atomically: one logical change per commit. Code and the outputs it
   regenerates go in the same commit; prose changes go separately.
3. Commit messages: a short imperative subject (72 characters at most), a
   blank line, then what changed and why, including any number that moved.
4. Run `sh tools/check --record`, push the branch and open a pull request
   into `develop`. The `check-record` status confirms the checks passed; say
   what changed, which outputs were regenerated and how you checked them.
5. Merge after review and delete the branch. A release to `main` is a pull
   request from `develop`, tagged after the merge.

## Local checks

Checks run on your machine, not on GitHub Actions:

```
sh tools/check                 # every default check
sh tools/check --record        # ... and commit a check record
sh tools/check --list          # their names
sh tools/check --only tests
```

It checks that no data, secret or oversized file is tracked, that every
provenance sidecar is well-formed, runs the toolkit's contract audit and
vintage check on the vendored helpers, and runs the testthat suite. It exits
non-zero on any failure. `sh tools/check` runs it with the right R setup
(`Rscript --no-init-file tools/check.R` takes the same arguments; use
`--no-init-file`, not `--vanilla`, which also drops `.Renviron` and the
library path it sets). Add a test to `tests/testthat/`
for each function and each bug fix.

**Check records.** `sh tools/check --record` runs the checks on a clean
working tree and, if none fails, commits `.checks/<content-hash>.json`: a
record that this exact content passed (`.checks/README.md`). The pre-push
hook refuses a push without one, and the `check-record` workflow verifies it
on pull requests into `develop` and `main` without running R. After merging
`develop` into your branch, record again: the content changed. On Windows,
`tools/check` starts R so it finds your `.Renviron` (Git Bash's `HOME` would
hide it).

The other GitHub Actions workflows are opt-in. If the repository has them
(`.github/workflows/`), they run the same script, by default only when
started by hand and on pull requests into `main`.

## Checking numbers

Every number in the paper traces to a file in `output/`.

- After re-running anything, check the prose against the new tables.
  Comparative claims ("flat", "the same", "robust") can flip while levels
  barely move.
- Before a submission, have someone who did not write the text recompute
  every number from the outputs.
- Label interim inputs *preliminary* wherever they are used.
