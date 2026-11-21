"""dw_compare(diagnose=True) / dw_diff_profile() and the same-file guard (#111).
Mirror of r/tests/testthat/test-dw_compare-diagnose.R."""
from __future__ import annotations

import pandas as pd
import pytest

import cso_toolkit as m
from cso_toolkit import _state

REF = pd.DataFrame({"REF_AREA": ["AAA", "BBB", "CCC", "DDD", "EEE", "R1"], "TIME_PERIOD": [2020] * 6,
                    "OBS_VALUE": [10, 20, 30, 40, 50, 100], "POP": [1, 2, 3, 4, 5, 6]})
CUR = pd.DataFrame({"REF_AREA": ["AAA", "BBB", "CCC", "DDD", "R1", "FFF"], "TIME_PERIOD": [2020] * 6,
                    "OBS_VALUE": [10, 22, 33, 40, 110, 60], "POP": [1, 2, 3, 9, 6, 7]})
KEYS = ["REF_AREA", "TIME_PERIOD"]


@pytest.fixture(autouse=True)
def plain(monkeypatch):
    for k, v in (("dw_mode", None), ("teamsWrkData", None), ("teamsWrkDataCanonical", None),
                 ("teamsRawDataCanonical", None), ("teamsFolderCanonical", None),
                 ("dw_z_available", False)):
        monkeypatch.setattr(_state, k, v, raising=False)


def test_profile_columns_drift_keys(capsys):
    r = m.dw_compare(CUR, REF, by=KEYS, numeric_value_cols=["OBS_VALUE", "POP"], diagnose=True)
    p = r["profile"]
    assert p["columns"]["column"].tolist() == ["OBS_VALUE", "POP"]
    assert p["columns"]["n_changed"].tolist() == [3, 1]
    ob = p["magnitude"].set_index("column").loc["OBS_VALUE"]
    assert ob["rel_q50"] == pytest.approx(0.1) and ob["abs_max"] == pytest.approx(10)
    assert sorted(p["keys"].loc[p["keys"]["key"] == "REF_AREA", "value"]) == ["BBB", "CCC", "DDD", "R1"]
    assert p["added"].loc[p["added"]["key"] == "REF_AREA", "value"].tolist() == ["FFF"]
    assert p["removed"].loc[p["removed"]["key"] == "REF_AREA", "value"].tolist() == ["EEE"]
    assert "  diff columns: OBS_VALUE(3) POP(1)" in p["text"]
    assert any("rel: 0.1 / 0.1 / 0.1 / 0.1" in t for t in p["text"])
    assert "profile:" in capsys.readouterr().out


def test_without_diagnose_the_keys_are_unchanged():
    r = m.dw_compare(CUR, REF, by=KEYS)
    assert list(r) == ["summary", "added", "removed", "changed"]


def test_no_difference_empty_profile():
    r = m.dw_compare(REF, REF, by=KEYS, numeric_value_cols=["OBS_VALUE"], diagnose=True)
    assert len(r["profile"]["columns"]) == 0 and r["profile"]["text"] == []


def test_report_writes_profile(tmp_path):
    m.dw_compare(CUR, REF, by=KEYS, numeric_value_cols=["OBS_VALUE"], diagnose=True, label="t",
                 write_report_to=tmp_path)
    assert (tmp_path / "t_profile.txt").read_text(encoding="utf-8").startswith("  diff columns")


def test_reviewer_remap_to_the_same_file_stops(tmp_path, monkeypatch):
    sandbox, canon = tmp_path / "sandbox", tmp_path / "canon"
    sandbox.mkdir()
    canon.mkdir()
    CUR.to_csv(sandbox / "x.csv", index=False)
    REF.to_csv(canon / "x.csv", index=False)
    monkeypatch.setattr(_state, "dw_mode", "reviewer", raising=False)
    monkeypatch.setattr(_state, "teamsWrkData", str(sandbox), raising=False)
    monkeypatch.setattr(_state, "teamsWrkDataCanonical", str(canon), raising=False)
    with pytest.raises(ValueError, match=r"^\[cso_toolkit\.dw_compare\](?s:.*)same file(?s:.*)reviewer mode"):
        m.dw_compare(str(sandbox / "x.csv"), str(canon / "x.csv"), by=KEYS)
    r = m.dw_compare(pd.read_csv(sandbox / "x.csv"), str(canon / "x.csv"), by=KEYS)
    assert int(r["summary"]["changed"].iloc[0]) > 0


def test_same_path_twice_stops(tmp_path):
    a, b = tmp_path / "a.csv", tmp_path / "b.csv"
    REF.to_csv(a, index=False)
    CUR.to_csv(b, index=False)
    with pytest.raises(ValueError, match="same file"):
        m.dw_compare(str(a), str(a), by=KEYS)
    assert int(m.dw_compare(str(b), str(a), by=KEYS)["summary"]["added"].iloc[0]) == 1
