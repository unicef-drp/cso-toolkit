# Cross-language conformance harness

Proves the toolkit's core claim — **R, Python, and Stata yield the same
results** — with an executed test, not just the coverage-matrix prose. This
closes the regression gap flagged for version upgrades: today R is CI-gated,
Python is manual-only, Stata has no tests, and parity is asserted but never run.

## What it tests

Each language driver takes the **same committed fixture**, runs the **shared
IO contract** on it, and emits a **normalised** output CSV. A comparator then
asserts the three outputs are **value-equal within tolerance**.

- **Core (3-way):** `dw_use` → `dw_save` → `dw_use` round-trip. This is the
  surface all three implement (Stata ships `dw_save`, `dw_use`, `dw_compare`
  only — no `aggregate_data_v2` / `dw_api_fetch`).
- **Extension (R ↔ Python):** `aggregate_data_v2`, `dw_compare` semantics —
  the R/Python-only surface, compared pairwise.

## Layout

```
conformance/
  fixtures/indicators.csv   # shared canonical input (edge cases below)
  run_r.R                   # driver: dw_use -> dw_save -> dw_use -> out_r.csv
  run_python.py             # driver -> out_python.csv          (TODO)
  run_stata.do              # driver -> out_stata.csv           (TODO)
  compare.py                # asserts out_r == out_python == out_stata  (TODO)
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

Jobs: `r-conformance`, `python-conformance`, `stata-conformance` — each runs its
driver and uploads `out_<lang>.csv`; a final `compare` job downloads all three
and runs `compare.py` (non-zero exit on any mismatch), on push/PR to
`main` + `develop`.

> **Stata-in-CI needs provisioning (admin action).** There is no Stata runner
> in this org today. The `stata-conformance` job is wired to a **Stata Docker
> image + a `STATA_LIC` repository secret** (the license file). An org admin
> must add that secret before the Stata gate can run; alternatively point the
> job at a **self-hosted runner** with Stata installed. Until then the R and
> Python gates run and the Stata job is skipped / allowed-to-fail.

## Status

- [x] Fixture + design
- [x] `run_r.R` — **working** (verified locally)
- [ ] `run_python.py`
- [ ] `run_stata.do`
- [ ] `compare.py`
- [ ] `.github/workflows/conformance.yml`
- [ ] `.github/workflows/python-check.yml` (Phase 0 — promote the manual Python
      tests to CI; independent of this harness)
- [ ] `STATA_LIC` secret provisioned (admin)
