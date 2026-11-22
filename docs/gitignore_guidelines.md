# `.gitignore` guidelines for consumer repos

How a CSO repository (a paper, an analysis project, an official-statistics
production pipeline) should write its `.gitignore`, and how to check that
it works. Two ready-to-copy templates implement these rules:

| Template | For |
|---|---|
| [`templates/gitignore/research-project.gitignore`](../templates/gitignore/research-project.gitignore) | Papers, analysis projects, replication packages. Git is the canonical store for results: small tables and figures are tracked with their sidecars. Data folders at the repo root. |
| [`templates/gitignore/official-stats.gitignore`](../templates/gitignore/official-stats.gitignore) | Official-statistics production repos: DW sector pipelines (DW-Production and siblings), SDMX / data.unicef.org publication pipelines, survey-processing repos. Results are embargoed until publication, so output folders are ignored outright and the release PR commits a per-vintage release record. `inputs/` folders at any depth, `_config_template/user_config.yml` kept. |

The two kinds of repository differ in where results live; the
[side-by-side comparison](#research-projects-and-official-statistics)
below sets out what follows from that.

The check side of the same rules (a check that fails when data are
tracked) is the `tracked-data` check of
[`templates/tools/check.R`](../templates/tools/check.R), run locally and,
when a repo switches it on, by
[`templates/workflows/ci-hygiene.yml`](../templates/workflows/ci-hygiene.yml);
see [`ci_cd_guidelines.md`](ci_cd_guidelines.md).

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
- One exception, in official-statistics repos: the sidecars of *outputs*
  wait for publication. Input sidecars are tracked as above; output sidecars
  enter git only in the release record, after the figures are published
  ([below](#the-embargo-rule)).

## Research projects and official statistics

The two templates share most of their rules, but not the one that matters
most for results:

| | `research-project.gitignore` | `official-stats.gitignore` |
|---|---|---|
| Canonical store for results | Git: the committed tables and figures, each with its sidecar | The deposit: Teams `060.DW-MASTER` / Z:, then SDMX and data.unicef.org |
| Results in the repo? | Small text results (under about 1 MB) and the manuscript's figures, tracked; large binaries and scratch output not | Never. Output folders (`013_wrkdata/`, `output/`, `outputs/`, `results/`, `wrk/`, at any depth) are ignored outright, sidecars included |
| Confidentiality | Results go public with the paper; the confidential part is the microdata, which never enter git anyway | Pre-release figures are embargoed until the publication date. Repository access is not release authorization |
| Release record | The tracked results themselves; tag the submitted version | `releases/<vintage>/output_manifest.csv` plus the deposited files' sidecars, committed in the release PR after publication |
| Folder layout | `data/`, `inputs/`, `_apis/`, `_frozen/` at the root | The deposit's stages (`01_dw_prep/010_metadata`, `011_rawdata`, `012_codes`, `013_wrkdata`); `inputs/`, `011_rawdata/`, `_apis/`, `_frozen/` at any depth keep only READMEs, sidecars and manifests; `releases/` at the root |
| Extra noise | Quarto and LaTeX build files; reviewer sandbox (`sandbox/`) and `*.staged.json` | Reviewer sandbox (`sandbox/`, `dw-repro/`), `*.staged.json`, local copies of the deposit (`060.DW-MASTER/`, `_deposit/`) |
| Tracked config | None by default; a placeholder template only through an explicit `!` line | `_config_template/user_config.yml` (placeholder values only) |

### The embargo rule

In a research project a small results table in git is the point: it is what
a reader checks the paper against. In official statistics the same table,
committed before its publication date, is a pre-release leak. Everyone with
read access to the repository (colleagues on other teams, contractors,
anyone the repository is later shared with or made public to) would see it,
and access to a repository is not authorization to release the figures in
it. Git history also keeps it after the file is deleted.

So `official-stats.gitignore` ignores the output folders wholesale, with
`**/output/**`, `**/outputs/**`, `**/results/**`, `**/wrk/**` and
`**/013_wrkdata/**` (the work-data stage of the deposit layout, where sector
scripts write `01_dw_prep/013_wrkdata/<sector>/`), and does
not re-include anything in them: not a small CSV, and not the
`.provenance.json` sidecars either, whose `sha256` and `schema` (row and
column counts) of a small table are enough to confirm a guessed figure.
Outputs go to the deposit through `dw_save()`, which is where reviewers
read them. The staging habit and CI still matter: a file written outside
these folders is not covered, so a pipeline writes its local outputs into
one of them or straight to the deposit.

The folder rules use `x/**`, not `x/`, so that later blocks can still
re-include files below a folder with one of these names: input sidecars
(`**/inputs/**`), sidecars of frozen downloads (a repository's `output/`
folder fetched under `_frozen/`), and the release record.

### The release record

What an official-statistics repo commits instead of its outputs is a
record of what it deposited, one folder per published vintage:

```text
releases/
  2026-11/
    output_manifest.csv
    dw_ed.csv.provenance.json
    dw_cme.csv.provenance.json
    README.md                  # optional: what was released, links
```

`output_manifest.csv` has one row per deposited file:

| Column | Content |
|---|---|
| `file` | File name as deposited |
| `sha256` | SHA-256 of the deposited bytes (the sidecar's `sha256`) |
| `bytes` | File size |
| `deposited_at` | ISO-8601 UTC time of the deposit |
| `deposit_path` | Path relative to the deposit root, e.g. `01_dw_prep/013_wrkdata/ed/dw_ed.csv` |

The `.provenance.json` files are copies of the deposited files' sidecars,
next to the manifest (sub-folders mirroring the deposit path are fine).
The template re-includes exactly these: `releases/**` is ignored, its
directories re-included, then only `output_manifest.*`, `*.provenance.json`,
`README.md` and `.gitkeep`. A data file copied into `releases/` by mistake
stays ignored. The block comes last in the template so that it wins over
the embargo for a sidecar kept in an `output/` sub-folder of a release.

**Never commit a release record before the publication date.** It goes in
the release PR, which merges on or after publication. Until then the
manifest's hashes and the sidecars are as embargoed as the figures they
describe.

With the record in git, `dw_provenance_diff()` and `dw_check_deposit()`
can answer, for any published vintage, whether the deposit still holds the
bytes that were released and whether a re-run reproduces them.

### Reviewer artefacts

A reviewer session ([chapter 21](https://unicef-drp.github.io/cso-toolkit/handbook/chapters/21-roles-and-modes.html))
writes into its sandbox (`sandboxRoot` in `user_config.yml`), which holds
full copies of canonical and pre-release files, and `dw_stage()` leaves a
`<file>.staged.json` integrity sidecar beside each staged copy. Both are
local to one reviewer. `sandboxRoot` should sit outside the repository;
both templates ignore `sandbox/` and `**/*.staged.json` in case it does
not. The official-stats template also ignores `dw-repro/` (the name the
handbook's examples use for `sandboxRoot`) and local copies of the deposit
(`060.DW-MASTER/`, `_deposit/`); add the name of your own copy if it
differs. In a research project a `.staged.json` appears only when the
project stages deposit files through `dw_stage()`, so the rule there is a
safeguard that costs nothing.

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
`.gitignore`; `**/inputs/**` (as in the official-stats template, which does
the same for `_apis/` and `_frozen/`) matches an `inputs/` folder at any
depth, such as `02_consultations/023_targets/inputs/`.

`dw_fetch_inputs(gitkeep = TRUE)` writes a `.gitkeep` into the inputs
folder and each of its sub-folders so the tree exists in a fresh clone;
the `.gitkeep` lines above are what let git track them.

## What else to ignore

| Block | Patterns | Why |
|---|---|---|
| Data and cache formats, anywhere | `*.sav *.dta *.rds *.RData *.rda *.parquet *.feather *.sas7bdat *.zip *.7z *.gz *.tar *.h5 *.duckdb *.sqlite *.db` | A stray `save()` or download in a code folder should not become a commit. |
| Secrets and personal config | `.env`, `.env.*` (but `!.env.example`), `*.pem`, `*.key`, `*.p12`, `*.pfx`, `.netrc`, `user_config.yml`, `.Renviron` | Credentials and per-machine paths. A placeholder template may be tracked under its own name or with an explicit `!` line after the block (official-stats keeps `!_config_template/user_config.yml` in its own *Tracked configuration* block). Do **not** ignore `.Rprofile`: renv writes its activation line there. |
| Language noise: R | `.Rhistory .RData .Ruserdata .Rproj.user/ renv/library/ renv/local/ renv/staging/ renv/python/` | Session state and the renv library (the lockfile `renv.lock` is tracked). |
| Language noise: Python | `__pycache__/ *.py[cod] .venv/ venv/ .ipynb_checkpoints/ .pytest_cache/ *.egg-info/ build/ dist/` | Build and environment output. |
| Language noise: Stata | `*.log *.smcl *.stswp *.dta~` | Logs are run output, not source. |
| Quarto and LaTeX (research only) | `.quarto/ _freeze/ _book/ _site/ *_files/`, `*.aux *.bbl *.blg *.fdb_latexmk *.fls *.out *.synctex.gz *.toc` … | Rebuilt on every render. If CI renders a Quarto project with `freeze: auto` and must not re-execute code, track `_freeze/` instead (delete that line), and check it carries no data. |
| OS and editors | `.DS_Store Thumbs.db desktop.ini ~$* .idea/ .vscode/ *.bak *.swp *.tmp` | Personal noise; per-user editor choices can also go in your global excludes file (`git config --global core.excludesFile`). |
| Reviewer artefacts | `sandbox/ **/*.staged.json` (official-stats adds `dw-repro/ 060.DW-MASTER/ _deposit/`) | Local copies of canonical and pre-release files; see [above](#reviewer-artefacts). |

**The shared blocks.** Data and cache formats, secrets and personal
configuration, language noise (R, Python, Stata) and OS and editors are the
same in both templates, and their headers carry the tag `[shared]`. People
copy a single file, so each template stays complete rather than including
the other; the toolkit's test suite
([`r/tests/testthat/test-gitignore-templates.R`](../r/tests/testthat/test-gitignore-templates.R))
fails when the rules in a `[shared]` block differ between the two files.
Change a shared block in both templates in the same commit.

### Results (research projects)

In an official-statistics repo results are not tracked at all; see
[the embargo rule](#the-embargo-rule). In a research project:


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
git status --short --untracked-files=all
git status --ignored --short
```

In an official-statistics repo, also check the embargo and the release
record: an output and its sidecar are ignored, the release record is not.

```bash
git check-ignore -v 02_consultations/023_targets/outputs/t.csv.provenance.json   # **/outputs/**
git check-ignore -v releases/2026-11/output_manifest.csv   # !releases/**/output_manifest.*
```

`check-ignore -v` prints the deciding rule for both, including the `!`
rule that re-includes a file; `git status --short --untracked-files=all`
shows which of the two would be committed.

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
  defence, and the hygiene check (`tracked-data` in
  [`tools/check.R`](../templates/tools/check.R), run by the pre-push hook)
  is the backstop that catches what both miss. In an official-statistics
  repo, set its `OUTPUT_DIRS` so it also fails on a tracked pre-release
  output.

## Adopting a template in an existing repo

1. Copy the template to `<repo>/.gitignore` (or merge it into the existing
   file; keep the block order).
2. Adjust the data folders to the repo's layout (`data/`, `inputs/`, a
   sector's `inputs/`, …).
3. Run `git ls-files -i -c --exclude-standard`. Untrack what it lists with
   `git rm --cached`, after checking each file is in the deposit.
4. Research project: for every output whose data now leave git, make sure
   its `.provenance.json` sidecar is tracked; for external microdata, add
   the sidecar under `data/provenance/<path>/`.
   Official statistics: untrack outputs *and* their sidecars from the output
   folders. For vintages already published, move their sidecars into
   `releases/<vintage>/` with an `output_manifest.csv`; for anything not yet
   published, wait for the release PR. Outputs committed before adoption are
   still in history, so tell the repo owner if any were pre-release.
5. Commit the `.gitignore` and the untracking as separate commits.
