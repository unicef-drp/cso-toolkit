"""dw_api_fetch(refresh=True) replaces an existing cache (producer mode).

Before the fix the refresh reached dw_save() with the default
``overwrite=False`` and stopped with FileExistsError, so the documented
refresh never replaced an existing cache.  Mirrors the R test in
``r/tests/testthat/test-dw_api.R``.
"""

from __future__ import annotations

import warnings

import pandas as pd
import pytest

import cso_toolkit as m
from cso_toolkit import _state
from cso_toolkit import dw_api


@pytest.fixture
def producer_raw(tmp_path, monkeypatch):
    raw = tmp_path / "raw"
    raw.mkdir()
    for key, value in {
        "teamsRawData": str(raw), "teamsRawDataCanonical": str(raw),
        "teamsWrkDataCanonical": str(raw), "teamsFolderCanonical": None,
        "dw_mode": "producer", "dw_apis_allowed": True,
        "dw_z_available": False, "dwZDrive": None,
    }.items():
        monkeypatch.setattr(_state, key, value, raising=False)
    calls = {"n": 0}

    def fake_fetch(**kwargs):
        calls["n"] += 1
        return pd.DataFrame({"a": [calls["n"]], "b": ["x"]})

    monkeypatch.setitem(dw_api._DISPATCH, "fake", fake_fetch)
    return raw


def _fetch(**kw):
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", DeprecationWarning)
        return m.dw_api_fetch("fake", cache_key="k", **kw)


def test_refresh_replaces_existing_cache(producer_raw):
    first = _fetch()
    assert first["a"].tolist() == [1]
    # Without refresh the existing cache is a hit: never replaced.
    assert _fetch()["a"].tolist() == [1]
    out = _fetch(refresh=True)
    assert out["a"].tolist() == [2]
    reread = m.dw_use(str(producer_raw / "_apis" / "fake" / "k.csv"))
    assert reread["a"].tolist() == [2]
