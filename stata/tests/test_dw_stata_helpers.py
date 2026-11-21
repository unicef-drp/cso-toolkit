"""Tests for stata/src/dw_stata_helpers.py (no Stata needed).

    python -m pytest stata/tests
The Stata side is covered by stata/tests/test_collab_guards.do.
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest

SRC = Path(__file__).resolve().parents[1] / "src" / "dw_stata_helpers.py"
spec = importlib.util.spec_from_file_location("dw_stata_helpers", SRC)
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)


def write(path: Path, data: bytes, user: str, at: str, **extra) -> None:
    path.write_bytes(data)
    side = {"sha256": hashlib.sha256(data).hexdigest(), "user": user, "written_at": at, **extra}
    Path(str(path) + ".provenance.json").write_text(json.dumps(side), encoding="utf-8")


def test_sha256_and_timestamps(tmp_path):
    p = tmp_path / "x.dta"
    p.write_bytes(b"abc")
    assert h.sha256_file(str(p)) == hashlib.sha256(b"abc").hexdigest()
    assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\+0000", h.utc_now())
    assert h.parse_iso("2026-11-20T10:00:00+0000") < h.parse_iso("2026-11-21T10:00:00+0000")
    assert h.parse_iso("21 Nov 2026 10:00:00") is None        # Stata's old local format


def test_no_sidecar_or_no_file_fires_nothing(tmp_path):
    p = tmp_path / "x.dta"
    r = h.preflight(str(p), "jp", "2000-01-01T00:00:00+0000", False)
    assert r["fired"] == [] and r["previous_sha256"] == ""
    p.write_bytes(b"abc")
    assert h.preflight(str(p), "jp", "2000-01-01T00:00:00+0000", False)["fired"] == []


def test_out_of_band(tmp_path):
    p = tmp_path / "x.dta"
    write(p, b"abc", "jp", "2026-11-20T10:00:00+0000")
    p.write_bytes(b"abcd")                                         # changed without dw_save
    r = h.preflight(str(p), "jp", "2999-01-01T00:00:00+0000", False)
    assert r["fired"] == ["out_of_band"] and "out-of-band" in r["why"][0]
    assert r["previous_sha256"] == hashlib.sha256(b"abcd").hexdigest()
    assert h.preflight(str(p), "jp", "2999-01-01T00:00:00+0000", True)["fired"] == []   # reviewer


def test_concurrent_note_and_baseline(tmp_path):
    p = tmp_path / "x.dta"
    write(p, b"abc", "karen", "2026-11-20T10:00:00+0000")
    assert h.preflight(str(p), "jp", "2000-01-01T00:00:00+0000", False)["fired"] == ["concurrent"]
    r = h.preflight(str(p), "jp", "2999-01-01T00:00:00+0000", False)
    assert r["fired"] == [] and "last written by karen" in r["note"]
    assert h.preflight(str(p), "karen", "2000-01-01T00:00:00+0000", False)["fired"] == []
    write(p, b"abc", "karen", "2020-01-01T00:00:00+0000", baseline={"user": "karen"})
    assert h.preflight(str(p), "jp", "2999-01-01T00:00:00+0000", False)["note"] == ""


@pytest.mark.skipif(shutil.which("git") is None, reason="git not installed")
def test_committed_write_is_not_concurrent(tmp_path):
    def git(*a):
        subprocess.run(["git", "-C", str(tmp_path), "-c", "user.name=t",
                        "-c", "user.email=t@example.org", *a], check=True, capture_output=True)
    git("init", "-q")
    p = tmp_path / "x.dta"
    write(p, b"abc", "karen", "2026-11-20T10:00:00+0000")
    git("add", "x.dta", "x.dta.provenance.json")
    git("commit", "-q", "-m", "karen-output")
    r = h.preflight(str(p), "jp", "2000-01-01T00:00:00+0000", False)
    assert r["fired"] == [] and r["git_commit"]
    write(p, b"abc", "karen", "2026-11-20T11:00:00+0000")         # modified after the commit
    assert h.preflight(str(p), "jp", "2000-01-01T00:00:00+0000", False)["fired"] == ["concurrent"]


def test_json_str_and_user(monkeypatch):
    assert h.json_str('say "hi"') == '"say \\"hi\\""'
    monkeypatch.setenv("USERNAME", "")
    monkeypatch.setenv("LOGNAME", "lg")
    assert h.current_user() == "lg"
