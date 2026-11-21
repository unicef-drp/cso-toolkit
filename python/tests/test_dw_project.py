"""Project-level collaboration model (cso_project.yml) — Python parity with
``r/tests/testthat/test-dw_project.R``: dw_collaboration, dw_set_collaboration,
the multi-producer dw_save guards and lineage fields, the API refresh rule and
the profile checks.
"""

from __future__ import annotations

import hashlib
import json
import logging
import re
import warnings
from pathlib import Path

import pandas as pd
import pytest
import yaml

import cso_toolkit as m
from cso_toolkit import _state
from cso_toolkit import dw_api

SINGLE_KEYS = ["path", "format", "written_at", "user", "dw_mode", "vintage",
               "sha256", "isid", "schema", "metadata"]
LINEAGE_KEYS = ["collaboration", "previous_sha256", "previous_user",
                "previous_written_at", "git_branch", "git_commit"]
FUTURE = "2999-01-01T00:00:00+0000"
PAST = "2000-01-01T00:00:00+0000"


@pytest.fixture(autouse=True)
def clean_state(monkeypatch):
    """Plain local writes: no mode, no mirrors; restore every key afterwards."""
    for key in ("dw_mode", "teamsWrkDataCanonical", "teamsRawDataCanonical",
                "teamsFolderCanonical", "dwZDrive", "rootFolder",
                "dw_collaboration_model", "dw_project_file", "dw_session_start"):
        monkeypatch.setattr(_state, key, None, raising=False)
    monkeypatch.setattr(_state, "dw_z_available", False, raising=False)
    monkeypatch.setattr(_state, "dw_apis_allowed", False, raising=False)


def write_project(d: Path, model: str = "multi-producer") -> None:
    (d / "cso_project.yml").write_text(
        f"schema: cso_project/1\ncollaboration: {model}\n"
        "collaboration_since: 2026-11-20\n", encoding="utf-8")


def multi(monkeypatch, start: str = PAST, mode=None) -> None:
    monkeypatch.setattr(_state, "dw_collaboration_model", "multi-producer")
    monkeypatch.setattr(_state, "dw_session_start", start)
    monkeypatch.setattr(_state, "dw_mode", mode)


def save_as(monkeypatch, user: str, df: pd.DataFrame, path: Path, **kw) -> str:
    monkeypatch.setenv("USERNAME", user)
    return m.dw_save(df, path=str(path), overwrite=True, **kw)


def sidecar(path: Path) -> dict:
    with open(f"{path}.provenance.json", encoding="utf-8") as f:
        return json.load(f)


def sha(path: Path) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


# --- dw_collaboration --------------------------------------------------------

def test_no_project_file_means_single_producer(tmp_path):
    (tmp_path / ".git").mkdir()
    assert m.dw_collaboration(root=tmp_path) == "single-producer"
    assert _state.dw_project_file is None
    assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\+0000", _state.dw_session_start)


def test_walk_up_and_cache(tmp_path):
    (tmp_path / ".git").mkdir()
    write_project(tmp_path, "multi-producer")
    sub = tmp_path / "a" / "b"
    sub.mkdir(parents=True)
    assert m.dw_collaboration(root=sub) == "multi-producer"
    assert _state.dw_collaboration_model == "multi-producer"
    write_project(tmp_path, "single-producer")
    assert m.dw_collaboration() == "multi-producer"          # cached
    assert m.dw_collaboration(root=sub, refresh=True) == "single-producer"


def test_walk_stops_at_repository_root(tmp_path):
    write_project(tmp_path, "multi-producer")
    repo = tmp_path / "repo"
    (repo / ".git").mkdir(parents=True)
    assert m.dw_collaboration(root=repo) == "single-producer"


def test_unknown_model_or_schema_raises_envelope(tmp_path):
    (tmp_path / ".git").mkdir()
    write_project(tmp_path, "everyone-produces")
    with pytest.raises(ValueError, match=r"^\[cso_toolkit\.dw_collaboration\]") as exc:
        m.dw_collaboration(root=tmp_path)
    assert "Fix:" in str(exc.value)
    (tmp_path / "cso_project.yml").write_text(
        "schema: cso_project/9\ncollaboration: multi-producer\n", encoding="utf-8")
    with pytest.raises(ValueError, match="cso_project/9"):
        m.dw_collaboration(root=tmp_path)


# --- dw_save: single-producer unchanged ---------------------------------------

def test_single_producer_sidecar_key_set_unchanged(tmp_path, monkeypatch):
    monkeypatch.setattr(_state, "dw_collaboration_model", "single-producer")
    out = tmp_path / "x.csv"
    save_as(monkeypatch, "jp", pd.DataFrame({"a": [1, 2]}), out, metadata={"title": "t"})
    save_as(monkeypatch, "karen", pd.DataFrame({"a": [3, 4]}), out, metadata={"title": "t"})
    assert list(sidecar(out)) == SINGLE_KEYS


# --- dw_save: multi-producer guards -----------------------------------------

def test_write_over_other_producer_only_notes(tmp_path, monkeypatch, caplog):
    multi(monkeypatch, start=FUTURE)
    out = tmp_path / "x.csv"
    save_as(monkeypatch, "karen", pd.DataFrame({"a": [1, 2]}), out)
    karen = sidecar(out)
    with caplog.at_level(logging.INFO, logger="cso_toolkit.dw_project"):
        save_as(monkeypatch, "jp", pd.DataFrame({"a": [3, 4]}), out)
    assert "x.csv was last written by karen" in caplog.text
    prov = sidecar(out)
    assert list(prov)[9:9 + len(LINEAGE_KEYS)] == LINEAGE_KEYS
    assert prov["collaboration"] == "multi-producer"
    assert prov["previous_sha256"] == karen["sha256"]
    assert prov["previous_user"] == "karen"
    assert prov["previous_written_at"] == karen["written_at"]
    assert prov["git_branch"] is None and prov["git_commit"] is None
    assert "takeover" not in prov


def test_first_write_has_null_previous_fields(tmp_path, monkeypatch):
    multi(monkeypatch)
    out = tmp_path / "new.csv"
    save_as(monkeypatch, "jp", pd.DataFrame({"a": [1]}), out)
    prov = sidecar(out)
    assert all(k in prov for k in LINEAGE_KEYS)
    assert prov["previous_sha256"] is None and prov["previous_user"] is None


def test_out_of_band_change_raises_envelope(tmp_path, monkeypatch):
    multi(monkeypatch, start=FUTURE)
    out = tmp_path / "x.csv"
    save_as(monkeypatch, "jp", pd.DataFrame({"a": [1, 2]}), out)
    with open(out, "a", encoding="utf-8") as f:
        f.write("9\n")
    with pytest.raises(PermissionError) as exc:
        save_as(monkeypatch, "jp", pd.DataFrame({"a": [5]}), out)
    msg = str(exc.value)
    assert msg.startswith("[cso_toolkit.dw_save]")
    assert "out-of-band change" in msg and "Fix:" in msg and "takeover=True" in msg
    assert out.read_text(encoding="utf-8").splitlines()[-1] == "9"


def test_guards_apply_in_producer_mode(tmp_path, monkeypatch):
    multi(monkeypatch, start=FUTURE, mode="producer")
    monkeypatch.setattr(_state, "teamsWrkDataCanonical", str(tmp_path))
    out = tmp_path / "x.csv"
    save_as(monkeypatch, "jp", pd.DataFrame({"a": [1]}), out)
    with open(out, "a", encoding="utf-8") as f:
        f.write("9\n")
    with pytest.raises(PermissionError, match="out-of-band change"):
        save_as(monkeypatch, "jp", pd.DataFrame({"a": [2]}), out)


def test_concurrent_write_raises(tmp_path, monkeypatch):
    multi(monkeypatch, start=PAST)
    out = tmp_path / "x.csv"
    save_as(monkeypatch, "karen", pd.DataFrame({"a": [1, 2]}), out)
    with pytest.raises(PermissionError) as exc:
        save_as(monkeypatch, "jp", pd.DataFrame({"a": [5]}), out)
    assert "concurrent write" in str(exc.value)
    assert "karen wrote it at" in str(exc.value)


def test_same_user_rewrite_is_not_concurrent(tmp_path, monkeypatch):
    multi(monkeypatch, start=PAST)
    out = tmp_path / "x.csv"
    save_as(monkeypatch, "jp", pd.DataFrame({"a": [1]}), out)
    save_as(monkeypatch, "jp", pd.DataFrame({"a": [2]}), out)


def test_takeover_overrides_and_is_recorded(tmp_path, monkeypatch, caplog):
    multi(monkeypatch, start=PAST)
    out = tmp_path / "x.csv"
    save_as(monkeypatch, "karen", pd.DataFrame({"a": [1, 2]}), out)
    with open(out, "a", encoding="utf-8") as f:
        f.write("9\n")
    changed = sha(out)
    with caplog.at_level(logging.INFO, logger="cso_toolkit.dw_project"):
        save_as(monkeypatch, "jp", pd.DataFrame({"a": [5]}), out, takeover=True)
    assert "takeover: replacing x.csv despite out_of_band + concurrent" in caplog.text
    prov = sidecar(out)
    assert prov["takeover"]["user"] == "jp"
    assert prov["takeover"]["at"].endswith("+0000")
    assert prov["takeover"]["overrode"] == ["out_of_band", "concurrent"]
    assert prov["previous_sha256"] == changed
    assert prov["previous_user"] == "karen"


def test_reviewer_sandbox_writes_skip_guards(tmp_path, monkeypatch):
    multi(monkeypatch, start=PAST, mode="reviewer")
    out = tmp_path / "x.csv"
    save_as(monkeypatch, "karen", pd.DataFrame({"a": [1, 2]}), out)
    with open(out, "a", encoding="utf-8") as f:
        f.write("9\n")
    save_as(monkeypatch, "jp", pd.DataFrame({"a": [3]}), out)
    assert sidecar(out)["collaboration"] == "multi-producer"


# --- dw_set_collaboration ----------------------------------------------------

def test_set_collaboration_baselines_without_touching_fields(tmp_path, monkeypatch):
    (tmp_path / ".git").mkdir()
    monkeypatch.setattr(_state, "dw_collaboration_model", "single-producer")
    out = tmp_path / "sub" / "x.csv"
    save_as(monkeypatch, "karen", pd.DataFrame({"a": [1, 2], "b": ["x", "y"]}), out,
            metadata={"title": "T", "sources": ["A", "B"]})
    sc = Path(f"{out}.provenance.json")
    before_txt = sc.read_text(encoding="utf-8")
    before = json.loads(before_txt)
    monkeypatch.setenv("USERNAME", "jp")
    res = m.dw_set_collaboration("multi-producer", root=tmp_path, members=["jp", "karen"])
    assert res["project_file_changed"] is True
    assert res["sidecars_found"] == 1 and res["sidecars_updated"] == 1
    after_txt = sc.read_text(encoding="utf-8")
    after = json.loads(after_txt)
    assert {k: after[k] for k in before} == before
    assert after["sha256"] == sha(out)
    assert after["baseline"]["collaboration"] == "multi-producer"
    assert after["baseline"]["by"] == "jp"
    assert after_txt.startswith(before_txt.rstrip().rstrip("}").rstrip())
    yml = yaml.safe_load((tmp_path / "cso_project.yml").read_text(encoding="utf-8"))
    assert yml["schema"] == "cso_project/1"
    assert yml["collaboration"] == "multi-producer"
    assert yml["members"] == ["jp", "karen"]
    assert m.dw_collaboration() == "multi-producer"


def test_set_collaboration_is_idempotent(tmp_path, monkeypatch):
    (tmp_path / ".git").mkdir()
    monkeypatch.setattr(_state, "dw_collaboration_model", "single-producer")
    out = tmp_path / "x.csv"
    save_as(monkeypatch, "karen", pd.DataFrame({"a": [1]}), out)
    m.dw_set_collaboration("multi-producer", root=tmp_path, members=["jp"])
    files = [tmp_path / "cso_project.yml", Path(f"{out}.provenance.json")]
    snap = [f.read_bytes() for f in files]
    res = m.dw_set_collaboration("multi-producer", root=tmp_path, members=["jp"])
    assert res["project_file_changed"] is False and res["sidecars_updated"] == 0
    assert [f.read_bytes() for f in files] == snap
    m.dw_set_collaboration("multi-producer", root=tmp_path)    # members=None keeps
    assert [f.read_bytes() for f in files] == snap


def test_first_write_after_switch_is_silent_and_clean(tmp_path, monkeypatch, caplog):
    (tmp_path / ".git").mkdir()
    monkeypatch.setattr(_state, "dw_collaboration_model", "single-producer")
    monkeypatch.setattr(_state, "dw_session_start", FUTURE)
    out = tmp_path / "x.csv"
    save_as(monkeypatch, "karen", pd.DataFrame({"a": [1]}), out)
    old = sha(out)
    m.dw_set_collaboration("multi-producer", root=tmp_path)
    with caplog.at_level(logging.INFO, logger="cso_toolkit.dw_project"):
        save_as(monkeypatch, "jp", pd.DataFrame({"a": [2]}), out)
    assert "last written by" not in caplog.text
    prov = sidecar(out)
    assert prov["previous_sha256"] == old and "baseline" not in prov
    res = m.dw_set_collaboration("multi-producer", root=tmp_path)
    assert res["sidecars_updated"] == 0


def test_set_collaboration_refuses_reviewer_and_unknown_model(tmp_path, monkeypatch):
    monkeypatch.setattr(_state, "dw_mode", "reviewer")
    with pytest.raises(PermissionError, match=r"^\[cso_toolkit\.dw_set_collaboration\]"):
        m.dw_set_collaboration("multi-producer", root=tmp_path)
    assert not (tmp_path / "cso_project.yml").exists()
    monkeypatch.setattr(_state, "dw_mode", "producer")
    with pytest.raises(ValueError, match=r"^\[cso_toolkit\.dw_set_collaboration\].*"):
        m.dw_set_collaboration("three-producers", root=tmp_path)


def test_r_and_python_write_the_same_project_file(tmp_path, monkeypatch):
    """The rendered cso_project.yml is identical across languages."""
    from cso_toolkit.dw_project import _project_yaml
    txt = _project_yaml("multi-producer", "2026-11-20", ["jp", "karen"])
    assert txt.splitlines()[4:] == [
        "schema: cso_project/1", "collaboration: multi-producer",
        "collaboration_since: 2026-11-20", "members:", "  - jp", "  - karen",
    ]


# --- API cache ---------------------------------------------------------------

def test_refresh_over_other_users_cache_keeps_previous_fetch(tmp_path, monkeypatch, caplog):
    raw = tmp_path / "raw"
    raw.mkdir()
    multi(monkeypatch, start=FUTURE, mode="producer")
    for key, value in {"teamsRawData": str(raw), "teamsRawDataCanonical": str(raw),
                       "teamsWrkDataCanonical": str(raw), "dw_apis_allowed": True}.items():
        monkeypatch.setattr(_state, key, value, raising=False)
    calls = {"n": 0}

    def fake_fetch(**kwargs):
        calls["n"] += 1
        return pd.DataFrame({"a": [calls["n"]]})

    monkeypatch.setitem(dw_api._DISPATCH, "fake", fake_fetch)
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", DeprecationWarning)
        monkeypatch.setenv("USERNAME", "karen")
        m.dw_api_fetch("fake", cache_key="k")
        cache = raw / "_apis" / "fake" / "k.csv"
        karen = sidecar(cache)
        monkeypatch.setenv("USERNAME", "jp")
        assert m.dw_api_fetch("fake", cache_key="k")["a"].tolist() == [1]  # hit
        with caplog.at_level(logging.INFO, logger="cso_toolkit.dw_api"):
            m.dw_api_fetch("fake", cache_key="k", refresh=True)
    assert "refresh replaces the fetch by karen" in caplog.text
    prov = sidecar(cache)
    assert prov["metadata"]["previous_fetch"]["sha256"] == karen["sha256"]
    assert prov["metadata"]["previous_fetch"]["user"] == "karen"
    assert prov["previous_sha256"] == karen["sha256"]
    assert prov["user"] == "jp"


# --- profiles ----------------------------------------------------------------

def test_create_profile_emits_block_and_review_passes(tmp_path, capsys):
    (tmp_path / ".git").mkdir()
    write_project(tmp_path, "multi-producer")
    p = m.create_profile("collab", output_path=tmp_path)
    src = Path(p).read_text(encoding="utf-8")
    assert "dw_collaboration(" in src
    rev = m.review_profile(p, verbose=False)
    assert rev.loc[rev["check"] == "Collaboration model block", "status"].item() == "pass"


def test_review_profile_warns_for_multi_producer_without_block(tmp_path):
    (tmp_path / ".git").mkdir()
    p = Path(m.create_profile("old", output_path=tmp_path))
    lines = [ln for ln in p.read_text(encoding="utf-8").splitlines()
             if "dw_collaboration" not in ln]
    p.write_text("\n".join(lines) + "\n", encoding="utf-8")
    rev = m.review_profile(p, verbose=False)
    assert rev.loc[rev["check"] == "Collaboration model block", "status"].item() == "pass"
    write_project(tmp_path, "multi-producer")
    rev = m.review_profile(p, verbose=False)
    row = rev[rev["check"] == "Collaboration model block"].iloc[0]
    assert row["status"] == "warn" and "multi-producer" in row["detail"]


# --- #178: false alarms and the empty user -------------------------------------

import shutil
import subprocess

from cso_toolkit import dw_project


def git_repo(d: Path):
    if shutil.which("git") is None:
        pytest.skip("git not available")

    def git(*args):
        subprocess.run(["git", "-C", str(d), *args], check=True,
                       capture_output=True)
    git("init", "-q")
    git("config", "user.name", "test")
    git("config", "user.email", "test@example.org")
    git("config", "core.autocrlf", "false")
    return git


def test_178_write_arrived_through_git_is_not_concurrent(tmp_path, monkeypatch):
    git = git_repo(tmp_path)
    multi(monkeypatch, start=PAST)                  # karen writes after this start
    out = tmp_path / "x.csv"
    save_as(monkeypatch, "karen", pd.DataFrame({"a": [1, 2]}), out)
    git("add", "--", "x.csv", "x.csv.provenance.json")
    git("commit", "-q", "-m", "karen-output")       # what a pull would bring in
    save_as(monkeypatch, "jp", pd.DataFrame({"a": [5]}), out)
    assert sidecar(out)["previous_user"] == "karen"


def test_178_uncommitted_or_modified_write_is_still_concurrent(tmp_path, monkeypatch):
    git = git_repo(tmp_path)
    multi(monkeypatch, start=PAST)
    out = tmp_path / "x.csv"
    save_as(monkeypatch, "karen", pd.DataFrame({"a": [1, 2]}), out)
    with pytest.raises(PermissionError, match="concurrent write"):
        save_as(monkeypatch, "jp", pd.DataFrame({"a": [5]}), out)
    git("add", "--", "x.csv", "x.csv.provenance.json")
    git("commit", "-q", "-m", "karen-output")
    save_as(monkeypatch, "karen", pd.DataFrame({"a": [3, 4]}), out)
    with pytest.raises(PermissionError, match="concurrent write"):
        save_as(monkeypatch, "jp", pd.DataFrame({"a": [5]}), out)


def test_178_other_line_endings_are_not_out_of_band(tmp_path, monkeypatch, caplog):
    multi(monkeypatch, start=FUTURE)
    out = tmp_path / "x.csv"
    save_as(monkeypatch, "jp", pd.DataFrame({"a": [1, 2, 3], "b": ["x", "y", "z"]}), out)
    data = out.read_bytes()
    flipped = (data.replace(b"\r\n", b"\n") if b"\r" in data
               else data.replace(b"\n", b"\r\n"))
    out.write_bytes(flipped)
    with caplog.at_level(logging.INFO):
        save_as(monkeypatch, "jp", pd.DataFrame({"a": [5]}), out)
    assert "only in line endings" in caplog.text
    assert pd.read_csv(out)["a"].tolist() == [5]


def test_178_lf_checkout_of_crlf_output(tmp_path, monkeypatch):
    multi(monkeypatch, start=FUTURE)
    out = tmp_path / "x.txt"
    out.write_bytes(b"a\r\nb\r\n")
    Path(f"{out}.provenance.json").write_text(json.dumps({
        "path": str(out), "sha256": sha(out), "user": "karen",
        "written_at": "2001-01-01T00:00:00+0000"}), encoding="utf-8")
    out.write_bytes(b"a\nb\n")
    monkeypatch.setenv("USERNAME", "jp")
    dw_project._collab_preflight(str(out))           # no error


def test_178_real_change_in_crlf_checkout_is_still_out_of_band(tmp_path, monkeypatch):
    multi(monkeypatch, start=FUTURE)
    out = tmp_path / "x.csv"
    save_as(monkeypatch, "jp", pd.DataFrame({"a": [1, 2]}), out)
    lines = out.read_bytes().replace(b"\r\n", b"\n").splitlines()
    out.write_bytes(b"\r\n".join(lines + [b"9"]) + b"\r\n")
    with pytest.raises(PermissionError, match="out-of-band change"):
        save_as(monkeypatch, "jp", pd.DataFrame({"a": [5]}), out)


def test_178_binary_formats_get_no_line_ending_leniency(tmp_path):
    f = tmp_path / "x.parquet"
    f.write_bytes(bytes([1, 13, 10, 2]))
    assert dw_project._sha256_eol_variants(f) == []


def test_178_eol_variants_match_r(tmp_path):
    # Same bytes as the R test: the two variants are the LF and CRLF forms.
    f = tmp_path / "x.txt"
    f.write_bytes(b"a\r\nb\nc")
    lf, crlf = dw_project._sha256_eol_variants(f)
    assert lf == hashlib.sha256(b"a\nb\nc").hexdigest()
    assert crlf == hashlib.sha256(b"a\r\nb\r\nc").hexdigest()


def test_178_user_falls_back_when_username_is_unset(monkeypatch):
    for var in ("USERNAME", "LOGNAME", "USER", "LNAME"):
        monkeypatch.delenv(var, raising=False)
    monkeypatch.setenv("USER", "macuser")
    assert dw_project._current_user() == "macuser"
    monkeypatch.setenv("LOGNAME", "loguser")
    assert dw_project._current_user() == "loguser"
    monkeypatch.setenv("USERNAME", "winuser")
    assert dw_project._current_user() == "winuser"


def test_178_sidecar_records_user_without_username(tmp_path, monkeypatch):
    multi(monkeypatch, start=PAST)
    for var in ("USERNAME", "LOGNAME", "LNAME"):
        monkeypatch.delenv(var, raising=False)
    out = tmp_path / "x.csv"
    monkeypatch.setenv("USER", "karen")
    m.dw_save(pd.DataFrame({"a": [1, 2]}), path=str(out), overwrite=True)
    assert sidecar(out)["user"] == "karen"
    monkeypatch.setenv("USER", "jp")
    with pytest.raises(PermissionError, match="concurrent write"):
        m.dw_save(pd.DataFrame({"a": [5]}), path=str(out), overwrite=True)
