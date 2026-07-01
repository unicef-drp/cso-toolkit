"""Regression tests for ``dw_pop`` (#17).

Python mirror of ``r/tests/testthat/test-dw_pop.R``.

Strategy: drop a fixture CSV at the cache path the helper looks up, then
exercise the latest-year, year-filter, and country-filter branches
without hitting the network.

Run with::

    pytest python/tests/test_dw_pop.py
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

from cso_toolkit import _state, dw_pop  # noqa: E402


def _fixture() -> pd.DataFrame:
    """Three countries x three years, plus one NA-value bogus row so the
    complete-case filter is exercised."""
    return pd.DataFrame({
        "iso3c": ["BFA", "BFA", "BFA",
                  "MLI", "MLI", "MLI",
                  "NER", "NER", "NER",
                  "XXX"],
        "country": ["Burkina Faso", "Burkina Faso", "Burkina Faso",
                    "Mali", "Mali", "Mali",
                    "Niger", "Niger", "Niger",
                    "Bogus"],
        "date": [2021, 2022, 2023,
                 2021, 2022, 2023,
                 2021, 2022, 2023,
                 2023],
        "value": [22.1e6, 22.6e6, 23.2e6,
                  21.9e6, 22.6e6, 23.3e6,
                  25.1e6, 26.2e6, 27.2e6,
                  float("nan")],
    })


@pytest.fixture()
def cached_state(tmp_path: Path):
    """Drop the fixture CSV at the WB cache path and configure state."""
    cache_dir = tmp_path / "_apis" / "wb"
    cache_dir.mkdir(parents=True)
    _fixture().to_csv(cache_dir / "wb_population_sp_pop_totl.csv", index=False)
    _state.configure(
        teamsRawData=str(tmp_path),
        teamsRawDataCanonical=str(tmp_path),
        dw_apis_allowed=False,
    )
    yield tmp_path


def test_latest_year_per_country(cached_state):
    out = dw_pop(verbose=False)
    assert list(out.columns) == ["REF_AREA", "TIME_PERIOD", "OBS_VALUE"]
    # Three countries with valid rows; bogus XXX has NA OBS_VALUE -> dropped.
    assert len(out) == 3
    assert (out["TIME_PERIOD"] == 2023).all()
    assert set(out["REF_AREA"]) == {"BFA", "MLI", "NER"}


def test_year_filter(cached_state):
    out = dw_pop(year=2022, verbose=False)
    assert len(out) == 3
    assert (out["TIME_PERIOD"] == 2022).all()


def test_countries_filter(cached_state):
    out = dw_pop(countries=["BFA", "MLI"], verbose=False)
    assert set(out["REF_AREA"]) == {"BFA", "MLI"}


def test_scalar_country_filter(cached_state):
    out = dw_pop(countries="NER", verbose=False)
    assert set(out["REF_AREA"]) == {"NER"}


def test_sorted_by_ref_area_then_time(cached_state):
    out = dw_pop(year=[2021, 2022, 2023], verbose=False)
    # 3 countries x 3 years = 9 rows.
    assert len(out) == 9
    assert list(out["REF_AREA"]) == sorted(out["REF_AREA"])


def test_reviewer_mode_empty_cache_raises(tmp_path):
    _state.configure(
        teamsRawData=str(tmp_path),
        teamsRawDataCanonical=str(tmp_path),
        dw_apis_allowed=False,
        dw_mode="reviewer",
    )
    with pytest.raises(PermissionError):
        dw_pop(cache_key="never_cached_pop_key", verbose=False)
