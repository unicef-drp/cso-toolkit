#!/usr/bin/env python3
# =====================================================================
# Cross-language conformance driver -- Python
# ---------------------------------------------------------------------
# Reads the shared fixture via dw_use(), round-trips it through
# dw_save() -> dw_use(), then writes a NORMALISED out_python.csv (fixed
# column order, rows sorted by the id keys). conformance/compare.py
# asserts out_r.csv == out_python.csv == out_stata.csv value-for-value.
#
# Usage: python conformance/run_python.py <fixture.csv> <out_python.csv>
# =====================================================================
from __future__ import annotations

import shutil
import sys
import tempfile
from pathlib import Path


def _bootstrap() -> None:
    """Make python/src importable as cso_toolkit (mirrors smoke_test.py)."""
    try:
        import cso_toolkit  # noqa: F401  (already installed)
        return
    except ImportError:
        pass
    repo_root = Path(__file__).resolve().parents[1]
    src = repo_root / "python" / "src"
    assert src.exists(), f"missing python/src at {src}"
    tmp = Path(tempfile.mkdtemp(prefix="cso_conf_pypkg_"))
    shutil.copytree(src, tmp / "cso_toolkit")
    sys.path.insert(0, str(tmp))


_bootstrap()

import cso_toolkit
from cso_toolkit import _state as state

KEYS = ["REF_AREA", "INDICATOR", "SEX", "AGE", "TIME_PERIOD"]

fixture = str(Path(sys.argv[1] if len(sys.argv) > 1
                   else "conformance/fixtures/indicators.csv").resolve())
outfile = sys.argv[2] if len(sys.argv) > 2 else "out_python.csv"

# Minimal state: a writable "Teams" root; canonical/Z: cleared so the mirror
# logic doesn't fan out. No dw_mode -> plain local write (mirrors run_r.R).
wrk = tempfile.mkdtemp(prefix="cso_conf_py_wrk_")
state.configure(
    teamsWrkData=wrk,
    teamsWrkDataCanonical=None,
    teamsRawDataCanonical=None,
    teamsFolderCanonical=None,
    dw_z_available=False,
)

in_df = cso_toolkit.dw_use(fixture)
out = cso_toolkit.dw_save(
    in_df, name="conformance_rt.csv", sector="conf", kind="wrk",
    isid=KEYS, provenance=False,
)
rt = cso_toolkit.dw_use(out)
rt = rt[KEYS + ["OBS_VALUE"]].sort_values(KEYS, kind="stable").reset_index(drop=True)
rt.to_csv(outfile, index=False)
print(f"[run_py] wrote {len(rt)} rows to {outfile}")
