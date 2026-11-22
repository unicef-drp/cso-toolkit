# CI/CD guidelines for consumer repos

Design principles and a default menu of checks for CSO repositories that
vendor `cso-toolkit`: papers, analysis projects and official-statistics
pipelines. **The checks run locally first**, with one command,
[`tools/check.R`](../templates/tools/check.R), and an optional pre-push
hook ([`templates/hooks/pre-push`](../templates/hooks/pre-push)) that runs
it before every push. GitHub Actions workflows that call the same script
are in [`templates/workflows/`](../templates/workflows/); they are opt-in
and, by default, run only by hand and on release pull requests into
`main`. A testthat skeleton is in
[`templates/testthat/`](../templates/testthat/), and the `.gitignore` rules
the hygiene checks enforce are in
[`gitignore_guidelines.md`](gitignore_guidelines.md). The handbook chapter
*Continuous integration and repository hygiene* summarises the same
material.

## Design principles

1. **Checks run locally first.** Every check in the menu runs on your
   machine with one command from the repo root:

   ```bash
   Rscript --no-init-file tools/check.R           # every default check
   Rscript --no-init-file tools/check.R --only sidecars,tests
   ```

   It prints one `[PASS]` / `[FAIL]` / `[SKIP]` / `[WARN]` line per check,
   a *Why* and a *Fix* line under each failure, and exits non-zero when any
   check fails. The pre-push hook runs it before every `git push`. The
   pull request carries its output (the header line names the commit), so
   the reviewer sees the result without a CI run. GitHub Actions are
   opt-in: the workflow templates call the same script, so turning them on
   adds a second, independent run and never a different check. *Why:*
   Actions minutes run out, and a failure you reproduce on your machine
   gets fixed before the push, not after.
2. **CI never needs real data.** Tests use tiny synthetic fixtures; no
   check reads the deposit. *Why:* data must not be in the repo or on a
   hosted runner, and a check that needs data cannot run on every push.
   Reproduction against real data runs locally in reviewer mode, and its
   evidence goes in the pull request: the `dw_provenance_diff()` status
   (`reproduced`, `output_changed`, …), `dw_check_deposit()` output, or a
   `dw_compare()` summary.
3. **Default checks are fast (target under 10 minutes).** *Why:* a check
   people wait for gets skipped; a fast one runs every time, including
   from a pre-push hook.
4. **Merges are gated by the check record.** By default the gate is the
   `tools/check.R` output in the pull request, for the pull request's head
   commit, and a reviewer who does not merge without it. Required status
   checks are available once a repo turns its workflows on for every pull
   request, but are not the default (see
   [Gating merges](#gating-merges-the-check-record-and-required-checks)).
   *Why:* a check that can be merged around is advice, not a gate; a
   required check whose workflow never runs blocks every merge.
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
   read access to the repo, and kept for months; a pasted local log is just
   as public.
8. **Fail with an actionable message.** Use the toolkit's envelope: what
   failed, why it matters, `Fix:` what to do
   (`[cso_toolkit.<func>] WHAT / Why / Fix`). *Why:* a red check that says
   how to turn it green costs minutes; a bare stack trace costs an
   afternoon.
9. **Spend minutes where they buy something.** When Actions run, default
   to `ubuntu-latest` and as few jobs as possible (each job is billed by
   the started minute). Run Windows and macOS on a schedule or on release,
   not on every push. *Why:* private repos pay for minutes, and Windows
   minutes count 2x and macOS minutes 10x against the quota.
10. **CI is documentation.** A short README section listing the checks, the
    local command and which workflows are switched on. *Why:* a new
    contributor learns the project's quality floor from the README, not from
    reading YAML.

## The default menu

Three tiers. Tier 0 goes in every repo, Tier 1 in every repo with code
(that is, nearly all), Tier 2 when it earns its keep. Every row runs
locally through `tools/check.R`; the *Workflow* column is the opt-in
GitHub Actions template that runs the same check.

### Tier 0: every repo

| Check | `tools/check.R` | Workflow | What it does |
|---|---|---|---|
| Repository hygiene: tracked data | `tracked-data` | [`ci-hygiene.yml`](../templates/workflows/ci-hygiene.yml) | Fails when a file inside `data/`, `inputs/`, `_apis/` or `_frozen/` is tracked other than `README.md`, `.gitkeep`, `*.provenance.json` or `input_manifest.*`; when a data format (`.dta`, `.rds`, `.parquet`, …) is tracked anywhere; when a secret file (`.env`, `*.pem`, `*.key`, `user_config.yml`, `.Renviron`) is tracked; and, in an official-statistics repo (`OUTPUT_DIRS` set), when anything is tracked in an embargoed output folder (`releases/` excepted). `tests/` (fixtures) and `_config_template/` are exempt by default (`ALLOW_PATHS`). |
| Repository hygiene: large files | `large-files` | `ci-hygiene.yml` | Fails on any tracked file over 50 MB (`MAX_FILE_MB`). GitHub warns at 50 MB and rejects at 100 MB. |
| Secret scan | `secret-scan` | `ci-hygiene.yml` | Runs [gitleaks](https://github.com/gitleaks/gitleaks) over the full history with findings redacted. Locally it runs when `gitleaks` is on the PATH and is skipped (`[SKIP]`) otherwise; in CI the workflow installs the pinned binary and a missing one fails. (The gitleaks GitHub Action needs a licence key on organisation repos; the binary does not.) GitHub's own secret scanning and push protection are worth turning on too where available: free on public repos, part of GitHub Secret Protection on private ones. |
| Provenance sidecar validation | `sidecars` | `ci-hygiene.yml` | Every tracked `*.provenance.json` parses, and has the core keys `path`, `format`, `written_at`, `dw_mode` and a 64-hex `sha256`. Stata sidecars (`format: dw_save.provenance/1`) need `datasignature` instead of `sha256`; API-fetch sidecars need `url`, `fetched_at`, `dw_mode`, `sha256` ([Appendix B](https://unicef-drp.github.io/cso-toolkit/handbook/appendices/b-provenance-schema.html)). **Hashes are not re-computed here**, because the data are not in the repo; they are verified in reviewer mode (`dw_read_provenance()`, `dw_check_deposit()`, `dw_provenance_diff()`). |
| Contract audit | `contract-audit` | [`ci-contract-audit.yml`](../templates/workflows/ci-contract-audit.yml) | Sources the vendored `00_functions/dw_io.R` and `test_scripts.R` and runs `test_scripts()` over `AUDIT_PATHS`: any raw IO or HTTP call that should go through a `dw_*` wrapper fails, or, with `AUDIT_MODE = "advisory"` (the setting for a new research project), is listed as a warning without failing the run ([handbook chapter 43](https://unicef-drp.github.io/cso-toolkit/handbook/chapters/43-contract-auditor-ci.html)). Uses the vendored copy, so it audits with the pinned vintage. R only; the Python variant is in chapter 43; Stata has no auditor. |
| Toolkit vintage | `vintage` | `ci-contract-audit.yml` | `00_functions/.toolkit_manifest.yml` exists, parses, has `source`, `pulled_version`, `vendored`, and every `vendored:` file is present; then `cso_toolkit_check()` runs offline in reviewer mode and the check fails if `pulled_version` is behind `target_version` (needs the v0.10.0+ `cso_toolkit_sync.R`). A newer upstream tag is not a failure: refreshing is the producer's decision ([chapter 44](https://unicef-drp.github.io/cso-toolkit/handbook/chapters/44-versioning-release.html)). |

### Tier 1: repos with code

| Check | `tools/check.R` | Workflow | What it does |
|---|---|---|---|
| R tests (testthat) | `tests` | [`ci-r-tests.yml`](../templates/workflows/ci-r-tests.yml) | Non-package project: runs `tests/testthat.R`, the runner from [`templates/testthat/`](../templates/testthat/), in a fresh R process; the runner puts the session in reviewer mode, sources `00_functions/` and the project's function files, and runs `testthat::test_dir()`. Uses the renv library when the repo has one. R package: `check.R` skips this and points to R CMD check, as in the toolkit's own [`r-check.yml`](../.github/workflows/r-check.yml) (the commented `r-package` job in the template). |
| lintr (advisory) | `lint` (opt-in) | `ci-r-tests.yml` `lintr`, manual runs only | `lintr::lint_dir()`, excluding vendored helpers. Reported as `[WARN]`, never a failure. |

**testthat is part of every R repo.** Copy `templates/testthat/` into the
repo root (`tests/testthat.R`, `tests/testthat/helper-project.R`, the
example test and fixture), edit `TOOLKIT_DIR` and `SOURCE_DIRS` at the top
of the runner, run `Rscript --no-init-file tools/check.R --only tests`,
then replace the example with your own tests. Conventions, matching the
toolkit's own suite (`r/tests/testthat/`):

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
  source will break the check. Keep analysis scripts elsewhere.

### Tier 2: optional

| Check | Local / template | When |
|---|---|---|
| Manuscript build + page limit | `tools/check.R --only manuscript` (local `latexmk`, `pdfinfo` for the page count); [`ci-manuscript.yml`](../templates/workflows/ci-manuscript.yml) | Paper repos. Compiles LaTeX from the committed tables and figures (never re-runs the analysis), fails over `MAX_PAGES`. The workflow uploads the PDF; Quarto variant commented in. Path-filtered, so advisory. |
| pkgdown / handbook deploy | `r-lib/actions` pkgdown example; this repo's `publish-book.yml` + `dashboard.yml` | Packages and books with a site. Needs `contents: write` (or `pages: write`) on that one job only. |
| `renv` status | `Rscript -e 'renv::status()'` | Repos with `renv.lock`: flags a lockfile out of sync with the code. |
| Cross-language conformance | this repo's [`conformance.yml`](../.github/workflows/conformance.yml) | Repos that ship the same contract in two languages: run both drivers on one fixture and compare. |
| Scheduled drift checks | `on: schedule` | Weekly at most: OS matrix (Windows, macOS), upstream API reachability, newer toolkit tag. Never on push; never required. |

## Running the checks locally

```bash
Rscript --no-init-file tools/check.R                 # default checks
Rscript --no-init-file tools/check.R --list          # the check names
Rscript --no-init-file tools/check.R --skip tests    # all but one
Rscript --no-init-file tools/check.R --only lint     # an opt-in check
```

- Use `--no-init-file`, not `--vanilla`: `--vanilla` also skips
  `.Renviron` and the library path it sets. `check.R` activates the
  project's renv library itself.
- Configure the checks at the top of `tools/check.R` (`CHECKS`,
  `DATA_DIRS`, `OUTPUT_DIRS`, `ALLOW_PATHS`, `MAX_FILE_MB`, `TOOLKIT_DIR`,
  `AUDIT_PATHS`, …); an environment variable of the same name overrides a
  value for one run. An official-statistics repo sets
  `OUTPUT_DIRS = "output outputs results wrk 013_wrkdata"`, so a tracked
  pre-release output fails the check, and adds `011_rawdata` to `DATA_DIRS` ([the embargo rule](gitignore_guidelines.md#the-embargo-rule)).
- Needs R, git, and the packages testthat, jsonlite (installed with
  testthat) and yaml; gitleaks for the secret scan (skipped without it).

**Check records.** `sh tools/check --record` ([`templates/tools/check`](../templates/tools/check),
a wrapper that starts R right on Windows) runs the checks on a clean working
tree and, if none fails, commits `.checks/<content-hash>.json`, where the hash
is git's tree ID with `.checks/` left out. The pre-push hook (verify mode)
refuses a push without a passing record; the workflow
[`templates/workflows/check-record.yml`](../templates/workflows/check-record.yml),
on by default for pull requests into `develop` and `main`, verifies it in
about 10 seconds without R. Handbook chapter 45, "Check records", has the
details, the branch-protection settings and the Windows note.

**Pre-push hook.** [`templates/hooks/pre-push`](../templates/hooks/pre-push)
requires a passing check record for each pushed branch (`MODE=verify`, the
default; no R) or, with `MODE=run` at its top, runs `tools/check.R` and stops
the push when a check fails. Install it either as a tracked hook for everyone
who opts in:

```bash
mkdir -p .githooks
cp pre-push .githooks/pre-push && chmod +x .githooks/pre-push
git config core.hooksPath .githooks        # once per clone
```

or for one clone only, untracked: `cp pre-push .git/hooks/pre-push`. If
`Rscript` is not on the PATH (common on Windows), set `RSCRIPT` to its
full path; the hook also looks in `C:\Program Files\R`. Skip it once with
`git push --no-verify` (or `CHECK_SKIP=1 git push`), and say why in the
pull request; `CHECK_ARGS="--skip tests" git push` runs a subset.

## Gating merges: the check record and required checks

The toolkit's gitflow ([`git_workflow.md`](git_workflow.md)) is feature
branch → pull request into `develop` → release pull request `develop` →
`main` → tag.

**By default (Actions off for routine work):**

- The pull request author runs `sh tools/check --record`; the
  `check-record` workflow verifies the record of the pull request's head.
  Require the status `check-record` on `develop` and `main`, with
  "Require branches to be up to date before merging", so what merges is the
  checked content. After merging `develop` into a branch, record again.
- Pull requests that only touch generated files (bot rebuilds) pass without
  a record when their paths are listed in the workflow's `EXEMPT_PATHS`.
- The opt-in workflows are **not** required: with the default triggers
  they do not run on pull requests into `develop`, and a required check
  that never runs blocks the merge forever.
- The release pull request into `main` triggers the workflows (their
  default trigger), which gives each release an independent run on a clean
  runner at a cost of a few minutes per release. Any workflow can also be
  run by hand from the Actions tab (*Run workflow*).

**Switching Actions back on for every push and pull request.** Each
workflow template carries a commented `on:` block for this; replace the
default block with it. Then, if you want GitHub to enforce the gate:

- **Require on both `develop` and `main`:** `hygiene (tools/check.R)`,
  `contract audit and toolkit vintage (tools/check.R)`, `R tests
  (testthat)` (or `R CMD check` for a package). These are the job `name:`
  values in the templates; GitHub matches required checks by that name, so
  do not rename a job without updating the branch rule.
- **Never require:** lintr, the manuscript build, scheduled jobs. Advisory
  checks are reported on the pull request but cannot block it.
- **No `paths:` filter on a required workflow.** A required check whose
  workflow did not run (because the pull request touched no matching path)
  stays "Expected — waiting for status" and blocks the merge forever.
  Path-filter only advisory workflows.
- **Set up order:** switch the triggers on a feature branch, let the
  workflows run green on its pull request, merge, and only then mark the
  jobs as required (in *Settings → Branches → Branch protection rules*, or
  a ruleset). A check GitHub has never seen cannot be selected.
- **Releases:** put the expensive extras (Windows/macOS matrix, manuscript
  PDF) on `release` or `workflow_dispatch` triggers so the release has them
  without every push paying for them.
- **Bots and automerge:** a workflow that opens and merges its own pull
  requests (like this repo's handbook rebuild) needs `gh pr merge --auto`
  once checks are required, and the checks must be able to run on the
  bot's branch.

## Adopting the menu in a repo

1. Copy `templates/gitignore/<kind>.gitignore` to `.gitignore`; run
   `git ls-files -i -c --exclude-standard` and untrack what it lists
   ([`gitignore_guidelines.md`](gitignore_guidelines.md)).
2. Copy `templates/tools/check.R` to `tools/check.R` and set its
   configuration block (`AUDIT_PATHS`; `DATA_DIRS` / `ALLOW_PATHS` if the
   layout differs; `OUTPUT_DIRS` in an official-statistics repo).
3. Copy `templates/testthat/` (runner, helper, example).
4. Run `Rscript --no-init-file tools/check.R` and fix what fails.
5. Install the pre-push hook (above) and tell contributors to.
6. Optional: copy `ci-hygiene.yml`, `ci-contract-audit.yml` and
   `ci-r-tests.yml` to `.github/workflows/`. With their default triggers
   they run on release pull requests into `main` and by hand; switch them
   to every push and pull request only if the minutes are there.
7. Add a "Testing and checks" section to the README: the local command, the
   hook, what each check does, and which workflows are switched on.
