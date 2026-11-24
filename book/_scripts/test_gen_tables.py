"""Tests for book/_scripts/gen_tables.py: the docs drift check fails when it should.

    python -m pytest book/_scripts
"""
from __future__ import annotations

import copy
import importlib.util
import json
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("gen_tables", HERE / "gen_tables.py")
gt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gt)

NOTES = json.loads(gt.NOTES.read_text(encoding="utf-8"))


def _errors(notes: dict) -> list:
    return gt.coverage(notes)[2]


def test_the_committed_notes_agree_with_the_code():
    assert _errors(NOTES) == []


def test_an_export_without_a_row_is_an_error():
    n = copy.deepcopy(NOTES)
    for sec in n["sections"]:
        if "dw_stage" in sec["rows"]:
            sec["rows"].remove("dw_stage")
    errs = _errors(n)
    assert any("`dw_stage` is exported" in e and "has no row" in e for e in errs)


def test_a_row_for_a_function_that_does_not_exist_is_an_error():
    n = copy.deepcopy(NOTES)
    n["sections"][0]["rows"].append("dw_no_such_function")
    assert any("dw_no_such_function" in e for e in _errors(n))


def test_a_note_denying_an_existing_function_is_an_error():
    n = copy.deepcopy(NOTES)
    n["functions"]["dw_stage"]["python"] = "No (R only)"
    assert any("exists in Python" in e for e in _errors(n))


def test_a_missing_language_needs_a_note():
    n = copy.deepcopy(NOTES)
    del n["functions"]["dw_regions"]["python"]
    assert any("`dw_regions` is not in Python" in e for e in _errors(n))


def test_a_note_claiming_a_missing_function_exists_is_an_error():
    n = copy.deepcopy(NOTES)
    n["functions"]["dw_regions"]["python"] = "Yes"
    assert any("starts with \"Yes\"" in e for e in _errors(n))


def test_check_mode_fails_on_a_stale_file(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(gt, "OUT", tmp_path)
    monkeypatch.setattr("sys.argv", ["gen_tables.py"])
    assert gt.main() == 0                       # write a fresh copy
    (tmp_path / "api-keys.md").write_text("edited by hand\n", encoding="utf-8")
    (tmp_path / "leftover.md").write_text("x\n", encoding="utf-8")
    monkeypatch.setattr("sys.argv", ["gen_tables.py", "--check"])
    assert gt.main() == 1
    out = capsys.readouterr().out
    assert "api-keys.md (out of date or missing)" in out
    assert "leftover.md (no longer generated)" in out


def test_every_api_key_is_in_both_languages_and_described():
    keys = gt.api_keys()
    assert len(keys) == len(NOTES["api_keys"])
    assert all(v["r"] and v["python"] for v in keys.values())


def test_rule_counts_match_the_registries():
    rules = gt.audit_rules()
    assert sum(1 for v in rules.values() if v["r"] is not None) >= 16
    assert sum(1 for v in rules.values() if v["python"] is not None) >= 19
