"""Tests for ``aggregate_data_v2(method="total")``.

Python mirror of ``r/tests/testthat/test-aggregate-data-v2-total.R``.
``"total"`` returns an additive count or stock total (``sum(value)``) for
person-count indicators, unlike ``"sum"``, which returns a
population-weighted rate.

Run with::

    pytest python/tests/test_aggregate_total.py
"""

from __future__ import annotations

import shutil
import sys
import tempfile
from pathlib import Path

import pandas as pd
import pytest


def _bootstrap_package() -> None:
    """Make ``python/src/`` importable under the name ``cso_toolkit``."""
    try:
        import cso_toolkit  # noqa: F401
        return
    except ImportError:
        pass
    repo_root = Path(__file__).resolve().parents[2]
    src = repo_root / "python" / "src"
    tmpdir = Path(tempfile.mkdtemp(prefix="cso_toolkit_pytest_"))
    pkg_dir = tmpdir / "cso_toolkit"
    shutil.copytree(src, pkg_dir)
    sys.path.insert(0, str(tmpdir))


_bootstrap_package()

from cso_toolkit import aggregate_data_v2  # noqa: E402


def _agg(out: pd.DataFrame, code: str) -> float:
    return float(out.loc[out["Region_Code"] == code, "Aggregate"].iloc[0])


def test_total_sums_values_per_group_and_global() -> None:
    df = pd.DataFrame({
        "REF_AREA": ["AAA", "BBB", "CCC", "DDD"],
        "Region_Code": ["R1", "R1", "R2", "R2"],
        "value": [100, 200, 50, 25],
        "weight": [10, 20, 5, 5],
    })
    out = aggregate_data_v2(df, value="value", weight="weight",
                            by=["Region_Code"], method="total",
                            global_=True, global_label="WORLD")
    assert _agg(out, "R1") == 300    # 100 + 200
    assert _agg(out, "R2") == 75     # 50 + 25
    assert _agg(out, "WORLD") == 375  # grand total


def test_total_ignores_the_weight_scale() -> None:
    df = pd.DataFrame({
        "REF_AREA": ["AAA", "BBB"],
        "Region_Code": ["R1", "R1"],
        "value": [40, 60],
        "weight": [1, 1000],
    })
    out = aggregate_data_v2(df, value="value", weight="weight",
                            by=["Region_Code"], method="total", global_=False)
    assert _agg(out, "R1") == 100


def test_sum_still_returns_the_weighted_rate() -> None:
    df = pd.DataFrame({
        "REF_AREA": ["AAA", "BBB"],
        "Region_Code": ["R1", "R1"],
        "value": [50, 50],
        "weight": [10, 30],
    })
    out = aggregate_data_v2(df, value="value", weight="weight",
                            by=["Region_Code"], method="sum", global_=False)
    # (50 + 50) / (10 + 30) * 100 = 250
    assert _agg(out, "R1") == 250


def test_total_drops_missing_values() -> None:
    df = pd.DataFrame({
        "REF_AREA": ["AAA", "BBB", "CCC"],
        "Region_Code": ["R1", "R1", "R1"],
        "value": [100, None, 200],
        "weight": [10, 10, 10],
    })
    out = aggregate_data_v2(df, value="value", weight="weight",
                            by=["Region_Code"], method="total", global_=False)
    assert _agg(out, "R1") == 300


def test_total_of_a_group_with_no_values_is_zero() -> None:
    # R's sum(na.rm = TRUE) of all-NA is 0, and so is pandas' default sum.
    df = pd.DataFrame({
        "REF_AREA": ["AAA", "BBB", "CCC"],
        "Region_Code": ["R1", "R1", "R2"],
        "value": [None, None, 5],
        "weight": [10, 10, 10],
    })
    out = aggregate_data_v2(df, value="value", weight="weight",
                            by=["Region_Code"], method="total", global_=False)
    assert _agg(out, "R1") == 0
    assert _agg(out, "R2") == 5


def test_total_respects_the_coverage_threshold() -> None:
    # R1 has values for 10 of 40 weight units (25% coverage), below 0.5.
    df = pd.DataFrame({
        "REF_AREA": ["AAA", "BBB", "CCC"],
        "Region_Code": ["R1", "R1", "R2"],
        "value": [7, None, 5],
        "weight": [10, 30, 10],
    })
    out = aggregate_data_v2(df, value="value", weight="weight",
                            by=["Region_Code"], method="total",
                            global_=False, coverage_threshold=0.5)
    assert pd.isna(_agg(out, "R1"))
    assert _agg(out, "R2") == 5


def test_unknown_method_names_total_in_the_message() -> None:
    df = pd.DataFrame({"Region_Code": ["R1"], "value": [1], "weight": [1]})
    with pytest.raises(ValueError, match="total"):
        aggregate_data_v2(df, value="value", weight="weight",
                          by=["Region_Code"], method="count")
