"""Self-tests for conformance/certify.py: the comparison and the register.

No R, Python driver or Stata is run: each test writes the outputs a driver
would have written and checks how certify.py judges them.
    python -m pytest conformance/tests
"""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("certify", HERE / "certify.py")
certify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(certify)


def case(**kw) -> dict:
    base = dict(id="c", title="t", kind="json", fixtures=[], expect={"ok": True},
                languages=["r", "python", "stata"], gaps={}, divergences={})
    base.update(kw)
    return base


def write(out: Path, lang: str, name: str, text: str) -> None:
    (out / lang).mkdir(parents=True, exist_ok=True)
    (out / lang / name).write_text(text, encoding="utf-8")


ALL_RAN = {"r": None, "python": None, "stata": None}


def statuses(res: dict, cid: str = "c") -> dict:
    return {lang: res[cid]["results"][lang]["status"] for lang in certify.LANGS}


def test_numbers_compare_within_tolerance_and_missing_is_empty():
    assert certify.same(certify.cell("1e+05"), certify.cell("100000"), 1e-9)
    assert certify.same(certify.cell("2020"), certify.cell("2020.0"), 1e-9)
    assert not certify.same(certify.cell("0.5"), certify.cell("0.5001"), 1e-9)
    assert certify.cell("") == certify.cell("NA") == certify.cell(".") == ("na", "")
    assert not certify.same(certify.cell("1"), certify.cell(""), 1e-9)


def test_json_case_pass_fail_missing_and_error(tmp_path):
    write(tmp_path, "r", "c.json", '{"ok": true}')
    write(tmp_path, "python", "c.json", '{"ok": false}')
    write(tmp_path, "stata", "c.error.txt", "Stata error r(198)")
    st = statuses(certify.judge([case()], tmp_path, ALL_RAN))
    assert st == {"r": "pass", "python": "fail", "stata": "error"}
    (tmp_path / "stata" / "c.error.txt").unlink()
    assert statuses(certify.judge([case()], tmp_path, ALL_RAN))["stata"] == "missing"


def test_gap_and_a_gap_that_closed(tmp_path):
    c = case(languages=["r", "python"], gaps={"stata": {"issue": "#1", "reason": "none"}})
    write(tmp_path, "r", "c.json", '{"ok": true}')
    write(tmp_path, "python", "c.json", '{"ok": true}')
    assert statuses(certify.judge([c], tmp_path, ALL_RAN))["stata"] == "gap"
    write(tmp_path, "stata", "c.json", '{"ok": true}')
    assert statuses(certify.judge([c], tmp_path, ALL_RAN))["stata"] == "unexpected"


def test_divergence_and_a_divergence_that_resolved(tmp_path):
    c = case(divergences={"stata": {"issue": "#2", "reason": "known"}})
    for lang in ("r", "python"):
        write(tmp_path, lang, "c.json", '{"ok": true}')
    write(tmp_path, "stata", "c.json", '{"ok": false}')
    assert statuses(certify.judge([c], tmp_path, ALL_RAN))["stata"] == "divergence"
    write(tmp_path, "stata", "c.json", '{"ok": true}')
    assert statuses(certify.judge([c], tmp_path, ALL_RAN))["stata"] == "unexpected"


def test_a_language_neither_listed_nor_a_gap_is_an_error(tmp_path):
    c = case(languages=["r", "python"])
    for lang in ("r", "python"):
        write(tmp_path, lang, "c.json", '{"ok": true}')
    assert statuses(certify.judge([c], tmp_path, ALL_RAN))["stata"] == "error"


def test_values_against_r_and_against_the_fixture(tmp_path, monkeypatch):
    head = "K,V\n"
    write(tmp_path, "r", "v.csv", head + "a,1\nb,2\n")
    write(tmp_path, "python", "v.csv", head + "b,2.0\na,1\n")        # order and format differ
    write(tmp_path, "stata", "v.csv", "k,v\na,1\nb,3\n")              # header case differs
    c = case(id="v", kind="values", keys=["K"], columns=["K", "V"], tolerance=1e-9, rows=2)
    del c["expect"]
    st = statuses(certify.judge([c], tmp_path, ALL_RAN), "v")
    assert st == {"r": "pass", "python": "pass", "stata": "fail"}
    # Against the fixture: R is judged too.
    fix = tmp_path / "fixtures"
    fix.mkdir()
    (fix / "f.csv").write_text(head + "a,1\nb,3\n", encoding="utf-8")
    monkeypatch.setattr(certify, "FIXTURES", fix)
    c.update(reference="fixture", fixtures=["f.csv"])
    st = statuses(certify.judge([c], tmp_path, ALL_RAN), "v")
    assert st == {"r": "fail", "python": "fail", "stata": "pass"}


def test_a_language_that_did_not_run(tmp_path):
    write(tmp_path, "r", "c.json", '{"ok": true}')
    write(tmp_path, "python", "c.json", '{"ok": true}')
    ran = {"r": None, "python": None, "stata": "Stata not found (set STATA_EXE)"}
    res = certify.judge([case()], tmp_path, ran)
    assert statuses(res)["stata"] == "not_run"
    assert "STATA_EXE" in res["c"]["results"]["stata"]["note"]


def test_every_shipped_case_is_well_formed():
    ids = set()
    for p in sorted((HERE / "cases").glob("*.json")):
        c = json.loads(p.read_text(encoding="utf-8"))
        assert c["id"] == p.stem and c["id"] not in ids
        ids.add(c["id"])
        assert c["kind"] in ("values", "json")
        for lang in certify.LANGS:
            assert (lang in c["languages"]) != (lang in c.get("gaps", {})), (p.name, lang)
        for f in c["fixtures"]:
            assert (HERE / "fixtures" / f).exists(), (p.name, f)
        if c["kind"] == "values":
            assert set(c["keys"]) <= set(c["columns"])
        else:
            assert isinstance(c["expect"], dict) and c["expect"]
