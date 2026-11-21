"""dw_fetch_inputs() and dw_check_deposit() (#152). Mirror of
r/tests/testthat/test-dw_deposit.R (D1-D14): each test builds its own
local / Teams / Z: folders; no real Teams sync or Z: mount is touched."""
from __future__ import annotations

import hashlib
import os
from pathlib import Path

import pytest

import cso_toolkit as m
from cso_toolkit import _state

REL = "02_consultations/023_targets/inputs"
PATTERN = r"_20(23|24|25)\.(csv|txt)$"
FILES = {"2024/NUTRITION_2024.csv": "Country,Value\nAFG,1\nBGD,2\n",
         "2025/WASH_2025.csv": "Country,Value\nAFG,3\n"}


def put(folder: Path, files: dict) -> None:
    for f, text in files.items():
        p = folder / f
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding="utf-8")


def sha(p) -> str:
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


@pytest.fixture
def fx(tmp_path, monkeypatch):
    def make(z: bool = False):
        teams, zr = tmp_path / "teams", tmp_path / "z"
        local = tmp_path / "repo" / REL
        for d in (teams / REL, zr / REL, local):
            d.mkdir(parents=True, exist_ok=True)
        (local / "README.md").write_text("# not an input\n", encoding="utf-8")
        monkeypatch.setattr(_state, "dw_mode", "reviewer", raising=False)
        monkeypatch.setattr(_state, "teamsFolderCanonical", str(teams), raising=False)
        monkeypatch.setattr(_state, "dwZDrive", str(zr) if z else None, raising=False)
        monkeypatch.setattr(_state, "dw_z_available", z, raising=False)
        return {"root": tmp_path, "teams": teams, "z": zr, "local": local}
    return make


def deposit(f, where="teams", files=FILES):
    put(f[where] / REL, files)


def local_files(f):
    return sorted(str(p.relative_to(f["local"])).replace(os.sep, "/")
                  for p in f["local"].rglob("*") if p.is_file())


def test_d1_empty_local_filled_from_teams(fx):
    f = fx()
    deposit(f)
    mf = m.dw_fetch_inputs(f["local"], REL, pattern=PATTERN, verbose=False)
    assert set(mf["file"]) == set(FILES)
    assert (mf["origin"] == "copied from Teams").all()
    for _, r in mf.iterrows():
        assert r["sha256"] == sha(f["teams"] / REL / r["file"])
        assert not os.path.exists(r["path"] + ".dw_fetch.tmp")
    assert (mf["teams"] == "match").all()


def test_d2_z_preferred(fx):
    f = fx(z=True)
    deposit(f, "teams")
    deposit(f, "z")
    mf = m.dw_fetch_inputs(f["local"], REL, pattern=PATTERN, verbose=False)
    assert (mf["origin"] == "copied from Z:").all()
    assert ((mf["z"] == "match") & (mf["teams"] == "match")).all()


def test_d3_copy_false_reads_in_place(fx):
    f = fx()
    deposit(f)
    mf = m.dw_fetch_inputs(f["local"], REL, pattern=PATTERN, copy=False, verbose=False)
    assert (mf["origin"] == "read from Teams").all()
    teams = str(f["teams"]).replace("\\", "/")
    assert all(p.replace("\\", "/").startswith(teams) for p in mf["path"])
    assert [x for x in local_files(f) if not x.endswith(".gitkeep")] == ["README.md"]
    assert (f["local"] / "2024" / ".gitkeep").exists()


def test_d4_partial_local_set_completed(fx):
    f = fx()
    deposit(f)
    first, second = list(FILES)
    put(f["local"], {first: FILES[first]})
    mf = m.dw_fetch_inputs(f["local"], REL, pattern=PATTERN, verbose=False)
    origin = dict(zip(mf["file"], mf["origin"]))
    assert origin[first] == "local" and origin[second] == "copied from Teams"


def test_d5_local_differs_stops(fx):
    f = fx()
    deposit(f)
    put(f["local"], {"2024/NUTRITION_2024.csv": "Country,Value\nAFG,999\n"})
    with pytest.raises(ValueError, match=r"^\[cso_toolkit\.dw_check_deposit\](?s:.*)differs(?s:.*)Fix:"):
        m.dw_fetch_inputs(f["local"], REL, pattern=PATTERN, verbose=False)


def test_d6_local_missing_from_deposit_stops(fx):
    f = fx()
    put(f["local"], FILES)
    first = list(FILES)[0]
    deposit(f, files={first: FILES[first]})
    with pytest.raises(ValueError, match=r"^\[cso_toolkit\.dw_check_deposit\](?s:.*)missing"):
        m.dw_fetch_inputs(f["local"], REL, pattern=PATTERN, verbose=False)


def test_d7_teams_and_z_disagree(fx):
    f = fx(z=True)
    deposit(f, "teams")
    deposit(f, "z", files={"2024/NUTRITION_2024.csv": "Country,Value\nAFG,7\n"})
    with pytest.raises(ValueError, match=r"^\[cso_toolkit\.dw_fetch_inputs\](?s:.*)different versions"):
        m.dw_fetch_inputs(f["local"], REL, pattern=PATTERN, verbose=False)
    assert local_files(f) == ["README.md"]


def test_d8_no_input_anywhere(fx):
    f = fx()
    with pytest.raises(FileNotFoundError, match=r"^\[cso_toolkit\.dw_fetch_inputs\] No input files"):
        m.dw_fetch_inputs(f["local"], REL, pattern=PATTERN, verbose=False)


def test_d9_no_reachable_deposit(fx, monkeypatch):
    f = fx()
    put(f["local"], FILES)
    monkeypatch.setattr(_state, "teamsFolderCanonical", None, raising=False)
    monkeypatch.setattr(_state, "dw_z_available", False, raising=False)
    with pytest.raises(FileNotFoundError, match=r"^\[cso_toolkit\.dw_check_deposit\]"):
        m.dw_fetch_inputs(f["local"], REL, pattern=PATTERN, verbose=False)


def test_d10_check_deposit_report(fx):
    f = fx()
    put(f["local"], FILES)
    first = list(FILES)[0]
    deposit(f, files={first: FILES[first]})
    paths = [f["local"] / x for x in FILES]
    rep = m.dw_check_deposit(paths, f["local"], REL, stop_on_fail=False, verbose=False)
    assert rep["ok"].tolist() == [True, False]
    assert rep["teams"].tolist() == ["match", "missing"]
    assert rep["z"].tolist() == ["no access", "no access"]


def test_d11_explicit_roots_override_globals(fx, monkeypatch):
    f = fx()
    deposit(f)
    monkeypatch.setattr(_state, "teamsFolderCanonical", None, raising=False)
    monkeypatch.setattr(_state, "dw_z_available", False, raising=False)
    mf = m.dw_fetch_inputs(f["local"], REL, pattern=PATTERN, teams_root=str(f["teams"]),
                           verbose=False)
    assert (mf["origin"] == "copied from Teams").all()


def test_d12_path_outside_local_root(fx):
    f = fx()
    outside = f["root"] / "elsewhere.csv"
    outside.write_text("x\n", encoding="utf-8")
    with pytest.raises(ValueError, match=r"^\[cso_toolkit\.dw_check_deposit\]"):
        m.dw_check_deposit([outside], f["local"], REL, verbose=False)


def test_d13_gitkeep_keeps_every_folder_visible(fx):
    f = fx()
    deposit(f)
    (f["teams"] / REL / "2023").mkdir()
    (f["local"] / "notes").mkdir()
    mf = m.dw_fetch_inputs(f["local"], REL, pattern=PATTERN, verbose=False)
    for d in ("", "2023", "2024", "2025", "notes"):
        assert (f["local"] / d / ".gitkeep").exists(), d
    assert not mf["file"].str.contains("gitkeep").any()
    mf2 = m.dw_fetch_inputs(f["local"], REL, pattern=PATTERN, verbose=False)
    assert mf2["file"].tolist() == mf["file"].tolist()


def test_d14_gitkeep_false_and_pattern_none(fx):
    f = fx()
    deposit(f)
    (f["teams"] / REL / ".gitkeep").write_text("", encoding="utf-8")
    (f["local"] / "README.md").unlink()
    mf = m.dw_fetch_inputs(f["local"], REL, gitkeep=False, verbose=False)
    assert set(mf["file"]) == set(FILES)
    assert not list(f["local"].rglob(".gitkeep"))


def test_manifest_round_trips_through_dw_save_metadata(fx, tmp_path):
    """The manifest passed as dw_save metadata lands as records and reads back as a frame."""
    f = fx()
    deposit(f)
    mf = m.dw_fetch_inputs(f["local"], REL, pattern=PATTERN, verbose=False)
    import pandas as pd
    out = tmp_path / "out.csv"
    _state.configure(dw_mode=None)
    m.dw_save(pd.DataFrame({"a": [1]}), path=str(out), overwrite=True,
              metadata={"inputs": mf[["file", "sha256", "origin"]]})
    prov = m.dw_read_provenance(out, verbose=False)
    assert prov["metadata"]["inputs"]["file"].tolist() == mf["file"].tolist()
