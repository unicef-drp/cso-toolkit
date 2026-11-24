# Cross-language conformance harness

## Parity certificate (#190)

The main tool here is the **parity certificate**: the cases in `cases/`, run by
one driver per language in `drivers/`, compared by `certify.py`.

```sh
sh tools/certify             # every case in R, Python and Stata
sh tools/certify --record    # all pass -> commit .parity/<content-hash>.json
sh tools/certify --verify    # is there a passing certificate for this tree?
sh tools/certify --lint      # are the case files well formed? (runs no language)
sh tools/certify --languages r,python --cases io_roundtrip_csv   # while developing
python -m pytest conformance/tests                               # certify.py's own tests
```

With Stata, a full run also runs Stata's own suites, `stata/tests/test_*.do`,
each in its own batch Stata; a wrapper writes each suite's return code to a
result file, and a missing file is a failure. `stata/tests` is a certified path.

- `CSO_PYTHON`: a Python with the toolkit's dependencies, for the Python driver.
- `CSO_RSCRIPT`, `STATA_EXE`: override where R and Stata are found.

**Adding a case**
1. Write `cases/<id>.json` with `id` (the file name), `title`, `surface`, `kind`
   (`values`, with `columns`, `keys`, `rows`, `tolerance`; or `json`, with
   `expect`), `fixtures`, `languages`, and `gaps` / `divergences` keyed by
   language with `issue` and `reason`. Each language is in `languages` or in
   `gaps`, never both.
2. Add `<id>` to each driver that implements it.
3. Run `sh tools/certify --cases <id>`.

**Ids are permanent.** Certificates and the gap register name cases by id. A
removed case's id goes in `retired_ids.txt` (with the date and the reason) and
is never used again. `sh tools/certify --lint`, which every run makes and
the `Conformance` workflow runs on pull requests into `develop` and `main`,
fails when a case uses one, or when a case a committed certificate records
has gone without its id being retired. It also checks that every Stata suite
ends with `global cert_suite_done 1`.

`tests/test_certify.py` checks the harness, and that every case is well formed. The handbook chapter "How the three languages stay in step" has the full protocol.

The round-trip harness described below (`run_r.R`, `run_python.py`,
`compare.py`, the `Conformance` workflow) predates the certificate and still
runs in CI for R and Python.

## The original round-trip harness

Proves the toolkit's core claim — **R, Python, and Stata yield the same
results** — with an executed test, not just the coverage-matrix prose. When this
harness was written, R was CI-gated, Python was manual-only, Stata had no
tests, and parity was asserted but never run; the parity certificate above
now runs it in all three languages.

## What it tests

Each language driver takes the **same committed fixture**, runs the **shared
IO contract** on it, and emits a **normalised** output CSV. A comparator then
asserts the three outputs are **value-equal within tolerance**.

- **Round-trip (R ↔ Python in CI):** `dw_use` → `dw_save` → `dw_use` on
  `fixtures/indicators.csv`. Aggregation, `dw_compare` and the other
  surfaces are covered by the certificate's cases in `cases/`.

## Layout

```
conformance/
  fixtures/indicators.csv   # shared canonical input (edge cases below)
  run_r.R                   # driver: dw_use -> dw_save -> dw_use -> out_r.csv
  run_python.py             # driver -> out_python.csv
  drivers/driver_stata.do   # the Stata driver is part of the parity certificate (no round-trip run_stata.do)
  compare.py                # asserts out_r == out_python == out_stata
```

The **fixture** deliberately exercises float precision (`0.333333333`,
`0.6666666667`), a clean float, a **missing** value, a **negative**, and a
**large int** (`100000`) — the cases most likely to diverge in formatting
across languages.

## Normalisation + comparison

Drivers write a fixed column order (`REF_AREA, INDICATOR, SEX, AGE,
TIME_PERIOD, OBS_VALUE`), rows sorted by the five id keys. The comparator
parses `OBS_VALUE` as a float and compares **numerically within `1e-9`** — so
`1e+05` (R's default repr) `== 100000` (another language's). Missing is `""`
in all three. Byte-identical across languages is *not* the bar; value-identical
is.

## CI (`conformance.yml`)

Jobs: `r-conformance`, `python-conformance` — each runs its driver and uploads
`out_<lang>.csv`; a final `compare` job downloads the outputs and runs
`compare.py` (non-zero exit on any mismatch), on push/PR to `main` + `develop`.

> **Stata-in-CI needs provisioning (admin action — issue #133).** There is no
> Stata runner in this org today. A `stata-conformance` job needs either a
> **Stata Docker image + a `STATA_LIC` repository secret** (the license file)
> or a **self-hosted runner** with Stata installed. Until provisioned, the R
> and Python gates run in CI, `compare.py` tolerates the absent Stata output,
> and Stata parity remains a local release gate.

## Status

- [x] Fixture + design
- [x] `run_r.R` — **working** (verified locally)
- [x] `run_python.py` — R ↔ Python round-trip verified locally (6/6 rows agree)
- [x] Stata: `drivers/driver_stata.do`, run locally by `sh tools/certify`
      (#190); CI still needs #133
- [x] `compare.py`
- [x] `.github/workflows/conformance.yml` (R + Python + compare)
- [ ] Python unit tests (`python/tests/`, pytest) in CI — not planned; they
      run locally
- [ ] `STATA_LIC` secret / self-hosted runner provisioned (admin — issue #133)
