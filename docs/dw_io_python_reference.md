# `dw_io.py` reference

Python port of `r/R/dw_io.R`.  Same behaviour contract; mode-aware path
routing, Z: drive mirror, provenance sidecar emission.  Imports as
`from cso_toolkit import dw_save, dw_use, ...`.

See also: [`dw_io_reference.md`](dw_io_reference.md) for the R
counterpart.

## Behaviour matrix

| Function              | Producer session (v0.4.0)                                                                  | Reviewer session (v0.4.0)                                                                         |
| --------------------- | ------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------- |
| `dw_save`             | Writes primary + fans out to BOTH Teams + Z: mirrors; hard-stops if neither is available    | Raises `PermissionError` on writes to canonical OR Z: paths (unless `allow_canonical_write=True`) |
| `dw_use`              | Local-first; falls back to canonical when missing (v0.3.0 preserved)                       | Network-first: Teams → Z: → repo-local (with provenance `warning`) → hard-stop                    |
| `dw_resolve_path`     | Resolves via mode-aware roots                                                              | Resolves via mode-aware roots                                                                     |
| `dw_compare`          | Pure compute; no side effects                                                              | Pure compute; no side effects                                                                     |
| `dw_merge`            | Pure compute; no side effects                                                              | Pure compute; no side effects                                                                     |
| `dw_isid`             | Pure compute; no side effects                                                              | Pure compute; no side effects                                                                     |
| `dw_verify_z`         | Returns dict; no side effects                                                              | Returns dict; no side effects                                                                     |
| `dw_is_canonical`     | Returns bool; no side effects                                                              | Returns bool; no side effects                                                                     |
| `dw_toolkit_version`  | Returns `"0.4.0"` (the toolkit semver)                                                     | Returns `"0.4.0"` (the toolkit semver)                                                            |

## Extension dispatch

| Extension                   | Writer                              | Reader                          | Notes                                       |
| --------------------------- | ----------------------------------- | ------------------------------- | ------------------------------------------- |
| `.csv` / `.tsv` / `.txt`    | `pandas.DataFrame.to_csv`           | `pandas.read_csv`               | Defaults: `na_rep=""`, `index=False`        |
| `.csv.gz` / `.tsv.gz`       | `to_csv(compression="gzip")`        | `pandas.read_csv` (auto-detect) | Set `compress=True` to add `.gz` suffix     |
| `.xlsx`                     | `openpyxl` (`pd.ExcelWriter`)       | `pd.read_excel(engine="openpyxl")` | DF, dict-of-DF, or `openpyxl.Workbook`     |
| `.pkl` / `.pickle`          | `pickle.dump`                       | `pickle.load`                   | Python analogue of R's `.rds`               |
| `.dta`                      | `pandas.DataFrame.to_stata`         | `pandas.read_stata`             | For Stata interchange                       |
| `.parquet`                  | `pandas.DataFrame.to_parquet`       | `pandas.read_parquet`           | Requires `pyarrow`                          |
| `.json`                     | `json.dump` (DF: `to_json`)         | `json.load`                     | Pretty-printed; `default=str` fallback      |
| `.yml` / `.yaml`            | `yaml.safe_dump`                    | `yaml.safe_load`                | Requires `PyYAML`                           |

## Mode contract (v0.4.0 tightening)

`dw_save` raises `PermissionError` when ALL of the following are true:

1. The resolved write path lies under a canonical root (test via
   `dw_is_canonical(path)`) **OR** under the configured Z: drive root
   (`_state.dwZDrive`).
2. The session's `_state.dw_mode` is `"reviewer"`.
3. The caller did not pass `allow_canonical_write=True`.

The Z: branch is new in v0.4.0 — v0.3.0 only refused canonical writes.

`dw_save` ALSO raises `PermissionError` in **producer** mode when neither
the Teams canonical nor the Z: drive mirror is configured / reachable.
Producer outputs are redundant by design; the helper refuses to ship a
write that lives only on the producer's laptop.

`dw_save` raises `FileExistsError` (v0.4.0 default `overwrite=False`) if
ANY of primary / Teams mirror / Z: mirror already exists. Pass
`overwrite=True` to restore v0.3.0 behaviour.

The intent: reviewer sessions keep the canonical deposit read-only, so
vintage permanence is preserved. Reviewer writes go to the sandbox
(which the profile resolves the same path-globals to).

## Z: drive + Teams integration (v0.4.0)

Every successful producer `dw_save` fans out the primary file AND its
`.provenance.json` sidecar to two redundant mirrors:

* **Teams canonical** — derived from the `teams*Data -> teams*DataCanonical`
  prefix map. Skipped silently when the primary already lies under
  canonical (DBM bootstrap case).
* **Z: drive** — derived from the Teams canonical equivalent and the
  configured `_state.dwZDrive`. Skipped when `dw_z_available=False`.

Each mirror is non-blocking — failures emit envelope-shaped
`warnings.warn` and do not roll back the primary write.

`dw_use` reads also use both mirrors, with order driven by mode:

* **Producer / unknown mode** (v0.3.0 preserved) — local-first: try the
  literal path; fall back to canonical equivalent when missing.
* **Reviewer mode** — network-first: try Teams → Z: → repo-local
  (with provenance warning) → hard-stop. The local fallback warning is
  the auditable signal that the reviewer is reading a copy of unverified
  provenance.

The Z: integrity check (`dw_verify_z`) still runs on `dw_use` canonical
reads as in v0.3.0.

## Provenance sidecar

Every `dw_save` (except `.RData`) emits `<path>.provenance.json`:

```json
{
  "path": "...",
  "format": "csv",
  "written_at": "2026-05-25T14:23:11+0000",
  "user": "jpazvd",
  "dw_mode": "producer",
  "vintage": "2026-05",
  "sha256": "...",
  "isid": ["DATAFLOW", "REF_AREA", ...],
  "schema": {"rows": 12345, "cols": 8, "columns": [...]},
  "metadata": { "title": "...", "producer": "...", "sources": [...] }
}
```

`metadata` is merged from the user-supplied `metadata=` argument.

## Worked example

```python
from cso_toolkit import _state, dw_save, dw_use

_state.configure(
    teamsWrkData="/data/wrk",
    teamsRawData="/data/raw",
    teamsWrkDataCanonical="/data/wrk-canonical",
    teamsRawDataCanonical="/data/raw-canonical",
    dw_mode="producer",
    dw_apis_allowed=True,
)

import pandas as pd
df = pd.DataFrame({"REF_AREA": ["AGO", "BFA"], "OBS_VALUE": [0.5, 0.7]})

# Write — auto-dispatches on .csv, runs isid, writes provenance sidecar
path = dw_save(
    df,
    name="dw_ed_edu.csv", sector="ed", kind="wrk",
    isid=["REF_AREA"],
    metadata={
        "title": "Education indicators",
        "producer": "01_dw_prep/012_codes/ed/02_aggregate.py",
        "sources": ["UIS bulk SDG_092025"],
        "vintage": "2026-05",
    },
)

# Read back
df2 = dw_use(path)
```

## Error envelope

All errors raised by `dw_io` follow the three-part WHAT / WHY / HOW
shape:

```
[cso_toolkit.dw_save] Reviewer mode forbids writes under canonical: /path
  Reviewer sessions must keep canonical deposits read-only to preserve
  vintage permanence; writes go to the sandbox.
  Fix:
    1. Resolve a sandbox path instead ...
    2. If this is a deliberate Database Manager bootstrap, pass ...
```

The leading `[cso_toolkit.<func>]` prefix lets you `grep` the project
for sites that hit a given error class.

## Sector migration checklist

When porting a sector script from raw pandas IO to cso-toolkit:

1. Replace every `pd.read_csv` / `df.to_csv` / `pd.read_excel` /
   `df.to_excel` / `pickle.dump` / `pickle.load` with `dw_use` /
   `dw_save`.
2. Replace `df.merge(other, ...)` with `dw_merge(df, other, by=[...],
   how="m:1")` for joins that should have a cardinality assertion.
3. Add an `isid=[...]` argument to `dw_save` calls that produce
   warehouse-shaped outputs.
4. Add a `metadata={"title": ..., "producer": __file__, "sources":
   [...]}` argument to make the provenance sidecar self-describing.
5. Run `cso_toolkit.test_scripts(<sector_folder>, error_on_violation=True)`
   in CI to catch regressions.
