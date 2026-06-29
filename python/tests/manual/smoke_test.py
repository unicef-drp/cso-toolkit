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
    # Clear lingering canonical state from the dw_is_canonical test
    # above so the v0.4.0 mirror logic doesn't try to fan out to a
    # synthetic path that persists across smoke-test runs.
    import pandas as pd
    with tempfile.TemporaryDirectory() as tdir:
        state.configure(
            teamsWrkData=tdir,
            teamsWrkDataCanonical=None,
            teamsRawDataCanonical=None,
            teamsFolderCanonical=None,
            dw_z_available=False,
        )
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

    # --- B2 regression: gzip auto-detect when path already ends in .gz
    with tempfile.TemporaryDirectory() as tdir:
        state.configure(teamsWrkData=tdir)
        df_gz = pd.DataFrame({"a": [1, 2, 3]})
        out = cso_toolkit.dw_save(
            df_gz, path=str(Path(tdir) / "auto_gz.csv.gz"),
        )
        assert Path(out).exists()
        # Read it back via gzip
        import gzip
        with gzip.open(out, "rt", encoding="utf-8") as fh:
            content = fh.read()
        assert "1\n2\n3" in content
        print("[dw_io] B2: gzip auto-detect when path ends .gz OK")

    # --- B3 regression: provenance sidecar failure warns, doesn't roll back
    with tempfile.TemporaryDirectory() as tdir:
        state.configure(teamsWrkData=tdir)
        # Pass a metadata value json.dump can't serialise even with
        # default=str only after str() — we use an explicitly-failing
        # object to make sure the warning path triggers.
        class _Unserialisable:
            def __str__(self_):
                raise TypeError("cannot stringify")
        bad_meta = {"weird": _Unserialisable()}
        import warnings as _warn
        with _warn.catch_warnings(record=True) as w:
            _warn.simplefilter("always")
            p = cso_toolkit.dw_save(
                pd.DataFrame({"a": [1, 2]}),
                path=str(Path(tdir) / "primary_survives.csv"),
                metadata=bad_meta,
            )
        # Primary file must exist regardless
        assert Path(p).exists()
        # The warning must be from cso_toolkit.dw_save
        assert any("cso_toolkit.dw_save" in str(m.message)
                   and "Provenance sidecar write failed" in str(m.message)
                   for m in w), f"expected sidecar-failure warning, got {[str(m.message) for m in w]}"
        print("[dw_io] B3: provenance failure warns; primary file preserved OK")

    # --- B4 regression: dw_api default extension for http/github_raw is pkl
    from cso_toolkit.dw_api import _dw_api_default_ext as _ext
    assert _ext("http") == "pkl"
    assert _ext("github_raw") == "pkl"
    assert _ext("wb_indicators") == "pkl"
    assert _ext("uis") == "csv"
    print("[dw_api] B4: http/github_raw default to pkl, others stay csv OK")

    # --- B1 regression: remote-URL freeze guards
    # No allowlist set => any URL refused
    state.configure(dw_url_allowlist=())
    try:
        cso_toolkit.dw_use("https://example.com/data.csv")
    except PermissionError as exc:
        assert "not in `dw_url_allowlist`" in str(exc)
        assert "Fix:" in str(exc)
    else:
        raise AssertionError("expected PermissionError on empty allowlist")
    print("[dw_io] B1: empty allowlist refuses any URL OK")

    # Allowlist set + reviewer mode + URL not yet frozen => refuse
    state.configure(
        dw_url_allowlist=(r"^https://example\.com/",),
        dw_mode="reviewer",
        dw_frozen_root=tempfile.mkdtemp(prefix="cso_frozen_"),
    )
    try:
        cso_toolkit.dw_use("https://example.com/data-not-yet-frozen.csv")
    except PermissionError as exc:
        assert "Reviewer mode forbids fetching" in str(exc)
        assert "Fix:" in str(exc)
    else:
        raise AssertionError("expected PermissionError in reviewer + unfrozen")
    print("[dw_io] B1: reviewer mode refuses unfrozen URL OK")

    # Reset mode for any subsequent checks
    state.configure(dw_mode="producer", dw_apis_allowed=True)

    # ===================================================================
    # v0.4.0 issue #14 — producer / reviewer mode contract regressions
    # ===================================================================

    # --- #14.0 dw_toolkit_version() stamp matches the package __version__
    assert cso_toolkit.dw_toolkit_version() == "0.5.1", (
        f"dw_toolkit_version() != 0.5.1 (got {cso_toolkit.dw_toolkit_version()!r})"
    )
    print("[#14] dw_toolkit_version() returns '0.5.1' OK")

    # --- #14.1 reviewer mode forbids canonical writes (v0.3.0 preserved)
    with tempfile.TemporaryDirectory() as tdir:
        canon = Path(tdir) / "canon"
        canon.mkdir(parents=True)
        state.configure(
            dw_mode="reviewer",
            teamsWrkDataCanonical=str(canon),
            teamsRawDataCanonical=str(canon),
            teamsFolderCanonical=str(canon),
            dwZDrive=None,
            dw_z_available=False,
        )
        df14 = pd.DataFrame({"a": [1, 2]})
        try:
            cso_toolkit.dw_save(df14, path=str(canon / "x.csv"))
        except PermissionError as exc:
            assert "cso_toolkit.dw_save" in str(exc)
            assert "Fix:" in str(exc)
        else:
            raise AssertionError(
                "expected PermissionError for reviewer canonical write"
            )
        print("[#14.1] reviewer canonical write -> PermissionError OK")

    # --- #14.2 reviewer mode forbids Z: drive writes (v0.4.0 broadened)
    with tempfile.TemporaryDirectory() as tdir:
        z_root = Path(tdir) / "z_drive"
        z_root.mkdir(parents=True)
        state.configure(
            dw_mode="reviewer",
            dwZDrive=str(z_root),
            dw_z_available=True,
        )
        try:
            cso_toolkit.dw_save(df14, path=str(z_root / "x.csv"))
        except PermissionError as exc:
            assert "Z:" in str(exc) or "cso_toolkit.dw_save" in str(exc)
        else:
            raise AssertionError(
                "expected PermissionError for reviewer Z: write"
            )
        print("[#14.2] reviewer Z: drive write -> PermissionError OK")

    # --- #14.3 producer mode hard-stops if neither Teams nor Z: configured
    with tempfile.TemporaryDirectory() as tdir:
        state.configure(
            dw_mode="producer",
            teamsWrkData=None,
            teamsRawData=None,
            teamsWrkDataCanonical=None,
            teamsRawDataCanonical=None,
            teamsFolderCanonical=None,
            dwZDrive=None,
            dw_z_available=False,
        )
        try:
            cso_toolkit.dw_save(df14, path=str(Path(tdir) / "isolated.csv"))
        except PermissionError as exc:
            assert "at least one of Teams" in str(exc)
            assert "Fix:" in str(exc)
        else:
            raise AssertionError(
                "expected PermissionError for producer with no mirrors"
            )
        print("[#14.3] producer hard-stop with no mirrors OK")

    # --- #14.4 producer mode writes to BOTH Teams + Z: when available
    with tempfile.TemporaryDirectory() as tdir:
        primary_root = Path(tdir) / "wrk-local"
        canon_root   = Path(tdir) / "wrk-canon"
        z_root       = Path(tdir) / "z_drive"
        for p in (primary_root, canon_root, z_root):
            p.mkdir(parents=True)
        state.configure(
            dw_mode="producer",
            teamsWrkData=str(primary_root),
            teamsWrkDataCanonical=str(canon_root),
            teamsFolderCanonical=str(canon_root),
            teamsRawData=None,
            teamsRawDataCanonical=None,
            dwZDrive=str(z_root),
            dw_z_available=True,
        )
        out = cso_toolkit.dw_save(
            pd.DataFrame({"REF_AREA": ["AGO", "BFA"], "v": [1, 2]}),
            path=str(primary_root / "sec/x.csv"),
            isid=["REF_AREA"],
        )
        assert Path(out).exists()
        teams_mirror = canon_root / "sec" / "x.csv"
        z_mirror = z_root / "sec" / "x.csv"
        assert teams_mirror.exists(), f"missing Teams mirror at {teams_mirror}"
        assert z_mirror.exists(), f"missing Z: mirror at {z_mirror}"
        # Each mirror got its own sidecar
        assert Path(str(teams_mirror) + ".provenance.json").exists()
        assert Path(str(z_mirror) + ".provenance.json").exists()
        print("[#14.4] producer fans out to Teams + Z: with sidecars OK")

    # --- #14.5 overwrite gate refuses if any destination exists
    with tempfile.TemporaryDirectory() as tdir:
        primary_root = Path(tdir) / "wrk-local"
        canon_root   = Path(tdir) / "wrk-canon"
        z_root       = Path(tdir) / "z_drive"
        for p in (primary_root, canon_root, z_root):
            p.mkdir(parents=True)
        state.configure(
            dw_mode="producer",
            teamsWrkData=str(primary_root),
            teamsWrkDataCanonical=str(canon_root),
            teamsFolderCanonical=str(canon_root),
            dwZDrive=str(z_root),
            dw_z_available=True,
        )
        primary = str(primary_root / "sec/x.csv")
        cso_toolkit.dw_save(
            pd.DataFrame({"REF_AREA": ["AGO"], "v": [1]}),
            path=primary, isid=["REF_AREA"],
        )
        try:
            cso_toolkit.dw_save(
                pd.DataFrame({"REF_AREA": ["AGO"], "v": [2]}),
                path=primary, isid=["REF_AREA"],
            )
        except FileExistsError as exc:
            assert "overwrite=False" in str(exc) or "overwrite" in str(exc)
        else:
            raise AssertionError("expected FileExistsError on second write")
        # overwrite=True succeeds
        out2 = cso_toolkit.dw_save(
            pd.DataFrame({"REF_AREA": ["AGO"], "v": [2]}),
            path=primary, isid=["REF_AREA"], overwrite=True,
        )
        assert Path(out2).exists()
        print("[#14.5] overwrite gate refuses + overwrite=True succeeds OK")

    # --- #14.6 reviewer-mode read is network-first: prefers Teams
    with tempfile.TemporaryDirectory() as tdir:
        primary_root = Path(tdir) / "wrk-local"
        canon_root   = Path(tdir) / "wrk-canon"
        (primary_root / "sec").mkdir(parents=True)
        (canon_root / "sec").mkdir(parents=True)
        (canon_root / "sec" / "x.csv").write_text(
            "REF_AREA,value\nAGO,42\n", encoding="utf-8"
        )
        (primary_root / "sec" / "x.csv").write_text(
            "REF_AREA,value\nAGO,99\n", encoding="utf-8"
        )
        state.configure(
            dw_mode="reviewer",
            teamsWrkData=str(primary_root),
            teamsWrkDataCanonical=str(canon_root),
            teamsFolderCanonical=str(canon_root),
            dwZDrive=None,
            dw_z_available=False,
        )
        df_read = cso_toolkit.dw_use(
            path=str(primary_root / "sec/x.csv"), verify_z=False
        )
        assert int(df_read["value"].iloc[0]) == 42, (
            f"reviewer read returned local copy (99) not Teams (42); "
            f"got {df_read.to_dict()}"
        )
        print("[#14.6] reviewer read prefers Teams canonical OK")

    # --- #14.7 reviewer-mode local fallback emits a provenance warning
    with tempfile.TemporaryDirectory() as tdir:
        primary_root = Path(tdir) / "wrk-local"
        canon_root   = Path(tdir) / "wrk-canon"
        (primary_root / "sec").mkdir(parents=True)
        canon_root.mkdir(parents=True)  # exists but EMPTY
        (primary_root / "sec" / "x.csv").write_text(
            "REF_AREA,value\nAGO,99\n", encoding="utf-8"
        )
        state.configure(
            dw_mode="reviewer",
            teamsWrkData=str(primary_root),
            teamsWrkDataCanonical=str(canon_root),
            teamsFolderCanonical=str(canon_root),
            dwZDrive=None,
            dw_z_available=False,
        )
        import warnings as _warn
        with _warn.catch_warnings(record=True) as w:
            _warn.simplefilter("always")
            df_fb = cso_toolkit.dw_use(
                path=str(primary_root / "sec/x.csv"), verify_z=False
            )
        assert int(df_fb["value"].iloc[0]) == 99
        assert any("cso_toolkit.dw_use" in str(m.message)
                   and ("provenance" in str(m.message)
                        or "local" in str(m.message))
                   for m in w), (
            f"expected reviewer local-fallback warning, got "
            f"{[str(m.message) for m in w]}"
        )
        print("[#14.7] reviewer local fallback warns about provenance OK")

    # --- #14.8 reviewer-mode hard-stop when file is missing everywhere
    with tempfile.TemporaryDirectory() as tdir:
        primary_root = Path(tdir) / "wrk-local"
        canon_root   = Path(tdir) / "wrk-canon"
        primary_root.mkdir(parents=True)
        canon_root.mkdir(parents=True)
        state.configure(
            dw_mode="reviewer",
            teamsWrkData=str(primary_root),
            teamsWrkDataCanonical=str(canon_root),
            teamsFolderCanonical=str(canon_root),
            dwZDrive=None,
            dw_z_available=False,
        )
        try:
            cso_toolkit.dw_use(
                path=str(primary_root / "missing.csv"), verify_z=False
            )
        except FileNotFoundError as exc:
            assert "cso_toolkit.dw_use" in str(exc)
            assert "Fix:" in str(exc)
        else:
            raise AssertionError(
                "expected FileNotFoundError when file missing everywhere"
            )
        print("[#14.8] reviewer file-missing-everywhere -> hard-stop OK")

    # Reset for any downstream checks (caller convention)
    state.configure(dw_mode="producer", dw_apis_allowed=True)

    print("\nAll smoke checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
