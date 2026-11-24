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
    assert list((HERE / "cases").glob("*.json"))
    assert certify.lint_cases(HERE.parent) == []


def lint_repo(tmp: Path, cases: dict, retired: str = "") -> list:
    (tmp / "conformance" / "cases").mkdir(parents=True)
    (tmp / "conformance" / "fixtures").mkdir()
    for name, c in cases.items():
        (tmp / "conformance" / "cases" / f"{name}.json").write_text(json.dumps(c), encoding="utf-8")
    if retired:
        (tmp / "conformance" / "retired_ids.txt").write_text(retired, encoding="utf-8")
    return certify.lint_cases(tmp)


def test_lint_names_a_wrong_id_a_retired_id_and_a_bad_register(tmp_path):
    errs = lint_repo(tmp_path, {
        "good": case(id="good"),
        "renamed": case(id="old_name"),
        "gone": case(id="gone"),
        "both": case(id="both", gaps={"stata": {"issue": "#1", "reason": "r"}}),
    }, retired="# comment\ngone 2026-11-24 merged into good\n")
    assert len(errs) == 3
    assert any(e.startswith("renamed.json: id 'old_name' is not the file name") for e in errs)
    assert any(e.startswith("gone.json: id 'gone' is retired") for e in errs)
    assert any(e.startswith("both.json: stata must be in") for e in errs)


def test_lint_checks_fixtures_and_kinds(tmp_path):
    errs = lint_repo(tmp_path, {
        "v": case(id="v", kind="values", fixtures=["absent.csv"], columns=["a"], keys=["b"]),
        "j": case(id="j", expect={}),
    })
    assert sorted(e.split(":")[0] for e in errs) == ["j.json", "v.json", "v.json"]


# Stata's own suites ---------------------------------------------------------

def test_the_certificate_covers_the_stata_suites():
    assert "stata/tests" in certify.CERT_PATHS
    assert [s.name for s in certify.stata_suites(HERE.parent)] == sorted(
        p.name for p in (HERE.parent / "stata" / "tests").glob("test_*.do"))


def test_the_wrapper_captures_the_suite_and_writes_its_return_code(tmp_path):
    w = certify.suite_wrapper(tmp_path, tmp_path / "stata/tests/test_x.do", tmp_path / "x.result")
    lines = w.splitlines()
    assert lines[0] == f'cd "{tmp_path.as_posix()}"'
    assert lines[1].startswith("capture noisily do ") and "test_x.do" in lines[1]
    assert "local cert_rc = _rc" in lines
    assert f'"{(tmp_path / "x.result").as_posix()}"' in w and "\"rc `cert_rc'\"" in w


def test_suites_pass_fail_missing_and_not_run(tmp_path):
    (tmp_path / "ok.result").write_text("rc 0\n", encoding="utf-8")
    (tmp_path / "bad.result").write_text("rc 9\n", encoding="utf-8")
    res = certify.judge_suites(["ok", "bad", "died"], tmp_path, None)
    assert {k: v["status"] for k, v in res.items()} == {"ok": "pass", "bad": "fail",
                                                         "died": "missing"}
    assert res["bad"]["note"].startswith("r(9)")
    assert "no result file" in res["died"]["note"]
    res = certify.judge_suites(["ok"], tmp_path, "Stata not found (set STATA_EXE)")
    assert res["ok"] == {"status": "not_run", "note": "Stata not found (set STATA_EXE)"}
