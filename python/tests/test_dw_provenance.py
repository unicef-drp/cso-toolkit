"""dw_read_provenance() and dw_provenance_diff() (#152). Mirror of
r/tests/testthat/test-dw_provenance.R (P1-P9)."""
from __future__ import annotations

import warnings

import pandas as pd
import pytest

import cso_toolkit as m
from cso_toolkit import _state

INPUTS = pd.DataFrame({"file": ["2024/A_2024.csv", "2025/B_2025.csv"],
                       "sha256": ["aaa", "bbb"], "origin": "local"})
DF = pd.DataFrame({"k": ["x", "y"], "v": [1.0, 2.0]})


@pytest.fixture(autouse=True)
def plain(monkeypatch):
    for k, v in (("dw_mode", None), ("dw_collaboration_model", "single-producer"),
                 ("teamsWrkDataCanonical", None), ("teamsRawDataCanonical", None),
                 ("teamsFolderCanonical", None), ("dw_z_available", False)):
        monkeypatch.setattr(_state, k, v, raising=False)


def save_run(folder, df, inputs=None, name="out.csv"):
    path = folder / name
    meta = {"title": "test output"}
    if inputs is not None:
        meta["inputs"] = inputs
    m.dw_save(df, path=str(path), metadata=meta, overwrite=True)
    return path


def test_p1_reads_from_output_or_sidecar(tmp_path):
    out = save_run(tmp_path, DF, INPUTS)
    p1 = m.dw_read_provenance(out, verbose=False)
    p2 = m.dw_read_provenance(str(out) + ".provenance.json", verbose=False)
    assert p1["sha256"] == p2["sha256"]
    assert isinstance(p1["metadata"]["inputs"], pd.DataFrame)
    assert p1["metadata"]["inputs"]["file"].tolist() == INPUTS["file"].tolist()


def test_p2_no_sidecar_is_none(tmp_path):
    assert m.dw_read_provenance(tmp_path / "none.csv", verbose=False) is None


def test_p3_invalid_sidecar(tmp_path):
    (tmp_path / "bad.csv.provenance.json").write_text("{ not json", encoding="utf-8")
    with pytest.raises(ValueError, match=r"^\[cso_toolkit\.dw_read_provenance\](?s:.*)Fix:"):
        m.dw_read_provenance(tmp_path / "bad.csv", verbose=False)


def test_p4_reproduced(tmp_path):
    out = save_run(tmp_path, DF, INPUTS)
    prev = m.dw_read_provenance(out, verbose=False)
    save_run(tmp_path, DF, INPUTS)
    run = m.dw_provenance_diff(prev, out, verbose=False)
    assert run["status"] == "reproduced" and run["same_inputs"] and run["same_output"]


def test_p5_output_changed_warns(tmp_path):
    out = save_run(tmp_path, DF, INPUTS)
    prev = m.dw_read_provenance(out, verbose=False)
    save_run(tmp_path, DF.assign(v=DF["v"] * 10), INPUTS)
    with pytest.warns(UserWarning, match=r"^\[cso_toolkit\.dw_provenance_diff\]"):
        run = m.dw_provenance_diff(prev, out, verbose=False)
    assert run["status"] == "output_changed"
    assert run["same_inputs"] is True and run["same_output"] is False
    with warnings.catch_warnings():
        warnings.simplefilter("error")
        m.dw_provenance_diff(prev, out, warn=False, verbose=False)


def test_p6_inputs_added_removed_changed(tmp_path):
    out = save_run(tmp_path, DF, INPUTS)
    prev = m.dw_read_provenance(out, verbose=False)
    new = pd.DataFrame({"file": ["2024/A_2024.csv", "2023/C_2023.csv"],
                        "sha256": ["aaa-changed", "ccc"], "origin": "local"})
    save_run(tmp_path, DF, new)
    run = m.dw_provenance_diff(prev, out, verbose=False)
    assert run["status"] == "inputs_changed" and run["same_inputs"] is False
    assert run["inputs_added"] == ["2023/C_2023.csv"]
    assert run["inputs_removed"] == ["2025/B_2025.csv"]
    assert run["inputs_changed"] == ["2024/A_2024.csv"]


def test_p7_first_run(tmp_path):
    out = save_run(tmp_path, DF, INPUTS)
    run = m.dw_provenance_diff(None, out, verbose=False)
    assert run["status"] == "first_run" and run["same_output"] is None


def test_p8_no_input_record(tmp_path):
    out = save_run(tmp_path, DF)
    prev = m.dw_read_provenance(out, verbose=False)
    save_run(tmp_path, DF, INPUTS)
    run = m.dw_provenance_diff(prev, out, verbose=False)
    assert run["status"] == "no_input_record" and run["same_output"] is True


def test_p9_current_without_sidecar(tmp_path):
    with pytest.raises(FileNotFoundError, match=r"^\[cso_toolkit\.dw_provenance_diff\]"):
        m.dw_provenance_diff(None, tmp_path / "none.csv", verbose=False)
