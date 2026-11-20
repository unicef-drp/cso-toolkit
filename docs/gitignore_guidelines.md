# `.gitignore` guidelines for consumer repos

How a CSO repository (a paper, an analysis project, a DW sector pipeline)
should write its `.gitignore`, and how to check that it works. Two
ready-to-copy templates implement these rules:

| Template | For |
|---|---|
| [`templates/gitignore/research-project.gitignore`](../templates/gitignore/research-project.gitignore) | Papers, analysis projects, replication packages. Data folders at the repo root. |
| [`templates/gitignore/pipeline.gitignore`](../templates/gitignore/pipeline.gitignore) | DW sector pipelines (DW-Production and siblings). `inputs/` folders at any depth, `_config_template/user_config.yml` kept. |

The CI side of the same rules (a check that fails when data are tracked)
is in [`ci_cd_guidelines.md`](ci_cd_guidelines.md) and
[`templates/workflows/ci-hygiene.yml`](../templates/workflows/ci-hygiene.yml).

## The rule

**Data never enter git. The provenance sidecars that say exactly which
bytes each result came from always do.**

- Data live in the deposit: the Teams `060.DW-MASTER` folder and its Z:
  mirror, `S:\datalib-*`, Gitea LFS for research microdata. `dw_fetch_inputs()`
  fills a local, gitignored inputs folder from the deposit and checks each
  copy's SHA-256 (see [`dw_io_reference.md`](dw_io_reference.md)).
- What git holds is the record: every `dw_save()` output has a
  `<file>.provenance.json` sidecar ([Appendix B](https://unicef-drp.github.io/cso-toolkit/handbook/appendices/b-provenance-schema.html))
  with the file's `sha256`, schema, writer, mode and, through
  `metadata.inputs`, the hashes of the inputs it was built from. Committing
  the sidecars puts that record under version control while the data stay
  out: a reviewer can tell from git alone which bytes a result came from, and
  `dw_provenance_diff()` can tell whether a re-run reproduced it.
- Where the sidecar goes:
  - **A file inside the repo but ignored** (an input under `inputs/`, an
    output under `data/`): the sidecar sits next to it,
    `data/derived/panel.csv.provenance.json`, and is tracked while the data
    file is not.
  - **Microdata kept outside the repo** (S:, Z:, Teams, Gitea LFS): the
    sidecar goes under `data/provenance/<path>/`, mirroring where the file
    lives. A sidecar for `S:\datalib-edu\KEN\2022\hh.dta` is committed as
    `data/provenance/S/datalib-edu/KEN/2022/hh.dta.provenance.json`.

## The data-folder pattern, and why it has four kinds of line

```gitignore
data/**                       # 1. ignore everything below data/
!data/**/                     # 2. re-include the directories
!data/**/README.md            # 3. then only these files
!data/**/.gitkeep
!data/**/*.provenance.json
!data/**/input_manifest.*
```

The same block repeats for `inputs/`, `_apis/` (the `dw_api_fetch()`
cache) and `_frozen/` (`dw_use()` URL downloads).

**Line 2 is the one people drop, and the pattern breaks without it.** Git
cannot re-include a file if a parent directory of that file is excluded: for
speed, git does not look inside an excluded directory at all, so a `!` rule
for a file in it is never consulted. `data/**` matches the sub-directories
too (`data/raw/`, `data/raw/mics/`), so without line 2 `!data/**/README.md`
would bring back `data/README.md` and nothing deeper. `!data/**/` (the
trailing slash means "directories only") re-includes every directory, which
lets git look inside; the files in them are still ignored by line 1 unless
a line-3 rule names them.

Two consequences:

- Write `data/**`, not `data/`. `data/` excludes the directory itself, and
  nothing below it can ever be re-included.
- Order matters: the last rule that matches a path wins. Keep the `!` lines
  after the rule they override.

`a/**/b` also matches `a/b`, so `!data/**/README.md` covers `data/README.md`
itself. Patterns containing a slash are anchored to the folder of the
`.gitignore`; `**/inputs/**` (as in the pipeline template) matches an
`inputs/` folder at any depth, such as `02_consultations/023_targets/inputs/`.

`dw_fetch_inputs(gitkeep = TRUE)` writes a `.gitkeep` into the inputs
folder and each of its sub-folders so the tree exists in a fresh clone;
the `.gitkeep` lines above are what let git track them.

## What else to ignore

| Block | Patterns | Why |
|---|---|---|
| Data and cache formats, anywhere | `*.sav *.dta *.rds *.RData *.rda *.parquet *.feather *.sas7bdat *.zip *.7z` (the research template adds `*.gz *.tar *.h5 *.duckdb *.sqlite *.db`) | A stray `save()` or download in a code folder should not become a commit. |
| Secrets and personal config | `.env`, `.env.*` (but `!.env.example`), `*.pem`, `*.key`, `*.p12`, `*.pfx`, `.netrc`, `user_config.yml`, `.Renviron` | Credentials and per-machine paths. A placeholder template may be tracked under its own name or with an explicit `!` line (`!_config_template/user_config.yml`). Do **not** ignore `.Rprofile`: renv writes its activation line there. |
| R | `.Rhistory .RData .Ruserdata .Rproj.user/ renv/library/ renv/local/ renv/staging/` | Session state and the renv library (the lockfile `renv.lock` is tracked). |
| Python | `__pycache__/ *.py[cod] .venv/ venv/ .ipynb_checkpoints/ .pytest_cache/ *.egg-info/` | Build and environment output. |
| Stata | `*.log *.smcl *.stswp` | Logs are run output, not source. |
| Quarto and LaTeX | `.quarto/ _freeze/ _book/ _site/ *_files/`, `*.aux *.bbl *.blg *.fdb_latexmk *.fls *.out *.synctex.gz *.toc` … | Rebuilt on every render. If CI renders a Quarto project with `freeze: auto` and must not re-execute code, track `_freeze/` instead (delete that line), and check it carries no data. |
| OS and editors | `.DS_Store Thumbs.db desktop.ini ~$* .idea/ .vscode/` | Personal noise; per-user editor choices can also go in your global excludes file (`git config --global core.excludesFile`). |

### Results

- **Tracked:** small text results (CSV, TSV, `.tex`, `.md`, JSON; as a rule
  under 1 MB each) and the figures the manuscript includes, each with its
  `.provenance.json` sidecar. These are what a reader checks a paper against,
  and diffs on them show when a re-run moved a number.
- **Not tracked:** large binaries (the data formats above), intermediate
  datasets, caches, scratch output (`results/tmp/`, `results/cache/`). If a
  result is needed downstream and is large, deposit it and commit its sidecar.

## How to verify

```bash
# Which rule decides a path (prints the .gitignore line, or nothing)
git check-ignore -v data/raw/mics/hh.csv
git check-ignore -v --no-index results/t1.csv   # also for tracked files

# Tracked files that the rules now say should be ignored -- must print nothing
git ls-files -i -c --exclude-standard

# What would be added (dry run), and what is ignored but present
git status --short
git status --ignored --short
```

When `git ls-files -i -c --exclude-standard` lists something, untrack it
without deleting it from disk, then commit:

```bash
git rm --cached -- data/raw/mics/hh.csv        # one file
git rm -r --cached -- data/raw/                 # a folder
git commit -m "chore: stop tracking raw data (kept locally)"
```

`git rm --cached` removes the file from the next commit only. **History
still holds every version that was committed**, and anyone with read access
to the repository can recover it. Removing it from history (`git
filter-repo`, then a force-push that the branch protection on `main` and
`develop` blocks, then every clone re-cloning, plus a GitHub support request
for cached pull-request refs) is a separate decision: take it with the repo
owner, and with the data owner when the file is confidential microdata. A
leaked secret is compromised the moment it is pushed: rotate it first,
whatever happens to history.

## Staging discipline

- Never `git add -A` or `git add .`. Stage by path: `git add -- R/clean.R
  results/t1.csv results/t1.csv.provenance.json`.
- Read `git status` and `git diff --cached --stat` before every commit.
- The `.gitignore` is the safety net, the staging habit is the first line of
  defence, and the CI hygiene check
  ([`ci-hygiene.yml`](../templates/workflows/ci-hygiene.yml)) is the backstop
  that catches what both miss.

## Adopting a template in an existing repo

1. Copy the template to `<repo>/.gitignore` (or merge it into the existing
   file; keep the block order).
2. Adjust the data folders to the repo's layout (`data/`, `inputs/`, a
   sector's `inputs/`, …).
3. Run `git ls-files -i -c --exclude-standard`. Untrack what it lists with
   `git rm --cached`, after checking each file is in the deposit.
4. For every output whose data now leave git, make sure its
   `.provenance.json` sidecar is tracked; for external microdata, add the
   sidecar under `data/provenance/<path>/`.
5. Commit the `.gitignore` and the untracking as separate commits.
