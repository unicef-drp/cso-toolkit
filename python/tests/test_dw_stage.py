"""Tests for ``dw_stage`` and ``dw_use(stage=)``.

Python mirror of ``r/tests/testthat/test-dw_stage.R`` (T1-T8 and the
producer no-op), plus the ``dw_use`` integration.  Each test builds its
own sandbox / Teams / Z: folders under ``tmp_path``; no real Teams sync
or Z: mount is touched.
"""

from __future__ import annotations

import hashlib
import json
import os
import time
import warnings
from pathlib import Path

import pytest

import cso_toolkit as m
from cso_toolkit import _state
from cso_toolkit.dw_io import _normalize

SRC_TEXT = "id,value\nAFG,1\nBGD,2\n"


def _sha(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


@pytest.fixture
def fx(tmp_path, monkeypatch):
    teams_root = tmp_path / "teams"
    z_root = tmp_path / "z"
    sandbox_root = tmp_path / "sandbox"
    rel = Path("nt") / "input" / "regions.csv"
    teams_path = teams_root / rel
    z_path = z_root / rel
    sandbox_path = sandbox_root / rel
    for p in (teams_path, z_path, sandbox_path):
        p.parent.mkdir(parents=True, exist_ok=True)
    teams_path.write_text(SRC_TEXT, encoding="utf-8")
    z_path.write_text(SRC_TEXT, encoding="utf-8")
    # Reviewer mode: the local roots point at the sandbox, the *Canonical
    # roots at the producer-side Teams deposit.
    for key, value in {
        "dw_mode": "reviewer",
        "teamsRawData": str(sandbox_root), "teamsRawDataCanonical": str(teams_root),
        "teamsWrkData": str(sandbox_root), "teamsWrkDataCanonical": str(teams_root),
        "teamsFolder": str(sandbox_root), "teamsFolderCanonical": str(teams_root),
        "dwZDrive": str(z_root), "dw_z_available": True,
        "dw_autostage": None,
    }.items():
        monkeypatch.setattr(_state, key, value, raising=False)
    return {
        "teams": teams_path, "z": z_path, "sandbox": sandbox_path,
        "sidecar": Path(str(sandbox_path) + ".staged.json"),
    }


def test_t1_first_stage_copies_verifies_and_writes_sidecar(fx):
    out = m.dw_stage(str(fx["sandbox"]))
    assert Path(out).exists()
    assert fx["sidecar"].exists()
    assert _sha(fx["sandbox"]) == _sha(fx["teams"])
    sc = json.loads(fx["sidecar"].read_text(encoding="utf-8"))
    assert sc["type"] == "dw_stage"
    assert sc["sha256"] == _sha(fx["teams"])
    assert sc["source_root"] == "z"  # Z: is preferred when it holds the file
    assert set(sc) == {"type", "source", "source_root", "sha256", "size",
                       "mtime", "staged_at", "dw_toolkit_version"}


def test_t2_second_run_skips_the_copy(fx):
    m.dw_stage(str(fx["sandbox"]))
    before = fx["sandbox"].stat().st_mtime
    time.sleep(1.1)
    m.dw_stage(str(fx["sandbox"]))
    assert fx["sandbox"].stat().st_mtime == before


def test_t3_tampered_sandbox_stops_with_drift(fx):
    m.dw_stage(str(fx["sandbox"]))
    fx["sandbox"].write_text("id,value\nXXX,9\n", encoding="utf-8")
    with pytest.raises(RuntimeError, match="SANDBOX DRIFT"):
        m.dw_stage(str(fx["sandbox"]))


def test_t4_overwrite_restores_from_source(fx):
    m.dw_stage(str(fx["sandbox"]))
    fx["sandbox"].write_text("id,value\nXXX,9\n", encoding="utf-8")
    out = m.dw_stage(str(fx["sandbox"]), overwrite=True)
    assert Path(out).exists()
    assert _sha(fx["sandbox"]) == _sha(fx["teams"])
    assert not Path(str(fx["sandbox"]) + ".dw_stage.tmp").exists()


def test_t5_upstream_change_warns_and_does_not_recopy(fx):
    m.dw_stage(str(fx["sandbox"]))
    time.sleep(1.1)
    new_text = "id,value\nAFG,9\nBGD,9\n"
    fx["teams"].write_text(new_text, encoding="utf-8")
    fx["z"].write_text(new_text, encoding="utf-8")
    before = _sha(fx["sandbox"])
    with pytest.warns(UserWarning, match="UPSTREAM CHANGED"):
        out = m.dw_stage(str(fx["sandbox"]))
    assert Path(out).exists()
    assert _sha(fx["sandbox"]) == before


def test_t6_mirrors_disagree_stops_before_any_copy(fx):
    fx["z"].write_text("id,value\nDIFFERENT,1\n", encoding="utf-8")
    with pytest.raises(RuntimeError, match="CANONICAL INTEGRITY"):
        m.dw_stage(str(fx["sandbox"]))
    assert not fx["sidecar"].exists()
    assert not Path(str(fx["sandbox"]) + ".dw_stage.tmp").exists()


def test_noop_outside_reviewer_mode(fx, monkeypatch):
    monkeypatch.setattr(_state, "dw_mode", "producer", raising=False)
    out = m.dw_stage(str(fx["sandbox"]))
    assert out == str(fx["sandbox"])
    assert not fx["sandbox"].exists()


def test_t7_canonical_input_is_mapped_to_the_sandbox(fx):
    out = m.dw_stage(str(fx["teams"]))
    assert _normalize(out) == _normalize(fx["sandbox"])
    assert fx["sandbox"].exists()
    assert fx["sidecar"].exists()
    assert not Path(str(fx["teams"]) + ".staged.json").exists()
    assert fx["sandbox"].read_text(encoding="utf-8") == fx["teams"].read_text(encoding="utf-8")


def test_t8_canonical_input_second_call_skips_the_copy(fx):
    m.dw_stage(str(fx["teams"]))
    before = fx["sandbox"].stat().st_mtime
    time.sleep(1.1)
    out = m.dw_stage(str(fx["teams"]))
    assert fx["sandbox"].stat().st_mtime == before
    assert _normalize(out) == _normalize(fx["sandbox"])


def test_teams_only_source_is_used_when_z_lacks_the_file(fx):
    fx["z"].unlink()
    m.dw_stage(str(fx["sandbox"]))
    sc = json.loads(fx["sidecar"].read_text(encoding="utf-8"))
    assert sc["source_root"] == "teams"


def test_missing_everywhere_raises_not_found(fx):
    fx["z"].unlink()
    fx["teams"].unlink()
    with pytest.raises(FileNotFoundError, match="not found in sandbox, Z:, or Teams"):
        m.dw_stage(str(fx["sandbox"]))


def test_sandbox_copy_without_sidecar_stops(fx):
    fx["sandbox"].write_text(SRC_TEXT, encoding="utf-8")
    with pytest.raises(RuntimeError, match="no archived hash sidecar"):
        m.dw_stage(str(fx["sandbox"]))


def test_sidecar_of_another_type_is_refused(fx):
    m.dw_stage(str(fx["sandbox"]))
    sc = json.loads(fx["sidecar"].read_text(encoding="utf-8"))
    sc["type"] = "dw_save"
    fx["sidecar"].write_text(json.dumps(sc), encoding="utf-8")
    with pytest.raises(RuntimeError, match="expected 'dw_stage'"):
        m.dw_stage(str(fx["sandbox"]))


def test_mtime_matches_rs_format(fx):
    # R writes format(file.mtime(p), "%Y-%m-%dT%H:%M:%S%z"): local time,
    # whole seconds, +HHMM offset with no colon.
    m.dw_stage(str(fx["sandbox"]))
    sc = json.loads(fx["sidecar"].read_text(encoding="utf-8"))
    assert len(sc["mtime"]) == 24
    assert sc["mtime"][19] in "+-" and ":" not in sc["mtime"][19:]
    assert sc["staged_at"].endswith("Z")


def test_unchanged_source_is_not_rehashed(fx, monkeypatch):
    # The size + mtime fast path must hold, or every read hashes the source.
    m.dw_stage(str(fx["sandbox"]))
    from cso_toolkit import dw_io
    calls = []
    real = dw_io._sha256_file

    def counting(p):
        calls.append(_normalize(p))
        return real(p)

    monkeypatch.setattr(dw_io, "_sha256_file", counting)
    with warnings.catch_warnings():
        warnings.simplefilter("error")
        m.dw_stage(str(fx["sandbox"]))
    assert calls == [_normalize(fx["sandbox"])]


def test_a_recopy_changes_the_sandbox_mtime(fx):
    # Guards T2 and T8: their "mtime unchanged" check only proves no re-copy
    # if a re-copy would change the mtime (copyfile, not copy2, as in R).
    m.dw_stage(str(fx["sandbox"]))
    before = fx["sandbox"].stat().st_mtime
    time.sleep(1.1)
    m.dw_stage(str(fx["sandbox"]), overwrite=True)
    assert fx["sandbox"].stat().st_mtime != before


def test_failed_copy_retries_then_stops_and_cleans_up(fx, monkeypatch):
    import shutil
    calls = []

    def failing_copy(src, dst, *a, **k):
        calls.append(dst)
        Path(dst).write_text("partial", encoding="utf-8")
        raise OSError(28, "No space left on device")

    monkeypatch.setattr(shutil, "copyfile", failing_copy)
    with pytest.raises(RuntimeError, match="COPY INTEGRITY"):
        m.dw_stage(str(fx["sandbox"]))
    assert len(calls) == 2  # one retry, as in R
    assert not Path(str(fx["sandbox"]) + ".dw_stage.tmp").exists()
    assert not fx["sandbox"].exists()
    assert not fx["sidecar"].exists()


def test_verifies_a_sidecar_written_by_r(fx, monkeypatch):
    # The layout jsonlite::write_json(auto_unbox = TRUE, pretty = TRUE,
    # na = "null") gives for R's dw_stage sidecar, with the source's real
    # size and mtime: Python must accept it without warning or re-hashing
    # the source.
    from cso_toolkit import dw_io
    fx["sandbox"].write_bytes(fx["z"].read_bytes())
    digest = _sha(fx["z"])
    size = fx["z"].stat().st_size
    mtime = dw_io._stage_mtime_iso(fx["z"])
    src = _normalize(fx["z"])
    fx["sidecar"].write_text(
        "{\n"
        '  "type": "dw_stage",\n'
        f'  "source": "{src}",\n'
        '  "source_root": "z",\n'
        f'  "sha256": "{digest}",\n'
        f'  "size": {size},\n'
        f'  "mtime": "{mtime}",\n'
        '  "staged_at": "2026-11-23T23:00:14Z",\n'
        '  "dw_toolkit_version": "0.11.1"\n'
        "}\n",
        encoding="utf-8",
    )
    hashed = []
    real = dw_io._sha256_file
    monkeypatch.setattr(dw_io, "_sha256_file", lambda p: (hashed.append(_normalize(p)), real(p))[1])
    with warnings.catch_warnings():
        warnings.simplefilter("error")
        out = m.dw_stage(str(fx["sandbox"]))
    assert _normalize(out) == _normalize(fx["sandbox"])
    assert hashed == [_normalize(fx["sandbox"])]


def test_dw_use_stage_true_reads_the_staged_copy(fx):
    df = m.dw_use(str(fx["teams"]), stage=True, verify_z=False)
    assert df["id"].tolist() == ["AFG", "BGD"]
    assert fx["sidecar"].exists()


def test_dw_use_follows_dw_autostage(fx, monkeypatch):
    monkeypatch.setattr(_state, "dw_autostage", True, raising=False)
    m.dw_use(str(fx["teams"]), verify_z=False)
    assert fx["sidecar"].exists()


def test_dw_use_stage_false_overrides_dw_autostage(fx, monkeypatch):
    monkeypatch.setattr(_state, "dw_autostage", True, raising=False)
    m.dw_use(str(fx["teams"]), stage=False, verify_z=False)
    assert not fx["sidecar"].exists()


def test_dw_use_does_not_stage_by_default(fx):
    m.dw_use(str(fx["teams"]), verify_z=False)
    assert not fx["sidecar"].exists()
    assert not fx["sandbox"].exists()
