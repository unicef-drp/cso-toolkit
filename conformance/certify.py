#!/usr/bin/env python3
"""Parity certificate: run every case in R, Python and Stata and compare.

    sh tools/certify              run the cases; print PASS / FAIL per case and language
    sh tools/certify --record     if all pass in all three languages, write and
                                  commit .parity/<content-hash>.json
    sh tools/certify --verify     no R, Python or Stata: is there a passing
                                  certificate for this tree?
    sh tools/certify --lint       no language: are the case files well formed?

With Stata, a full run also runs Stata's own test suites, stata/tests/test_*.do,
each in its own batch Stata, and records them in the certificate.

Standard library only, so any Python 3.8+ runs it. The Python *driver* needs
the toolkit's dependencies (pandas, PyYAML, ...): it runs under CSO_PYTHON when
that is set, else under this interpreter. R comes from CSO_RSCRIPT or the PATH
(on Windows also C:/Program Files/R/R-*/bin), Stata from STATA_EXE or the
usual install folders. See conformance/README.md and the handbook appendix
"Cross-language parity" (#190).
"""
from __future__ import annotations

import argparse
import datetime as dt
import glob
import hashlib
import json
import math
import os
import platform
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

LANGS = ("r", "python", "stata")
REFERENCE = "r"
# What a certificate is about: the three implementations and the harness.
# Docs (README, handbook) are left out, so editing them keeps the certificate.
CERT_PATHS = ("r/R", "python/src", "stata/src", "stata/tests", "conformance/certify.py",
              "conformance/cases", "conformance/drivers", "conformance/fixtures")
CERT_DIR = ".parity"
SCHEMA = "cso_toolkit.parity/2"
BAD = {"fail", "error", "missing", "unexpected"}
# Case ids are permanent: certificates and the gap register name cases by id,
# so an id once used is never given to a different case. A removed case's id
# goes here, with the date and the reason, and can never come back.
RETIRED = "conformance/retired_ids.txt"
SUITE_TIMEOUT = 900


# --------------------------------------------------------------------------
# git and the content hash
# --------------------------------------------------------------------------

def git(repo: Path, *args: str, check: bool = True) -> str:
    res = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)
    if check and res.returncode != 0:
        sys.exit(f"[certify] git {' '.join(args)} failed: {res.stderr.strip()}")
    return res.stdout.strip()


def content_hash(repo: Path) -> tuple:
    """SHA-256 over the git trees of CERT_PATHS at HEAD (doc-only changes keep it)."""
    trees = {p: git(repo, "rev-parse", f"HEAD:{p}") for p in CERT_PATHS}
    text = "".join(f"{p} {t}\n" for p, t in trees.items())
    return hashlib.sha256(text.encode("utf-8")).hexdigest(), trees


def dirty(repo: Path) -> list:
    out = git(repo, "status", "--porcelain", "--untracked-files=all", "--", *CERT_PATHS)
    return [ln for ln in out.splitlines() if ln.strip()]


# --------------------------------------------------------------------------
# finding the three languages
# --------------------------------------------------------------------------

def find_rscript() -> str | None:
    if os.environ.get("CSO_RSCRIPT"):
        return os.environ["CSO_RSCRIPT"]
    hit = shutil.which("Rscript")
    if hit:
        return hit
    cands = sorted(glob.glob("C:/Program Files/R/R-*/bin/Rscript.exe"))
    return cands[-1] if cands else None


def find_stata() -> str | None:
    if os.environ.get("STATA_EXE"):
        return os.environ["STATA_EXE"]
    pats = ["C:/Users/Public/Software/Stata*/Stata*-64.exe", "C:/Program Files/Stata*/Stata*-64.exe",
            "/Applications/Stata/Stata*.app/Contents/MacOS/stata-*",
            "/usr/local/stata*/stata-mp", "/usr/local/stata*/stata-se", "/usr/local/stata*/stata"]
    for pat in pats:
        cands = sorted(glob.glob(pat))
        if cands:
            return cands[-1]
    return None


def run(cmd: list, cwd: Path, env: dict, log: Path, timeout: int = 1800) -> int:
    with open(log, "w", encoding="utf-8", errors="replace") as fh:
        try:
            res = subprocess.run(cmd, cwd=str(cwd), env=env, stdout=fh, stderr=subprocess.STDOUT,
                                 timeout=timeout)
            return res.returncode
        except subprocess.TimeoutExpired:
            fh.write(f"\n[certify] timed out after {timeout} s\n")
            return 124


def run_drivers(repo: Path, cases: list, out: Path, langs: list) -> dict:
    """Run each language's driver; return {lang: why-not-run or None}."""
    ids = [c["id"] for c in cases]
    fix = repo / "conformance" / "fixtures"
    drv = repo / "conformance" / "drivers"
    env = dict(os.environ, CERT_REPO=str(repo), PYTHONUTF8="1")
    status = {}
    for lang in langs:
        d = out / lang
        d.mkdir(parents=True, exist_ok=True)
        if lang == "r":
            rs = find_rscript()
            if not rs:
                status[lang] = "Rscript not found (set CSO_RSCRIPT)"
                continue
            renv = dict(env)
            if os.name == "nt":
                # Git Bash's HOME hides R's own home (Documents), where .Renviron lives.
                renv.pop("HOME", None)
            rc = run([rs, "--no-init-file", str(drv / "driver_r.R"), ",".join(ids), str(fix), str(d)],
                     repo, renv, out / "r.log")
        elif lang == "python":
            py = os.environ.get("CSO_PYTHON") or sys.executable
            rc = run([py, str(drv / "driver_python.py"), ",".join(ids), str(fix), str(d)],
                     repo, env, out / "python.log")
        else:
            st = find_stata()
            if not st:
                status[lang] = "Stata not found (set STATA_EXE)"
                continue
            do = d / "_run.do"
            do.write_text("\n".join([
                f'global CERT_CASES "{" ".join(ids)}"',
                f'global CERT_FIX "{fix.as_posix()}"',
                f'global CERT_OUT "{d.as_posix()}"',
                f'global CERT_ADO "{(repo / "stata" / "src").as_posix()}/"',
                f'do "{(drv / "driver_stata.do").as_posix()}"', ""]), encoding="utf-8")
            flag = "/e" if os.name == "nt" else "-b"
            rc = run([st, flag, "do", str(do)], d, env, out / "stata.console.log")
            if (d / "_run.log").exists():
                shutil.copyfile(d / "_run.log", out / "stata.log")
        status[lang] = None if rc == 0 else f"driver exited {rc} (see {out / (lang + '.log')})"
        if rc != 0 and any((d / f"{i}.{e}").exists() for i in ids for e in ("csv", "json")):
            status[lang] = None          # partial run: judge the outputs it wrote
    return status


# --------------------------------------------------------------------------
# Stata's own test suites (stata/tests/test_*.do)
# --------------------------------------------------------------------------
#
# Batch Stata always exits 0, and its log echoes the source, so a suite's
# "PASS:" line appears in the log even when the suite stopped before reaching
# it. The verdict therefore comes from a file only execution can create: a
# wrapper runs the suite under -capture- and then writes its return code to
# <suite>.result. A missing result file is a failure, not a skip: it means
# Stata stopped or timed out before the wrapper's last lines.

def stata_suites(repo: Path) -> list:
    return sorted((repo / "stata" / "tests").glob("test_*.do"))


def suite_wrapper(repo: Path, suite: Path, result: Path) -> str:
    return "\n".join([
        f'cd "{repo.as_posix()}"',
        f'capture noisily do "{suite.as_posix()}"',
        "local cert_rc = _rc",
        "tempname cert_fh",
        f'file open `cert_fh\' using "{result.as_posix()}", write text replace',
        "file write `cert_fh' \"rc `cert_rc'\" _n",
        "file close `cert_fh'",
        ""])


def run_suites(repo: Path, out: Path, stata: str, env: dict) -> None:
    """Run every suite in its own batch Stata; each leaves <out>/stata_suites/<name>.result."""
    d = out / "stata_suites"
    d.mkdir(parents=True, exist_ok=True)
    flag = "/e" if os.name == "nt" else "-b"
    for suite in stata_suites(repo):
        result = d / f"{suite.stem}.result"
        if result.exists():
            result.unlink()
        wrap = d / f"{suite.stem}.do"
        wrap.write_text(suite_wrapper(repo, suite, result), encoding="utf-8")
        print(f"[certify] Stata suite {suite.name} ...", flush=True)
        run([stata, flag, "do", str(wrap)], d, env, d / f"{suite.stem}.console.log",
            timeout=SUITE_TIMEOUT)


def judge_suites(names: list, d: Path, why_not: str | None) -> dict:
    """{suite: {status, note}} from the .result files in d."""
    res = {}
    for name in names:
        if why_not:
            res[name] = {"status": "not_run", "note": why_not}
            continue
        p = d / f"{name}.result"
        log = (d / f"{name}.log").as_posix()
        if not p.exists():
            res[name] = {"status": "missing", "note": "no result file: Stata stopped or timed "
                         f"out before the suite returned (see {log})"}
            continue
        text = p.read_text(encoding="utf-8", errors="replace").strip()
        rc = text[3:].strip() if text.startswith("rc ") else ""
        if rc == "0":
            res[name] = {"status": "pass", "note": ""}
        else:
            res[name] = {"status": "fail", "note": f"r({rc or '?'}) (see {log})"}
    return res


# --------------------------------------------------------------------------
# the case files
# --------------------------------------------------------------------------

def retired_ids(repo: Path) -> set:
    p = repo / RETIRED
    if not p.exists():
        return set()
    lines = p.read_text(encoding="utf-8").splitlines()
    return {ln.split()[0] for ln in lines if ln.strip() and not ln.lstrip().startswith("#")}


def lint_cases(repo: Path) -> list:
    """Every problem with conformance/cases/*.json, as 'file: message'; empty when well formed."""
    errs, retired = [], retired_ids(repo)
    for p in sorted((repo / "conformance" / "cases").glob("*.json")):
        try:
            c = json.loads(p.read_text(encoding="utf-8"))
        except ValueError as e:
            errs.append(f"{p.name}: not JSON: {e}")
            continue
        cid = c.get("id")
        if cid != p.stem:
            errs.append(f"{p.name}: id {cid!r} is not the file name")
        if cid in retired:
            errs.append(f"{p.name}: id {cid!r} is retired ({RETIRED}); give the case a new id")
        kind = c.get("kind")
        if kind not in ("values", "json"):
            errs.append(f"{p.name}: kind {kind!r} is neither 'values' nor 'json'")
        for lang in LANGS:
            if (lang in c.get("languages", [])) == (lang in c.get("gaps", {})):
                errs.append(f"{p.name}: {lang} must be in `languages` or in `gaps`, not both "
                            "or neither")
        for f in c.get("fixtures", []):
            if not (repo / "conformance" / "fixtures" / f).exists():
                errs.append(f"{p.name}: fixture {f} does not exist")
        if kind == "values" and not set(c.get("keys", [])) <= set(c.get("columns", [])):
            errs.append(f"{p.name}: every key must be one of the columns")
        if kind == "json" and not (isinstance(c.get("expect"), dict) and c["expect"]):
            errs.append(f"{p.name}: a json case needs a non-empty `expect`")
    return errs


# --------------------------------------------------------------------------
# comparison
# --------------------------------------------------------------------------

def read_csv(path: Path) -> tuple:
    import csv
    with open(path, encoding="utf-8-sig", newline="") as fh:
        rows = list(csv.reader(fh))
    if not rows:
        return [], []
    return [h.strip().lower() for h in rows[0]], rows[1:]


def cell(v: str):
    s = (v or "").strip()
    if s in ("", "NA", "NaN", "nan", ".", "None"):
        return ("na", "")
    try:
        f = float(s)
        if math.isfinite(f):
            return ("num", f)
    except ValueError:
        pass
    return ("str", s)


def key_str(c) -> str:
    return format(c[1], ".15g") if c[0] == "num" else str(c[1])


def same(a, b, tol: float) -> bool:
    if a[0] != b[0]:
        return False
    if a[0] == "num":
        return abs(a[1] - b[1]) <= tol * max(1.0, abs(a[1]), abs(b[1]))
    return a[1] == b[1]


def table(path: Path, case: dict) -> tuple:
    """Rows of normalised cells for the case's columns, sorted by its keys."""
    head, rows = read_csv(path)
    cols = [c.lower() for c in case["columns"]]
    miss = [c for c in cols if c not in head]
    if miss:
        return None, f"missing column(s) {miss}"
    idx = [head.index(c) for c in cols]
    kidx = [cols.index(k.lower()) for k in case["keys"]]
    norm = [[cell(r[i] if i < len(r) else "") for i in idx] for r in rows]
    norm.sort(key=lambda r: [key_str(r[k]) for k in kidx])
    return norm, None


FIXTURES = Path(__file__).resolve().parent / "fixtures"


def repo_fixture(case: dict) -> Path:
    return FIXTURES / case["fixtures"][0]


def compare_values(case: dict, path: Path, ref, ref_name: str = REFERENCE) -> str | None:
    got, err = table(path, case)
    if err:
        return err
    if case.get("rows") is not None and len(got) != case["rows"]:
        return f"{len(got)} rows, expected {case['rows']}"
    if ref is None:
        return None
    if len(got) != len(ref):
        return f"{len(got)} rows vs {len(ref)} in {ref_name}"
    tol = float(case.get("tolerance", 1e-9))
    for i, (a, b) in enumerate(zip(got, ref)):
        for j, (x, y) in enumerate(zip(a, b)):
            if not same(x, y, tol):
                return (f"row {i + 1}, {case['columns'][j]}: {x[1]!r} vs {y[1]!r} in {ref_name}")
    return None


def canon(x):
    if isinstance(x, bool) or x is None or isinstance(x, str):
        return x
    if isinstance(x, (int, float)):
        return float(x)
    if isinstance(x, list):
        return [canon(v) for v in x]
    if isinstance(x, dict):
        return {k: canon(v) for k, v in sorted(x.items())}
    return x


def compare_json(case: dict, path: Path) -> str | None:
    try:
        got = json.loads(path.read_text(encoding="utf-8-sig"))
    except ValueError as e:
        return f"not JSON: {e}"
    want = case["expect"]
    diffs = [k for k in want if canon(got.get(k)) != canon(want[k])]
    if diffs:
        return "; ".join(f"{k}: {json.dumps(got.get(k))} (expected {json.dumps(want[k])})"
                         for k in diffs)
    return None


def sha_file(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def judge(cases: list, out: Path, ran: dict) -> dict:
    results = {}
    for case in cases:
        cid, kind = case["id"], case["kind"]
        ext = "csv" if kind == "values" else "json"
        # The reference: the fixture itself for a round trip (every language,
        # R included, must give back the input), else R's output.
        ref, ref_name = None, REFERENCE
        if kind == "values" and case.get("reference") == "fixture":
            ref, ref_name = table(repo_fixture(case), case)[0], "the fixture"
        elif kind == "values":
            rp = out / REFERENCE / f"{cid}.csv"
            if rp.exists():
                ref, _ = table(rp, case)
        res = {}
        for lang in LANGS:
            gap = case.get("gaps", {}).get(lang)
            div = case.get("divergences", {}).get(lang)
            p = out / lang / f"{cid}.{ext}"
            e = out / lang / f"{cid}.error.txt"
            if lang not in case["languages"] and not gap:
                res[lang] = {"status": "error", "note": "case lists this language neither in "
                             "`languages` nor in `gaps`"}
                continue
            if lang not in ran:
                res[lang] = {"status": "not_run", "note": "not requested"}
                continue
            if ran[lang] is not None:
                res[lang] = {"status": "not_run", "note": ran[lang]}
                continue
            if gap:
                if p.exists():
                    res[lang] = {"status": "unexpected", "note": f"listed as a gap ({gap['issue']}) "
                                 "but now implemented: remove it from `gaps`"}
                else:
                    res[lang] = {"status": "gap", "note": f"{gap['issue']}: {gap['reason']}"}
                continue
            if e.exists():
                msg = e.read_text(encoding="utf-8", errors="replace").strip().splitlines()
                res[lang] = {"status": "error", "note": (msg[-1] if msg else "error")[:300]}
                continue
            if not p.exists():
                res[lang] = {"status": "missing", "note": "the driver wrote no output for this case"}
                continue
            is_ref = lang == REFERENCE and ref_name == REFERENCE
            why = compare_values(case, p, None if is_ref else ref, ref_name) if kind == "values" \
                else compare_json(case, p)
            if kind == "values" and not is_ref and ref is None:
                why = why or f"no {ref_name} output to compare with"
            if div:
                st = "divergence" if why else "unexpected"
                note = f"{div['issue']}: {div['reason']}" + (f" ({why})" if why else
                                                             " -- now agrees: remove it from `divergences`")
            else:
                st, note = ("fail", why) if why else ("pass", "")
            res[lang] = {"status": st, "note": note, "sha256": sha_file(p)}
        results[cid] = {"title": case["title"], "kind": kind, "results": res}
    return results


# --------------------------------------------------------------------------
# reporting, recording, verifying
# --------------------------------------------------------------------------

LABEL = {"pass": "PASS", "fail": "FAIL", "gap": "gap", "divergence": "DIVERGES", "error": "ERROR",
         "missing": "MISSING", "unexpected": "UPDATE-REGISTER", "not_run": "not run"}


def report(results: dict) -> dict:
    w = max(len(c) for c in results) + 2
    print(f"{'case':<{w}}" + "".join(f"{lang:<16}" for lang in LANGS))
    counts: dict = {}
    for cid, r in results.items():
        line = f"{cid:<{w}}"
        for lang in LANGS:
            st = r["results"][lang]["status"]
            counts[st] = counts.get(st, 0) + 1
            line += f"{LABEL[st]:<16}"
        print(line)
    notes = [(cid, lang, r["results"][lang]["note"]) for cid, r in results.items()
             for lang in LANGS if r["results"][lang]["status"] not in ("pass",)
             and r["results"][lang].get("note")]
    if notes:
        print("\nnotes:")
        for cid, lang, note in notes:
            print(f"  {cid} [{lang}] {note}")
    return counts


def report_suites(suites: dict) -> dict:
    counts: dict = {}
    if suites:
        print("\nStata suites (stata/tests)")
    for name, r in suites.items():
        counts[r["status"]] = counts.get(r["status"], 0) + 1
        print(f"  {name:<28}{LABEL[r['status']]:<10}{r['note']}")
    return counts


def verify(repo: Path) -> int:
    h, _ = content_hash(repo)
    p = repo / CERT_DIR / f"{h}.json"
    if not p.exists():
        print(f"[certify] FAIL no certificate for this tree ({CERT_DIR}/{h}.json).\n"
              "  Fix: run `sh tools/certify --record` with R, Python and Stata available, "
              "then push the commit it makes.")
        return 1
    cert = json.loads(p.read_text(encoding="utf-8"))
    if cert.get("result") != "pass" or cert.get("content_hash") != h:
        print(f"[certify] FAIL {p.name} does not record a pass for this tree.")
        return 1
    suites = cert.get("suites_summary")
    print(f"[certify] PASS certificate {h[:12]} ({cert.get('created_at')}, "
          f"{cert.get('summary')}" + (f", Stata suites {suites}" if suites else "") + ")")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--record", action="store_true", help="write and commit the certificate")
    ap.add_argument("--verify", action="store_true", help="check a certificate exists; run nothing")
    ap.add_argument("--lint", action="store_true", help="check the case files; run nothing")
    ap.add_argument("--languages", default=",".join(LANGS), help="subset, e.g. r,python")
    ap.add_argument("--cases", default="", help="only these case ids (comma separated); "
                    "skips the Stata suites")
    ap.add_argument("--out", default="", help="output folder (default: a new temporary one)")
    a = ap.parse_args()

    repo = Path(git(Path.cwd(), "rev-parse", "--show-toplevel"))
    errs = lint_cases(repo)
    if errs:
        print("[certify] FAIL: the case files are not well formed")
        for e in errs:
            print(f"  conformance/cases/{e}")
        return 1
    if a.lint:
        print(f"[certify] PASS: {len(list((repo / 'conformance' / 'cases').glob('*.json')))} "
              "case files well formed, no retired id reused")
        return 0
    if a.verify:
        return verify(repo)

    langs = [x for x in a.languages.split(",") if x]
    bad = [x for x in langs if x not in LANGS]
    if bad:
        sys.exit(f"[certify] unknown language(s) {bad}; choose from {LANGS}")
    if a.record and set(langs) != set(LANGS):
        sys.exit("[certify] --record needs all three languages.")
    if a.record and a.cases:
        sys.exit("[certify] --record runs every case: drop --cases.")
    if a.record and dirty(repo):
        sys.exit("[certify] --record needs a clean tree under " + ", ".join(CERT_PATHS) +
                 ": commit first.\n" + "\n".join(dirty(repo)))

    cases = [json.loads(p.read_text(encoding="utf-8"))
             for p in sorted((repo / "conformance" / "cases").glob("*.json"))]
    if a.cases:
        want = set(a.cases.split(","))
        cases = [c for c in cases if c["id"] in want]
    out = Path(a.out).resolve() if a.out else Path(tempfile.mkdtemp(prefix="cso_parity_"))
    out.mkdir(parents=True, exist_ok=True)
    print(f"[certify] {len(cases)} case(s), languages {', '.join(langs)}; outputs in {out}\n")

    ran = run_drivers(repo, cases, out, langs)
    names = [s.stem for s in stata_suites(repo)]
    stata = find_stata()
    why_not = ("Stata not requested (--languages)" if "stata" not in langs else
               "only some cases requested (--cases)" if a.cases else
               None if stata else "Stata not found (set STATA_EXE)")
    if why_not is None:
        run_suites(repo, out, stata, dict(os.environ, PYTHONUTF8="1"))
    suites = judge_suites(names, out / "stata_suites", why_not)
    results = judge(cases, out, ran)
    counts = report(results)
    scounts = report_suites(suites)
    failed = sum(counts.get(s, 0) for s in BAD) + sum(scounts.get(s, 0) for s in BAD)
    complete = all(ran.get(lang, "x") is None for lang in LANGS) and why_not is None
    result = "pass" if failed == 0 and complete else ("fail" if failed else "incomplete")
    print(f"\n[certify] {result.upper()}: " + ", ".join(f"{v} {LABEL[k].lower()}"
                                                     for k, v in sorted(counts.items()))
          + ("; Stata suites: " + ", ".join(f"{v} {LABEL[k].lower()}"
                                            for k, v in sorted(scounts.items()))
             if scounts else ""))
    if not a.record:
        return 0 if failed == 0 else 1
    if result != "pass":
        print("[certify] no certificate written: every case must pass (or be a listed gap or "
              "divergence) in all three languages, and every Stata suite must pass.")
        return 1

    h, trees = content_hash(repo)
    versions = {}
    for lang in LANGS:
        vp = out / lang / "_versions.json"
        if vp.exists():
            try:
                versions[lang] = json.loads(vp.read_text(encoding="utf-8-sig"))
            except ValueError:
                versions[lang] = {"raw": vp.read_text(encoding="utf-8", errors="replace").strip()}
    cert = {
        "schema": SCHEMA,
        "content_hash": h,
        "trees": trees,
        "commit": git(repo, "rev-parse", "HEAD"),
        "created_at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "created_by": git(repo, "config", "user.name", check=False),
        "platform": platform.platform(),
        "versions": versions,
        "result": result,
        "summary": {k: v for k, v in sorted(counts.items())},
        "suites_summary": {k: v for k, v in sorted(scounts.items())},
        "cases": results,
        "stata_suites": suites,
    }
    d = repo / CERT_DIR
    d.mkdir(exist_ok=True)
    p = d / f"{h}.json"
    p.write_text(json.dumps(cert, indent=2, ensure_ascii=False) + "\n", encoding="utf-8",
                 newline="\n")
    git(repo, "add", "--", str(p.relative_to(repo).as_posix()))
    git(repo, "commit", "-q", "-m", f"Parity certificate {h[:12]}", "--",
        str(p.relative_to(repo).as_posix()))
    print(f"[certify] committed {CERT_DIR}/{p.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
