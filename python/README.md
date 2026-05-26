# python/ — cso-toolkit (Python)

Python implementation of the [cso-toolkit](../) IO + API + sync
contract. Same behaviour matrix as the [R](../r/) and
[Stata](../stata/) siblings.

## Package metadata

Defined in [`pyproject.toml`](pyproject.toml):

- **Name** — `cso-toolkit`
- **Version** — `0.2.1.dev0` (development; the next tagged release is
  `v0.3.0`)
- **Requires** — Python >= 3.9
- **License** — MIT
- **Type-hint coverage** — full; ships [`src/py.typed`](src/py.typed)
  per PEP 561 so type-checkers respect the annotations when consumers
  vendor the package.

## Installation

Vendoring is the **production model** (drop `python/src/` into a
consumer repo's `00_functions/cso_toolkit/`). `pip install -e` is
supported for development.

### Option A — vendor into a consumer repo (production)

Copy `python/src/` into the consumer's `00_functions/cso_toolkit/`, then:

```python
import sys
sys.path.insert(0, "00_functions")           # makes `cso_toolkit` importable
from cso_toolkit import dw_save, dw_use, dw_api_fetch
from cso_toolkit import _state as cso_state
```

Pin the version in `.toolkit_manifest.yml` alongside the helpers:

```yaml
source: "unicef-drp/cso-toolkit"
pulled_version: "v0.2.0"
pulled_date: "2026-05-25"
```

See [`templates/.toolkit_manifest.yml`](../templates/.toolkit_manifest.yml)
for the full schema and [`src/README.md`](src/README.md) for the
per-module catalogue.

### Option B — `pip install -e` (development)

```bash
pip install -e python/
# or with optional API libraries:
pip install -e "python/[all]"
```

Available extras: `excel` (openpyxl), `parquet` (pyarrow), `yaml`
(PyYAML), `http` (requests), `sdmx` (sdmx1), `worldbank` (wbgapi),
`test` (pytest), `all` (everything).

## Layout

```text
python/
├── pyproject.toml      # package metadata + optional-dep groups
├── src/
│   ├── README.md       # per-module catalogue (vendoring view)
│   ├── __init__.py     # re-exports 26 public entries; __version__
│   ├── py.typed        # PEP 561 marker
│   ├── _state.py       # session globals (configure / _get)
│   ├── dw_io.py        # IO contract
│   ├── dw_api.py       # cached external API (10 dispatch keys)
│   ├── cso_toolkit_sync.py
│   ├── aggregate_data.py
│   ├── dw_nestweight.py
│   ├── generate_markdown_report.py
│   ├── create_sector_script.py
│   ├── profile_helpers.py
│   └── test_scripts.py
└── tests/
    └── manual/
        ├── smoke_test.py             # 15 in-process invariants
        └── error_envelope_test.py    # 30 raise paths verified
```

## Quick start

```python
import pandas as pd
from cso_toolkit import _state as cso_state, dw_save, dw_use

# 1. Configure session state (normally done by profile_<repo>.py)
cso_state.configure(
    teamsWrkData="/path/to/wrk",
    teamsRawData="/path/to/raw",
    teamsWrkDataCanonical="/path/to/wrk-canonical",
    teamsRawDataCanonical="/path/to/raw-canonical",
    dw_mode="producer",
    dw_apis_allowed=True,
)

# 2. Use the contract
df = pd.DataFrame({"REF_AREA": ["AGO", "BFA"], "OBS_VALUE": [0.5, 0.7]})
out_path = dw_save(
    df,
    name="dw_ed_edu.csv", sector="ed", kind="wrk",
    isid=["REF_AREA"],
    metadata={
        "title": "Education indicators",
        "producer": "01_dw_prep/012_codes/ed/example.py",
        "sources": ["UIS bulk SDG_092025"],
        "vintage": "2026-05",
    },
)
# Writes the CSV + a sibling `.provenance.json` sidecar.

# 3. Read back
warehouse = dw_use(name="dw_ed_edu.csv", sector="ed", kind="wrk")
```

## Mode contract (Python side)

`dw_save` raises `PermissionError` when reviewer-session writes would
land under canonical, unless `allow_canonical_write=True` is passed.
`dw_api_fetch` similarly raises `PermissionError` when the cache is
missing and `_state.dw_apis_allowed` is `False`. The full contract is
documented in
[`docs/mode_contract_integration.md`](../docs/mode_contract_integration.md)
and [`docs/roles_and_workflow.md`](../docs/roles_and_workflow.md).

## Error envelope

Every raise emits the three-part **WHAT / Why / Fix** envelope:

```text
[cso_toolkit.dw_save] Reviewer mode forbids writes under canonical: /path
  Reviewer sessions must keep canonical deposits read-only to preserve
  vintage permanence; writes go to the sandbox.
  Fix:
    1. Resolve a sandbox path instead, OR
    2. If this is a deliberate DBM bootstrap, pass `allow_canonical_write=True`.
```

The leading `[cso_toolkit.<module.func>]` prefix is grep-friendly. HTTP
failures in `dw_api_fetch` are wrapped with URL + status + body
snippet so upstream-shape changes are debuggable; sensitive keys
(`token`, `headers`, `api_key`, `password`, …) in `fetch_args` are
redacted before they reach the `.provenance.json` sidecar.

## Testing

```bash
# In-process smoke test (15 invariants)
python python/tests/manual/smoke_test.py

# Error-envelope contract test (30 raise paths)
python python/tests/manual/error_envelope_test.py
```

Both are dependency-free in the read paths (no network, no R) — they
bootstrap the package under the name `cso_toolkit` in a tempdir and
exercise pure-function invariants.

## See also

- [Top-level README](../README.md) — overview, three-role contract,
  vendoring rationale, versioning.
- [NEWS.md / Changelog](../NEWS.md) — per-release notes
  (`v0.1.0-rc1` → `v0.2.0` → `v0.3.0` → `v0.4.0`).
- [`python/src/README.md`](src/README.md) — per-module catalogue (the
  vendoring view).
- [`docs/dw_io_python_reference.md`](../docs/dw_io_python_reference.md)
  — IO function reference.
- [`docs/dw_api_python_reference.md`](../docs/dw_api_python_reference.md)
  — API function reference.
- Sibling implementations of the same contract:
  - [`r/README.md`](../r/README.md) — R
  - [`stata/README.md`](../stata/README.md) — Stata
