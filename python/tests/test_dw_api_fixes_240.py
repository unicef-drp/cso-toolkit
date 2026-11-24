"""Fixes for #240: timeout, the reviewer reason, sdmx version, the wb cache
shape, and the dw_nestweight weight check."""

from __future__ import annotations

import types
import warnings
from pathlib import Path

import pandas as pd
import pytest

import cso_toolkit as m
from cso_toolkit import _state
from cso_toolkit import dw_api


def _set(monkeypatch, **values):
    for k, v in values.items():
        monkeypatch.setattr(_state, k, v, raising=False)


# ---- 1. timeout reaches the HTTP call ------------------------------------

def test_fetchers_take_a_timeout(monkeypatch):
    seen = []

    class Resp:
        text = "a\n1\n"

        def json(self):
            return {"ok": True}

    def fake_call(method, url, **kw):
        seen.append(kw.get("timeout"))
        return Resp()

    monkeypatch.setattr(dw_api, "_http_call", fake_call)
    dw_api._fetch_json_get("https://example.org/a.json")
    dw_api._fetch_json_get("https://example.org/a.json", timeout=5)
    dw_api._fetch_http("https://example.org/a.txt", timeout=7)
    out = dw_api._fetch_csv("https://example.org/a.csv", timeout=9)
    assert seen == [120, 5, 7, 9]
    assert out["a"].tolist() == [1]            # timeout did not reach read_csv


def test_timeout_passes_through_dw_api_fetch(tmp_path, monkeypatch):
    seen = []

    class Resp:
        def json(self):
            return {"ok": True}

    monkeypatch.setattr(dw_api, "_http_call",
                        lambda method, url, **kw: (seen.append(kw.get("timeout")), Resp())[1])
    _set(monkeypatch, teamsRawData=str(tmp_path), teamsRawDataCanonical=str(tmp_path),
         teamsWrkDataCanonical=str(tmp_path), teamsFolderCanonical=None,
         dw_mode="producer", dw_apis_allowed=True, dw_z_available=False, dwZDrive=None)
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", DeprecationWarning)
        m.dw_api_fetch("json_get", cache_key="k", url="https://example.org/a.json", timeout=30)
    assert seen == [30]


# ---- 2. the reviewer stop says why ---------------------------------------

def test_reviewer_refresh_with_a_cache_says_refresh(tmp_path, monkeypatch):
    cache = tmp_path / "_apis" / "csv"
    cache.mkdir(parents=True)
    (cache / "k.csv").write_text("a\n1\n", encoding="utf-8")
    _set(monkeypatch, teamsRawData=str(tmp_path), teamsRawDataCanonical=str(tmp_path),
         dw_mode="reviewer", dw_apis_allowed=False)
    with pytest.raises(PermissionError, match="refresh requested"):
        m.dw_api_fetch("csv", cache_key="k", url="x.csv", refresh=True)
    with pytest.raises(PermissionError, match="cache missing"):
        m.dw_api_fetch("csv", cache_key="other", url="x.csv")


# ---- 3. sdmx version is not dropped silently -----------------------------

def _fake_sdmx(calls):
    class Client:
        def __init__(self, provider):
            calls.append(("client", provider))

        def data(self, flow, key=None, params=None):
            calls.append(("data", flow, key))
            return "msg"

    return types.SimpleNamespace(Client=Client, to_pandas=lambda msg: pd.DataFrame({"x": [1]}))


def test_sdmx_version_without_flowref_version_warns(monkeypatch):
    calls = []
    monkeypatch.setattr(dw_api, "_require", lambda *a, **k: _fake_sdmx(calls))
    with pytest.warns(UserWarning, match="AGENCY,FLOW,VERSION"):
        dw_api._fetch_sdmx("ILO", "DF_X", key="BRA", version="1.1")
    with warnings.catch_warnings():
        warnings.simplefilter("error")
        dw_api._fetch_sdmx("ILO", "DF_X", key="BRA")
        dw_api._fetch_sdmx("ILO", "ILO,DF_X,1.1", key="BRA", version="1.1")
    assert ("data", "ILO,DF_X,1.1", "BRA") in calls


# ---- 4. a Python wb cache has the long wbstats layout --------------------

def _fake_wbgapi(asked):
    """Returns what wbgapi 1.0.14 returned for SP.POP.TOTL, AGO and BRA,
    2021-2022 (recorded 2026-11-24): the wide frame by default, the long
    frame with columns="series"."""
    wide = pd.DataFrame({"Country": ["Brazil", "Angola"],
                         "YR2021": [209550294.0, 34532429.0],
                         "YR2022": [210306415.0, 35635029.0]},
                        index=pd.Index(["BRA", "AGO"], name="economy"))
    long = pd.DataFrame({"Country": ["Brazil", "Brazil", "Angola", "Angola"],
                         "Time": [2022, 2021, 2022, 2021],
                         "SP.POP.TOTL": [210306415.0, 209550294.0, 35635029.0, 34532429.0]},
                        index=pd.MultiIndex.from_tuples(
                            [("BRA", "YR2022"), ("BRA", "YR2021"), ("AGO", "YR2022"), ("AGO", "YR2021")],
                            names=["economy", "time"]))

    def DataFrame(series, time=None, labels=False, columns=None, **_):
        asked.append(columns)
        return long if columns == "series" else wide

    return types.SimpleNamespace(data=types.SimpleNamespace(DataFrame=DataFrame))


def test_wb_fetch_returns_the_wbstats_layout(monkeypatch):
    asked = []
    monkeypatch.setattr(dw_api, "_require", lambda *a, **k: _fake_wbgapi(asked))
    out = dw_api._fetch_wb("SP.POP.TOTL", start_date=2021, end_date=2022)
    assert asked == ["series"]
    assert list(out.columns) == ["iso3c", "country", "date", "SP.POP.TOTL"]
    assert out["iso3c"].tolist() == ["AGO", "AGO", "BRA", "BRA"]
    assert out["date"].tolist() == [2021, 2022, 2021, 2022]


def test_dw_pop_reads_a_cache_python_wrote(tmp_path, monkeypatch):
    asked = []
    monkeypatch.setattr(dw_api, "_require", lambda *a, **k: _fake_wbgapi(asked))
    frame = dw_api._fetch_wb("SP.POP.TOTL", start_date=2021, end_date=2022)
    cache = tmp_path / "_apis" / "wb"
    cache.mkdir(parents=True)
    frame.to_csv(cache / "wb_population_sp_pop_totl.csv", index=False)
    _set(monkeypatch, teamsRawData=str(tmp_path), teamsRawDataCanonical=str(tmp_path),
         dw_apis_allowed=False)
    out = m.dw_pop(verbose=False)
    assert list(out.columns) == ["REF_AREA", "TIME_PERIOD", "OBS_VALUE"]
    assert set(out["REF_AREA"]) == {"AGO", "BRA"}
    assert (out["TIME_PERIOD"] == 2022).all()


# ---- 5. dw_nestweight refuses a non-numeric weight -----------------------

def test_nestweight_refuses_a_text_weight():
    df = pd.DataFrame({"y": [1.0, None, 3.0], "s": ["a", "a", "b"], "w": ["1", "2", "x"]})
    with pytest.raises(TypeError, match="is not numeric"):
        m.dw_nestweight(df, value="y", by="s", weight="w")
