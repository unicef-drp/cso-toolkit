# Data

**No data are committed to this repository.** Microdata stay outside it
(an archive drive, the Teams deposit, Gitea LFS, a sibling folder); external
aggregates and derived caches may sit in `data/` but are git-ignored. This
file says where every input comes from and how to obtain or regenerate it.

## Provenance: what IS committed

The data stay out; **their provenance sidecars are committed.** Each input
has one JSON file in the cso-toolkit `.provenance.json` format (The CSO
Handbook, Appendix B) recording its sha256, size, source and the scripts
that read it. Together they are the version-controlled record of exactly
which bytes every result was built from.

| What | Where | Committed? |
|---|---|---|
| Microdata kept outside the repository | wherever they live (see the table below) | No |
| Their sidecars | `data/provenance/<path>/<file>.provenance.json`, mirroring where the file lives | **Yes** |
| External aggregates and downloads | `data/external/<file>` | No (git-ignored) |
| Their sidecars | next to the file: `data/external/<file>.provenance.json` | **Yes** |
| Input manifest | `data/input_manifest.csv` (`file`, `sha256`, `bytes`, `origin`, `sidecar`) | **Yes** |
| Derived caches | `data/derived/` | No |

`.gitignore` enforces this: it ignores everything under `data/`,
re-includes the directories (git cannot re-include a file inside an
excluded directory), and then re-includes only `README.md`,
`input_manifest.*`, `*.provenance.json` and `.gitkeep`. Check what git would
add with `git status --short --untracked-files=all data`.

- **Add an input:** record its sidecar and a manifest row (`file` is the
  path relative to the repository root, `sidecar` the path of its sidecar),
  and commit both in the same pull request as the code that first uses it.
  Inputs fetched with `dw_api_fetch()` or copied from the deposit with
  `dw_fetch_inputs()` get their hashes from the toolkit.
- **An input changed** (a new release, a re-download): record it again,
  re-run what depends on it, and commit the new sidecar with the regenerated
  outputs. Never update a sidecar without re-running what depends on it.

### Verify

A co-author obtains the inputs under their own licence, places them at the
paths in the manifest, and checks that the bytes match:

```r
m <- read.csv("data/input_manifest.csv", colClasses = "character")
bad <- m$file[vapply(m$file, function(f) !file.exists(f) ||
  !identical(digest::digest(file = f, algo = "sha256"), m$sha256[m$file == f][1]),
  logical(1))]
bad   # must be empty
```

`tests/testthat/test-project.R` checks, without the data, that every
manifest row has a sidecar carrying the same sha256.

## Inputs

<!-- One row per input. -->

| Input | Local path | Obtain from | Licence / terms |
|---|---|---|---|
| | | | |
