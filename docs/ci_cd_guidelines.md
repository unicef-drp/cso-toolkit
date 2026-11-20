# CI/CD guidelines for consumer repos

Design principles and a default menu of GitHub Actions checks for CSO
repositories that vendor `cso-toolkit`: papers, analysis projects and DW
sector pipelines. Ready-to-copy workflows are in
[`templates/workflows/`](../templates/workflows/), a testthat skeleton in
[`templates/testthat/`](../templates/testthat/), and the `.gitignore` rules
the hygiene checks enforce in [`gitignore_guidelines.md`](gitignore_guidelines.md).
The handbook chapter *Continuous integration and repository hygiene*
summarises the same material.

## Design principles

1. **CI never needs real data.** Tests use tiny synthetic fixtures; nothing
   in CI reads the deposit. *Why:* data must not be in the repo or on a
   hosted runner, and a check that needs data cannot run on every push.
   Reproduction against real data runs locally in reviewer mode, and its
   evidence goes in the pull request: the `dw_provenance_diff()` status
   (`reproduced`, `output_changed`, …), `dw_check_deposit()` output, or a
   `dw_compare()` summary.
2. **Default checks are fast (target under 10 minutes).** *Why:* a check
   people wait for gets skipped; a fast one runs every time.
3. **The same checks run locally with one command.** `Rscript
   tests/testthat.R`, the audit one-liner in `ci-contract-audit.yml`, the
   bash blocks in `ci-hygiene.yml`. *Why:* a failure you can reproduce on
   your machine gets fixed before the push, not after.
4. **Required checks gate the protected branches.** *Why:* a check that can
   be merged around is advice, not a gate (see
   [Required checks](#required-checks-and-the-gitflow)).
5. **Every bug fix ships a regression test.** The test reproduces the bug,
   fails on the old code, passes on the fix, and names the issue in its
   title. *Why:* the bug cannot come back silently, and the test documents
   what went wrong.
6. **Least privilege and pinned actions.** Every workflow starts with
   `permissions: contents: read` and widens a single job only when it must
   write; actions are pinned to a major version tag at least
   (`actions/checkout@v4`), third-party actions and binaries to an exact
   release or commit SHA. *Why:* a compromised or changed dependency should
   not be able to write to the repo or alter results unnoticed.
7. **No secrets in logs.** Prefer checks that need no secret at all; when one
   is needed, pass it through `secrets.*` (masked) and never echo it; scanners
   run with `--redact`. *Why:* Actions logs are readable by everyone with
   read access to the repo, and kept for months.
8. **Fail with an actionable message.** Use the toolkit's envelope: what
   failed, why it matters, `Fix:` what to do
   (`[cso_toolkit.<func>] WHAT / Why / Fix`). *Why:* a red check that says
   how to turn it green costs minutes; a bare stack trace costs an
   afternoon.
9. **Spend minutes where they buy something.** Default to `ubuntu-latest`.
   Run Windows and macOS on a schedule or on release, not on every push.
   *Why:* private repos pay for minutes, and Windows minutes count 2x and
   macOS minutes 10x against the quota.
10. **CI is documentation.** A status badge in the README, and a short README
    section listing what runs, when, and how to run it locally. *Why:* a new
    contributor learns the project's quality floor from the README, not from
    reading YAML.

## The default menu

Three tiers. Tier 0 goes in every repo, Tier 1 in every repo with code
(that is, nearly all), Tier 2 when it earns its keep.

### Tier 0: every repo, on push and pull request

| Check | Template | What it does |
|---|---|---|
| Repository hygiene: tracked data | [`ci-hygiene.yml`](../templates/workflows/ci-hygiene.yml) `tracked-data` | Fails when a file inside `data/`, `inputs/`, `_apis/` or `_frozen/` is tracked other than `README.md`, `.gitkeep`, `*.provenance.json` or `input_manifest.*`; when a data format (`.dta`, `.rds`, `.parquet`, …) is tracked anywhere; or when a secret file (`.env`, `*.pem`, `*.key`, `user_config.yml`, `.Renviron`) is tracked. `tests/` (fixtures) and `_config_template/` are exempt by default (`ALLOW_PATHS`). |
| Repository hygiene: large files | `ci-hygiene.yml` `large-files` | Fails on any tracked file over 50 MB (`MAX_FILE_MB`). GitHub warns at 50 MB and rejects at 100 MB. |
| Secret scan | `ci-hygiene.yml` `secret-scan` | Runs the pinned [gitleaks](https://github.com/gitleaks/gitleaks) binary over the full history with findings redacted. (The gitleaks GitHub Action needs a licence key on organisation repos; the binary does not.) GitHub's own secret scanning and push protection are worth turning on too where available: free on public repos, part of GitHub Secret Protection on private ones. |
| Provenance sidecar validation | `ci-hygiene.yml` `sidecars` | Every tracked `*.provenance.json` parses, and has the core keys `path`, `format`, `written_at`, `dw_mode` and a 64-hex `sha256`. Stata sidecars (`format: dw_save.provenance/1`) need `datasignature` instead of `sha256`; API-fetch sidecars need `url`, `fetched_at`, `dw_mode`, `sha256` ([Appendix B](https://unicef-drp.github.io/cso-toolkit/handbook/appendices/b-provenance-schema.html)). **Hashes are not re-computed in CI**, because the data are not there; they are verified locally or in reviewer mode (`dw_read_provenance()`, `dw_check_deposit()`, `dw_provenance_diff()`). |
| Contract audit | [`ci-contract-audit.yml`](../templates/workflows/ci-contract-audit.yml) `audit` | Sources the vendored `00_functions/dw_io.R` and `test_scripts.R` and runs `test_scripts(<path>, error_on_violation = TRUE)` over `AUDIT_PATHS`: any raw IO or HTTP call that should go through a `dw_*` wrapper fails the build ([handbook chapter 43](https://unicef-drp.github.io/cso-toolkit/handbook/chapters/43-contract-auditor-ci.html)). Uses the vendored copy, so CI audits with the pinned vintage. R only; the Python variant is in chapter 43; Stata has no auditor. |
| Toolkit vintage | `ci-contract-audit.yml` `vintage` | `00_functions/.toolkit_manifest.yml` exists, parses, has `source`, `pulled_version`, `vendored`, and every `vendored:` file is present; then `cso_toolkit_check()` runs offline in reviewer mode and the job fails if `pulled_version` is behind `target_version` (needs the v0.10.0+ `cso_toolkit_sync.R`; older copies just skip that part). A newer upstream tag is not a failure: refreshing is the producer's decision ([chapter 44](https://unicef-drp.github.io/cso-toolkit/handbook/chapters/44-versioning-release.html)). |

### Tier 1: repos with code

| Check | Template | What it does |
|---|---|---|
| R tests (testthat) | [`ci-r-tests.yml`](../templates/workflows/ci-r-tests.yml) `testthat` | Non-package project: `Rscript tests/testthat.R`, the runner from [`templates/testthat/`](../templates/testthat/), which puts the session in reviewer mode, sources `00_functions/` and the project's function files, and runs `testthat::test_dir()`. Restores `renv.lock` when present. R package: the commented `r-package` job, R CMD check as in the toolkit's own [`r-check.yml`](../.github/workflows/r-check.yml). |
| lintr (advisory) | `ci-r-tests.yml` `lintr` | `lintr::lint_dir()`, excluding vendored helpers. `continue-on-error: true`: reported, never blocking. |

**testthat is part of every R repo.** Copy `templates/testthat/` into the
repo root (`tests/testthat.R`, `tests/testthat/helper-project.R`, the
example test and fixture), edit `TOOLKIT_DIR` and `SOURCE_DIRS` at the top
of the runner, run `Rscript tests/testthat.R`, then replace the example
with your own tests. Conventions, matching the toolkit's own suite
(`r/tests/testthat/`):

- One `test-<topic>.R` per function family; shared helpers in
  `helper-*.R` (testthat sources them first).
- Session state through a local setter that restores on exit
  (`local_dw_state()` in the template, `local_state()` in the toolkit), so
  test order never matters.
- Errors asserted with `expect_envelope()`: the `[<scope>.<function>]`
  prefix and a `Fix:` line.
- Fixtures in `tests/testthat/fixtures/`, a few rows, synthetic values.
- A regression test per fixed bug, with the issue number in its title
  (`test_that("regression #12: …")`); the template's example shows the
  pattern, and fails on the pre-fix code.
- Function files must only define functions: the runner sources
  `SOURCE_DIRS`, so a file there that reads data or runs a pipeline on
  source will break CI. Keep analysis scripts elsewhere.

### Tier 2: optional

| Check | Template / tool | When |
|---|---|---|
| Manuscript build + page limit | [`ci-manuscript.yml`](../templates/workflows/ci-manuscript.yml) | Paper repos. Compiles LaTeX from the committed tables and figures (never re-runs the analysis), fails over `MAX_PAGES`, uploads the PDF. Quarto variant commented in. Path-filtered, so advisory. |
| pkgdown / handbook deploy | `r-lib/actions` pkgdown example; this repo's `publish-book.yml` + `dashboard.yml` | Packages and books with a site. Needs `contents: write` (or `pages: write`) on that one job only. |
| `renv` status | `Rscript -e 'renv::status()'` | Repos with `renv.lock`: flags a lockfile out of sync with the code. |
| Cross-language conformance | this repo's [`conformance.yml`](../.github/workflows/conformance.yml) | Repos that ship the same contract in two languages: run both drivers on one fixture and compare. |
| Scheduled drift checks | `on: schedule` | Nightly or weekly: OS matrix (Windows, macOS), upstream API reachability, newer toolkit tag. Never on push; never required. |

## Required checks and the gitflow

The toolkit's gitflow ([`git_workflow.md`](git_workflow.md)) is feature
branch → pull request into `develop` → release pull request `develop` →
`main` → tag. Required status checks make CI part of that flow.

- **Require on both `develop` and `main`:** `hygiene: tracked data`,
  `hygiene: large files`, `hygiene: secret scan`, `hygiene: provenance
  sidecars`, `contract audit (test_scripts)`, `toolkit vintage (manifest)`,
  `R tests (testthat)` (or `R CMD check` for a package). These are the job
  `name:` values in the templates; GitHub matches required checks by that
  name, so do not rename a job without updating the branch rule.
- **Never require:** lintr, the manuscript build, scheduled jobs. Advisory
  checks are reported on the pull request but cannot block it.
- **No `paths:` filter on a required workflow.** A required check whose
  workflow did not run (because the pull request touched no matching path)
  stays "Expected — waiting for status" and blocks the merge forever.
  Path-filter only advisory workflows.
- **Set up order:** add the workflows on a feature branch, let them run green
  on its pull request, merge, and only then mark the jobs as required (in
  *Settings → Branches → Branch protection rules*, or a ruleset). A check
  GitHub has never seen cannot be selected.
- **Releases** (`develop` → `main`): the same required checks run on the
  release pull request. Put the expensive extras (Windows/macOS matrix,
  manuscript PDF) on `release` or `workflow_dispatch` triggers so the
  release has them without every push paying for them.
- **Bots and automerge:** a workflow that opens and merges its own pull
  requests (like this repo's handbook rebuild) needs `gh pr merge --auto`
  once checks are required, and the checks must be able to run on the bot's
  branch.

## Adopting the menu in a repo

1. Copy `templates/gitignore/<kind>.gitignore` to `.gitignore`; run
   `git ls-files -i -c --exclude-standard` and untrack what it lists
   ([`gitignore_guidelines.md`](gitignore_guidelines.md)).
2. Copy `ci-hygiene.yml`, `ci-contract-audit.yml` and `ci-r-tests.yml` to
   `.github/workflows/`; set `AUDIT_PATHS`, and `DATA_DIRS` /
   `ALLOW_PATHS` if the layout differs.
3. Copy `templates/testthat/` (runner, helper, example) and run
   `Rscript tests/testthat.R` locally.
4. Push on a feature branch, open the pull request into `develop`, fix what
   goes red, merge.
5. Mark the Tier 0 and Tier 1 jobs as required on `develop` and `main`.
6. Add the badge and a "Testing and CI" section to the README, listing each
   workflow, what it checks, and the local command.
