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


def lint_repo(tmp: Path, cases: dict, retired: str = "", mkdirs: bool = True) -> list:
    (tmp / "conformance" / "cases").mkdir(parents=True, exist_ok=not mkdirs)
    (tmp / "conformance" / "fixtures").mkdir(exist_ok=not mkdirs)
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


def test_lint_needs_the_required_fields_and_an_object(tmp_path):
    bare = {"id": "v", "title": "t", "kind": "values", "fixtures": [], "languages": ["r"]}
    (tmp_path / "conformance" / "cases").mkdir(parents=True)
    (tmp_path / "conformance" / "fixtures").mkdir()
    (tmp_path / "conformance" / "cases" / "v.json").write_text(json.dumps(bare), encoding="utf-8")
    (tmp_path / "conformance" / "cases" / "l.json").write_text("[1, 2]", encoding="utf-8")
    errs = certify.lint_cases(tmp_path)
    assert "v.json: missing columns, keys" in errs
    assert any(e.startswith("l.json: a case is a JSON object") for e in errs)


def git_commit_all(root: Path) -> None:
    import subprocess
    for args in (["init", "-q"], ["add", "-A"],
                 ["-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q",
                  "-m", "c"]):
        subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True)


def test_a_certified_case_cannot_vanish_without_retiring_its_id(tmp_path):
    (tmp_path / ".parity").mkdir()
    (tmp_path / ".parity" / "old.json").write_text(
        json.dumps({"cases": {"good": {}, "dropped": {}, "retired_one": {}, "broken": {}}}),
        encoding="utf-8")
    (tmp_path / ".parity" / "bad.json").write_text('{"cases": null}', encoding="utf-8")
    (tmp_path / "conformance" / "cases").mkdir(parents=True)
    (tmp_path / "conformance" / "cases" / "broken.json").write_text("{not json", encoding="utf-8")
    git_commit_all(tmp_path)
    (tmp_path / ".parity" / "untracked.json").write_text(
        json.dumps({"cases": {"only_on_disk": {}}}), encoding="utf-8")
    (tmp_path / "conformance" / "cases" / "broken.json").unlink()
    (tmp_path / "conformance" / "cases" / "broken.json").write_text("{not json", encoding="utf-8")
    errs = lint_repo(tmp_path, {"good": case(id="good")},
                     retired="retired_one 2026-11-24 merged into good\n", mkdirs=False)
    assert any(e.startswith("broken.json: not JSON") for e in errs)
    assert any(e.startswith(".parity/bad.json: a committed certificate that cannot") for e in errs)
    gone = [e for e in errs if "is in a committed certificate" in e]
    assert len(gone) == 1 and gone[0].startswith("dropped.json: id 'dropped'")   # not broken, not untracked
    assert len(errs) == 3


def test_lint_checks_the_register_tolerance_and_reference(tmp_path):
    errs = lint_repo(tmp_path, {
        "a": case(id="a", languages=["r", "python"], gaps={"stata": {"reason": "r"}}),
        "b": case(id="b", languages=["r", "python"], gaps={"stata": "coverage matrix"}),
        "c": case(id="c", divergences=["stata"]),
        "d": case(id="d", kind="values", columns=["k"], keys=["k"], tolerance="tight"),
        "e": case(id="e", kind="values", columns=["k"], keys=["k"], reference="fixture"),
        "f": case(id="f", languages="r,python,stata"),
    })
    by = {e.split(":")[0]: e for e in errs}
    assert sorted(by) == ["a.json", "b.json", "c.json", "d.json", "e.json", "f.json"]
    assert "gaps.stata` needs string `issue` and `reason`" in by["a.json"]
    assert "gaps.stata` needs string" in by["b.json"]
    assert "`divergences` must be an object" in by["c.json"]
    assert "`tolerance` must be a non-negative number" in by["d.json"]
    assert "needs a fixture" in by["e.json"]
    assert "must be lists" in by["f.json"]


# Stata's own suites ---------------------------------------------------------

def test_the_certificate_covers_the_stata_suites():
    assert "stata/tests" in certify.CERT_PATHS
    assert [s.name for s in certify.stata_suites(HERE.parent)] == sorted(
        p.name for p in (HERE.parent / "stata" / "tests").glob("test_*.do"))
    assert certify.lint_suites(HERE.parent) == []


def test_lint_needs_the_completion_line_last(tmp_path):
    t = tmp_path / "stata" / "tests"
    t.mkdir(parents=True)
    (t / "test_ok.do").write_text(f"assert 1\n{certify.DONE_LINE}\n* a trailing comment\n\n",
                                  encoding="utf-8")
    (t / "test_early.do").write_text(f"{certify.DONE_LINE}\nassert 1\n", encoding="utf-8")
    (t / "test_none.do").write_text("assert 1\n", encoding="utf-8")
    (t / "test_block.do").write_text(f"assert 1\n/*\n{certify.DONE_LINE}\n*/\n", encoding="utf-8")
    (t / "test_cont.do").write_text(f"assert 1\n* a note ///\n{certify.DONE_LINE}\n",
                                    encoding="utf-8")
    (t / "test_inline.do").write_text(f"assert 1\n{certify.DONE_LINE}  // done\n", encoding="utf-8")
    (t / "test_exit.do").write_text(f"{certify.DONE_LINE}\nexit\n", encoding="utf-8")
    errs = certify.lint_suites(tmp_path)
    assert sorted(e.split(":")[0] for e in errs) == [
        "stata/tests/test_block.do", "stata/tests/test_cont.do", "stata/tests/test_early.do",
        "stata/tests/test_exit.do", "stata/tests/test_none.do"]


def test_the_wrapper_captures_the_suite_and_writes_its_return_code(tmp_path):
    w = certify.suite_wrapper(tmp_path, tmp_path / "stata/tests/test_x.do", tmp_path / "x.result")
    lines = w.splitlines()
    assert lines[0] == "global cert_suite_done"
    assert lines[1] == f'cd "{tmp_path.as_posix()}"'
    assert lines[2].startswith("capture noisily do ") and "test_x.do" in lines[2]
    assert "local cert_rc = _rc" in lines and 'local cert_done "$cert_suite_done"' in lines
    assert f'"{(tmp_path / "x.result").as_posix()}"' in w
    assert "\"rc `cert_rc' done `cert_done'\"" in w


def test_suites_pass_fail_exit_missing_and_not_run(tmp_path):
    (tmp_path / "ok.result").write_text("rc 0 done 1\n", encoding="utf-8")
    (tmp_path / "bad.result").write_text("rc 9 done\n", encoding="utf-8")
    (tmp_path / "exited.result").write_text("rc 0 done\n", encoding="utf-8")
    res = certify.judge_suites(["ok", "bad", "exited", "died"], tmp_path, None)
    assert {k: v["status"] for k, v in res.items()} == {"ok": "pass", "bad": "fail",
                                                         "exited": "fail", "died": "missing"}
    assert res["bad"]["note"].startswith("r(9)")
    assert "before its last line" in res["exited"]["note"]
    assert "no result file" in res["died"]["note"]
    res = certify.judge_suites(["ok"], tmp_path, "Stata not found (set STATA_EXE)")
    assert res["ok"] == {"status": "not_run", "note": "Stata not found (set STATA_EXE)"}


def test_verify_reads_the_certificate_from_the_commit(tmp_path, capsys):
    import subprocess
    g = lambda *a: subprocess.run(["git", "-C", str(tmp_path), *a], check=True,
                                  capture_output=True, text=True).stdout.strip()
    g("init", "-q")
    for p in certify.CERT_PATHS:
        f = tmp_path / p / "x" if "." not in Path(p).name else tmp_path / p
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text("x\n", encoding="utf-8")
    g("add", "-A")
    g("-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q", "-m", "a")
    first = g("rev-parse", "HEAD")
    h, _ = certify.content_hash(tmp_path)
    (tmp_path / ".parity").mkdir()
    (tmp_path / ".parity" / f"{h}.json").write_text(
        json.dumps({"result": "pass", "content_hash": h}), encoding="utf-8")
    assert certify.verify(tmp_path) == 1          # on disk but not committed: not enough
    g("add", "-A")
    g("-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q", "-m", "cert")
    assert certify.verify(tmp_path) == 0
    assert certify.verify(tmp_path, first) == 1   # the earlier commit does not carry it
    (tmp_path / "r" / "R" / "x").write_text("changed\n", encoding="utf-8")
    g("-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q", "-am", "code")
    assert certify.verify(tmp_path) == 1
    assert certify.verify(tmp_path, "HEAD~1") == 0
    h2, _ = certify.content_hash(tmp_path)
    (tmp_path / ".parity" / f"{h2}.json").write_text("{not json", encoding="utf-8")
    g("add", "-A")
    g("-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q", "-m", "bad")
    assert certify.verify(tmp_path) == 1          # a FAIL line, not a traceback
    assert "is not a valid certificate" in capsys.readouterr().out
