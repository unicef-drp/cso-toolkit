"""``dw_api_fetch(api="csv")``: flat CSV at a URL.

Python mirror of the two ``csv`` tests in
``r/tests/testthat/test-dw_api.R``, plus the producer cache round trip
and the reviewer refusal.  No network: every "URL" is a local file.
"""

from __future__ import annotations

import warnings

import pandas as pd
import pytest

import cso_toolkit as m
from cso_toolkit import _state
from cso_toolkit import dw_api


def _set_state(monkeypatch, **values) -> None:
    for key, value in values.items():
        monkeypatch.setattr(_state, key, value, raising=False)


@pytest.fixture
def producer(tmp_path, monkeypatch):
    raw = tmp_path / "raw"
    raw.mkdir()
    _set_state(
        monkeypatch,
        teamsRawData=str(raw), teamsRawDataCanonical=str(raw),
        teamsWrkDataCanonical=str(raw), teamsFolderCanonical=None,
        dw_mode="producer", dw_apis_allowed=True,
        dw_z_available=False, dwZDrive=None,
    )
    return raw


def _fetch(**kw):
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", DeprecationWarning)
        return m.dw_api_fetch("csv", **kw)


def test_csv_is_a_supported_api():
    assert "csv" in dw_api._DISPATCH
    assert dw_api._dw_api_default_ext("csv") == "csv"


def test_dispatch_reaches_the_fetcher_not_the_unsupported_guard(producer):
    # Mirrors R: a missing file fails at the read, not at "Unsupported api".
    with pytest.raises(Exception) as err:
        _fetch(cache_key="csv_dispatch_probe",
               url=str(producer / "no-such-cso-toolkit-test-file.csv"))
    assert "Unsupported api" not in str(err.value)


def test_fetcher_parses_a_csv_source(tmp_path):
    src = tmp_path / "src.csv"
    src.write_text("a,b\n1,x\n2,y\n", encoding="utf-8")
    out = dw_api._fetch_csv(str(src))
    assert isinstance(out, pd.DataFrame)
    assert list(out.columns) == ["a", "b"]
    assert out["a"].tolist() == [1, 2]


def test_fetcher_passes_read_csv_options(tmp_path):
    src = tmp_path / "src.csv"
    src.write_text("a;b\n1;x\n", encoding="utf-8")
    out = dw_api._fetch_csv(str(src), sep=";")
    assert list(out.columns) == ["a", "b"]


def test_producer_caches_and_refresh_replaces(producer, tmp_path):
    src = tmp_path / "src.csv"
    src.write_text("a,b\n1,x\n", encoding="utf-8")
    assert _fetch(cache_key="k", url=str(src))["a"].tolist() == [1]
    cache = producer / "_apis" / "csv" / "k.csv"
    assert cache.exists()
    assert cache.with_name("k.csv.provenance.json").exists()
    src.write_text("a,b\n2,y\n", encoding="utf-8")
    # Without refresh the cache is a hit and is not replaced.
    assert _fetch(cache_key="k", url=str(src))["a"].tolist() == [1]
    assert _fetch(cache_key="k", url=str(src), refresh=True)["a"].tolist() == [2]


def test_reviewer_without_cache_refuses(tmp_path, monkeypatch):
    raw = tmp_path / "raw"
    raw.mkdir()
    _set_state(
        monkeypatch,
        teamsRawData=str(raw), teamsRawDataCanonical=str(raw),
        teamsWrkDataCanonical=str(raw), teamsFolderCanonical=None,
        dw_mode="reviewer", dw_apis_allowed=False,
        dw_z_available=False, dwZDrive=None,
    )
    src = tmp_path / "src.csv"
    src.write_text("a\n1\n", encoding="utf-8")
    with pytest.raises(PermissionError):
        _fetch(cache_key="k", url=str(src))
