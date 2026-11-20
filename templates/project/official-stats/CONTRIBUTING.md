# Contributing

How to work in this repository. Start with `README.md`; the toolkit's
conventions are in The CSO Handbook (unicef-drp/cso-toolkit).

## Ground rules

- **Outputs are embargoed until their publication date.** They go to the
  deposit through `dw_save()`, never into git: not a small CSV, and not its
  `.provenance.json` sidecar either (hashes and row counts of a small table
  can confirm a guessed figure). `.gitignore` ignores `013_wrkdata/`,
  `output/`, `outputs/`, `results/` and `wrk/` at any depth, and
  `tools/check.R` fails on anything tracked inside them.
- **Never commit data; always commit their provenance.** Inputs stay in the
  deposit; `inputs/` and `01_dw_prep/011_rawdata/` hold local copies
  (git-ignored), their sidecars and input manifests (committed).
- **Release records after publication only.** The release pull request adds
  `releases/<vintage>/output_manifest.csv` and the deposited files' sidecars,
  after the publication date and never before (`releases/README.md`).
- **Do not edit vendored code** in `00_functions/`. A change to a toolkit
  helper is a pull request to cso-toolkit; the new release is then
  re-vendored here with the manifest updated.
- **Stage by path** (`git add -- <files>`), never `git add -A` or `git add .`,
  and read `git diff --cached --stat` before committing.

## Joining the team (first clone)

1. Clone, then `git config core.hooksPath .githooks` so the local checks run
   on every push.
2. Copy `_config_template/user_config.yml` to `~/.config/user_config.yml`
   and fill in your block with `dw_mode: reviewer` and a `sandboxRoot`
   outside the repository. Reviewer mode reads the deposit and writes only to
   your sandbox; a Database Manager switches to `producer` for a deposit run.
3. Fill `inputs/` with `dw_fetch_inputs()` and confirm every copy matches the
   deposit (it stops on any mismatch).
4. Reproduce the latest vintage in reviewer mode and compare it with the
   deposit (`dw_compare()`, `dw_provenance_diff()`). A clean comparison means
   your setup reproduces the published figures.
5. Run `Rscript --no-init-file tools/check.R`. Every line must pass.

## Collaboration model

`cso_project.yml` declares the project **{{collaboration}}**.

- `single-producer`: one Database Manager produces each deposit; the others
  review in reviewer mode. The usual setting for a sector pipeline.
- `multi-producer`: several people produce. `dw_save()` then refuses to
  replace an output that was changed outside `dw_save()` or written by
  someone else during your session, unless you pass `takeover = TRUE` after
  checking, and records the lineage in each sidecar.

Change the setting with `dw_set_collaboration()`, never by editing the file
alone, and commit the result as one reviewed pull request (handbook, "Roles
and the mode contract", "Collaboration model").

## Workflow

Two trunks: `develop` is the default branch, `main` holds released
vintages. Protect both, so changes reach them only through pull requests.

1. Branch from an up-to-date `develop`:
   `git switch develop && git pull && git switch -c <type>/<short-name>`.
   Types: `feature/`, `fix/`, `docs/`, `data-prep/`, `release/`.
2. Commit atomically: one logical change per commit, with a short imperative
   subject and a body that says what changed and why.
3. Run the local checks, push the branch and open a pull request into
   `develop`. Paste the output of `tools/check.R` into the description, with
   the reviewer-mode reproduction evidence when the change touches figures
   (the `dw_compare()` summary, the `dw_provenance_diff()` status).
4. Merge after review and delete the branch. A release to `main` is a pull
   request from `develop`; after publication it carries the release record.

## Local checks

Checks run on your machine, not on GitHub Actions:

```
Rscript --no-init-file tools/check.R            # every default check
Rscript --no-init-file tools/check.R --list     # their names
Rscript --no-init-file tools/check.R --only tracked-data
```

It checks that no data, secret, oversized file or embargoed output is
tracked, that every provenance sidecar is well-formed, runs the toolkit's
contract audit on `01_dw_prep/012_codes/` and its vintage check on the
vendored helpers, and runs the testthat suite. It exits non-zero on any
failure, and the pre-push hook in `.githooks/` runs it before every push.
Use `Rscript --no-init-file`, not `--vanilla`.

GitHub Actions workflows are opt-in. If the repository has them
(`.github/workflows/`), they run the same script, by default only when
started by hand and on pull requests into `main`.
