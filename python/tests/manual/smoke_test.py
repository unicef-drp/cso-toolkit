"""Smoke test for the cso-toolkit Python port.

Loads the package as ``cso_toolkit`` from ``python/src/`` (via a tempdir
symlink alias so the package can use relative imports), then exercises
the pure functions that have no external dependencies.

Usage::

    python python/tests/manual/smoke_test.py
"""

from __future__ import annotations

import os
import shutil
import sys
import tempfile
from pathlib import Path


def _bootstrap_package() -> None:
    """Make ``python/src/`` importable under the name ``cso_toolkit``."""
    repo_root = Path(__file__).resolve().parents[3]
    src = repo_root / "python" / "src"
    assert src.exists(), f"missing python/src at {src}"
    tmpdir = Path(tempfile.mkdtemp(prefix="cso_toolkit_smoke_"))
    pkg_dir = tmpdir / "cso_toolkit"
    shutil.copytree(src, pkg_dir)
    sys.path.insert(0, str(tmpdir))
    print(f"[bootstrap] copied {src} -> {pkg_dir}")


def main() -> int:
    _bootstrap_package()
    import cso_toolkit
    print(f"[import] cso_toolkit v{cso_toolkit.__version__} OK")
    print(f"[import] __all__ has {len(cso_toolkit.__all__)} entries")

    # --- _state ---
    from cso_toolkit import _state as state
    state.configure(dw_mode="reviewer", dw_apis_allowed=False)
    assert state.dw_mode == "reviewer"
    assert state._get("dw_mode") == "reviewer"
    assert state._get("nonexistent_key") is None
    try:
        state.configure(unknown_key=1)
    except AttributeError:
        pass
    else:
        raise AssertionError("_state.configure should reject unknown keys")
    print("[_state] configure / _get / typo-protection OK")

    # --- dw_io: dw_resolve_path / dw_is_canonical (no IO needed) ---
    state.configure(teamsWrkData="/tmp/wrk")
    p = cso_toolkit.dw_resolve_path(name="x.csv", sector="ed", kind="wrk")
    assert p.endswith("/wrk/ed/x.csv"), f"unexpected resolved path: {p}"
    state.configure(teamsWrkDataCanonical="/tmp/wrk-can")
    assert cso_toolkit.dw_is_canonical("/tmp/wrk-can/ed/x.csv")
    assert not cso_toolkit.dw_is_canonical("/tmp/random/path")
    print("[dw_io] dw_resolve_path / dw_is_canonical OK")

    # --- dw_io: roundtrip CSV via dw_save / dw_use ---
    import pandas as pd
    with tempfile.TemporaryDirectory() as tdir:
        state.configure(teamsWrkData=tdir)
        df = pd.DataFrame({"a": [1, 2, 3], "b": ["x", "y", "z"]})
        out_path = cso_toolkit.dw_save(
            df, name="roundtrip.csv", sector="t", kind="wrk",
            isid=["a"],
            metadata={"title": "smoke test", "vintage": "2026-05"},
        )
        assert Path(out_path).exists()
        assert Path(out_path + ".provenance.json").exists()
        loaded = cso_toolkit.dw_use(out_path)
        assert list(loaded.columns) == ["a", "b"]
        assert len(loaded) == 3
        print("[dw_io] dw_save -> dw_use roundtrip + provenance sidecar OK")

        # dw_isid catches duplicates
        bad = pd.DataFrame({"a": [1, 1, 2], "b": ["x", "y", "z"]})
        try:
            cso_toolkit.dw_save(bad, name="bad.csv", sector="t", kind="wrk",
                                isid=["a"])
        except ValueError as exc:
            assert "duplicate" in str(exc)
            print("[dw_io] dw_isid catches duplicates OK")
        else:
            raise AssertionError("dw_isid should have rejected duplicates")

    # --- aggregate_data ---
    df = pd.DataFrame({
        "REF_AREA": ["A", "A", "B", "B", "C"],
        "SEX": ["F", "M", "F", "M", "F"],
        "value": [10.0, 20.0, 30.0, None, 50.0],
        "weight": [1.0, 1.0, 2.0, 2.0, 3.0],
    })
    agg = cso_toolkit.aggregate_data_v2(
        df, value="value", weight="weight", by=["SEX"],
        method="weighted_mean", coverage_threshold=0.5,
    )
    assert "Aggregate" in agg.columns
    assert "Pop_Covered" in agg.columns
    print(f"[aggregate_data] aggregate_data_v2 OK ({len(agg)} rows)")

    footnote = cso_toolkit.generate_agg_footnote(
        country_coverage=3, total_countries=5, pop_coverage=0.75,
        start_year=2020, end_year=2025,
    )
    assert "3/5 countries" in footnote
    assert "75 %" in footnote
    print(f"[aggregate_data] generate_agg_footnote OK ({footnote!r})")

    # --- dw_nestweight ---
    dhs = pd.DataFrame({
        "stratum": ["A", "A", "A", "B", "B"],
        "stunting": [1.0, None, 0.0, 1.0, None],
        "hh_weight": [10.0, 20.0, 30.0, 40.0, 60.0],
    })
    adj = cso_toolkit.dw_nestweight(
        dhs, value="stunting", by="stratum", weight="hh_weight",
        verbose=False,
    )
    # Stratum totals should be preserved
    orig_sum = dhs.groupby("stratum")["hh_weight"].sum()
    adj_sum = adj.groupby("stratum")["weight_adj"].sum()
    for k in orig_sum.index:
        assert abs(orig_sum[k] - adj_sum[k]) < 1e-9, (
            f"stratum {k}: {orig_sum[k]} != {adj_sum[k]}"
        )
    print("[dw_nestweight] preserves stratum totals OK")

    # --- create_sector_script / profile_helpers / test_scripts ---
    with tempfile.TemporaryDirectory() as tdir:
        sp = cso_toolkit.create_sector_script(
            sector_name="WASH", sector_code="ws", base_dir=tdir,
        )
        assert Path(sp).exists()
        assert Path(sp).read_text(encoding="utf-8").startswith('"""\nWASH Run Script')
        print(f"[create_sector_script] wrote {Path(sp).name} OK")

        pp = cso_toolkit.create_profile(
            "Test-Project", project_title="Test Project",
            output_path=tdir, overwrite=True,
        )
        review = cso_toolkit.review_profile(pp, verbose=False)
        n_fail = (review["status"] == "fail").sum()
        n_pass = (review["status"] == "pass").sum()
        print(
            f"[profile_helpers] create_profile + review_profile OK "
            f"({n_pass} pass, {n_fail} fail)"
        )
        assert n_fail == 0, "Generated profile should pass all required checks"

        # test_scripts on a clean file -> no violations
        clean = Path(tdir) / "clean.py"
        clean.write_text(
            "from cso_toolkit import dw_save, dw_api_fetch\n"
            "df = dw_save({}, name='x.csv', sector='t', kind='wrk')\n",
            encoding="utf-8",
        )
        violations = cso_toolkit.test_scripts(clean, verbose=False)
        assert len(violations) == 0
        print("[test_scripts] clean file has no violations OK")

        # test_scripts on a violating file -> catches read_csv
        bad = Path(tdir) / "bad.py"
        bad.write_text(
            "import pandas as pd\n"
            "df = pd.read_csv('foo.csv')\n",
            encoding="utf-8",
        )
        violations = cso_toolkit.test_scripts(bad, verbose=False)
        assert len(violations) == 1
        assert violations.iloc[0]["rule"] == "io-read-csv"
        print("[test_scripts] catches direct pd.read_csv OK")

    # --- cso_toolkit_sync (without a manifest) ---
    state.configure(dw_apis_allowed=True, dwFunct="/nonexistent/path")
    res = cso_toolkit.cso_toolkit_check(quiet=True)
    assert res is None  # no manifest -> None
    print("[cso_toolkit_sync] check with missing manifest -> None OK")

    # --- Regression: dw_is_canonical no longer matches sibling prefixes.
    #     Copilot finding on PR #7: a root of "/data/wrk-can" must NOT
    #     match a path under "/data/wrk-canary/...".
    state.configure(teamsWrkDataCanonical="/data/wrk-can")
    assert cso_toolkit.dw_is_canonical("/data/wrk-can/ed/x.csv")
    assert cso_toolkit.dw_is_canonical("/data/wrk-can")
    assert not cso_toolkit.dw_is_canonical("/data/wrk-canary/ed/x.csv")
    assert not cso_toolkit.dw_is_canonical("/data/wrk-canopen")
    print("[dw_io] dw_is_canonical no longer matches sibling prefixes OK")

    # --- Regression: dw_api fetch_args secrets are redacted in provenance.
    #     Copilot finding on PR #7.
    from cso_toolkit import dw_api as _dwapi
    redacted = _dwapi._redact_sensitive({
        "indicator": "SE.LPV.PRIM",
        "token": "abc123",
        "headers": {"Authorization": "Bearer XYZ"},
        "nested": {"api_key": "leaky"},
    })
    assert redacted["indicator"] == "SE.LPV.PRIM"
    assert redacted["token"] == "<redacted>"
    assert redacted["headers"] == "<redacted>"
    assert redacted["nested"]["api_key"] == "<redacted>"
    print("[dw_api] _redact_sensitive scrubs token/headers/api_key OK")

    # --- Regression: _get returns falsy values as-is (only None falls
    #     back to the default).  Copilot finding on PR #7.
    state.configure(dw_apis_allowed=False)
    assert state._get("dw_apis_allowed", True) is False
    state.configure(dw_apis_allowed=True)
    assert state._get("dw_apis_allowed", False) is True
    print("[_state] _get treats None (not falsy) as the default trigger OK")

    print("\nAll smoke checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
