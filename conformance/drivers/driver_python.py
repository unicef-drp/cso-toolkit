#!/usr/bin/env python3
# =====================================================================
# Parity certificate driver -- Python
# ---------------------------------------------------------------------
# Runs the parity cases Python implements against the toolkit in this
# working tree (python/src copied in as `cso_toolkit`, never an installed
# package) and writes one output per case into <out_dir>: <id>.csv (kind
# "values") or <id>.json (kind "json"); a case that crashes writes
# <id>.error.txt. Mirror of driver_r.R.
#
# Usage: python conformance/drivers/driver_python.py \
#          <case_ids,comma,separated> <fixtures_dir> <out_dir>
# =====================================================================
from __future__ import annotations

import hashlib
import importlib
import json
import logging
import os
import shutil
import sys
import tempfile
import traceback
import warnings
from pathlib import Path

REPO = Path(os.environ.get("CERT_REPO", ".")).resolve()


def _bootstrap() -> Path:
    """Import python/src of this tree as cso_toolkit, ahead of any install."""
    tmp = Path(tempfile.mkdtemp(prefix="cso_cert_pypkg_"))
    shutil.copytree(REPO / "python" / "src", tmp / "cso_toolkit")
    sys.path.insert(0, str(tmp))
    return tmp


PKG_ROOT = _bootstrap()
import pandas as pd  # noqa: E402

import cso_toolkit as m  # noqa: E402
from cso_toolkit import _state as state  # noqa: E402

sync = importlib.import_module("cso_toolkit.cso_toolkit_sync")
logging.disable(logging.CRITICAL)
warnings.simplefilter("ignore")

case_ids = sys.argv[1].split(",")
fix_dir = Path(sys.argv[2]).resolve()
out_dir = Path(sys.argv[3]).resolve()
work = out_dir / "_work"
work.mkdir(parents=True, exist_ok=True)


def fx(name: str) -> str:
    return str(fix_dir / name)


def out_csv(df: pd.DataFrame, cid: str) -> None:
    df.to_csv(out_dir / f"{cid}.csv", index=False, encoding="utf-8")


def out_json(obj, cid: str) -> None:
    (out_dir / f"{cid}.json").write_text(json.dumps(obj, indent=2, ensure_ascii=False),
                                         encoding="utf-8")


def is_envelope(e: BaseException) -> bool:
    return str(e).startswith("[cso_toolkit.")


def plain() -> None:
    """A plain local session: no dw_mode, so no mirror pre-flight, no reviewer lock."""
    state.configure(dw_mode=None, dw_apis_allowed=None, teamsWrkDataCanonical=None,
                    teamsRawDataCanonical=None, teamsFolderCanonical=None,
                    dw_z_available=False, dw_collaboration_model="single-producer",
                    dw_session_start="2000-01-01T00:00:00+0000")


def roundtrip(fixture: str, ext: str, cid: str) -> None:
    plain()
    x = m.dw_use(fx(fixture))
    p = work / f"{cid}.{ext}"
    m.dw_save(x, path=str(p), overwrite=True, provenance=False)
    out_csv(m.dw_use(str(p)), cid)


def save_isid_duplicate(cid: str) -> None:
    plain()
    x = m.dw_use(fx("duplicate_keys.csv"))
    p = work / f"{cid}.csv"
    err = None
    try:
        m.dw_save(x, path=str(p), isid=["REF_AREA", "TIME_PERIOD"], overwrite=True,
                  provenance=False)
    except Exception as e:  # noqa: BLE001
        err = e
    out_json({"error": err is not None, "envelope": err is not None and is_envelope(err),
              "file_written": p.exists()}, cid)


def reviewer_refuses_api(cid: str) -> None:
    d = work / cid
    d.mkdir(exist_ok=True)
    state.configure(dw_mode="reviewer", dw_apis_allowed=False, teamsRawData=str(d),
                    teamsRawDataCanonical=str(d))
    err = None
    try:
        m.dw_api_fetch("csv", cache_key="never_cached", url="https://example.org/x.csv")
    except Exception as e:  # noqa: BLE001
        err = e
    plain()
    out_json({"refused": err is not None, "envelope": err is not None and is_envelope(err)}, cid)


def provenance_sidecar(cid: str) -> None:
    plain()
    x = m.dw_use(fx("indicators.csv"))
    p = work / f"{cid}.csv"
    m.dw_save(x, path=str(p), overwrite=True, provenance=True)
    sc = Path(str(p) + ".provenance.json")
    prov = json.loads(sc.read_text(encoding="utf-8")) if sc.exists() else {}
    req = ["path", "written_at", "user", "dw_mode", "sha256", "schema"]
    schema = prov.get("schema") or {}
    out_json({"sidecar": sc.exists(),
              "missing_keys": [k for k in req if k not in prov],
              "sha256_matches": prov.get("sha256") == hashlib.sha256(p.read_bytes()).hexdigest(),
              "rows": schema.get("rows"), "cols": schema.get("cols")}, cid)


def compare_counts(cid: str) -> None:
    plain()
    ref = m.dw_use(fx("compare_reference.csv"))
    cur = m.dw_use(fx("compare_current.csv"))
    r = m.dw_compare(cur, ref, by=["REF_AREA", "TIME_PERIOD"], value_cols=["OBS_VALUE"],
                     numeric_value_cols=["OBS_VALUE"], tol=1e-6)
    s = r["summary"].iloc[0] if isinstance(r, dict) else r.summary.iloc[0]
    out_json({"added": int(s["added"]), "removed": int(s["removed"]),
              "changed": int(s["changed"])}, cid)


def aggregate_weighted_mean(cid: str) -> None:
    plain()
    x = m.dw_use(fx("aggregate_input.csv"))
    a = m.aggregate_data_v2(x, value="value", weight="weight", by=["Region_Code"],
                            method="weighted_mean", global_=True, global_label="WORLD")
    out_csv(a, cid)


def version_compare(cid: str) -> None:
    case = json.loads((REPO / "conformance" / "cases" / f"{cid}.json").read_text(encoding="utf-8"))
    out_json({"behind": [sync._cso_version_behind(a, b) for a, b in case["pairs"]]}, cid)


def config_user_block(cid: str) -> None:
    import subprocess
    case = json.loads((REPO / "conformance" / "cases" / f"{cid}.json").read_text(encoding="utf-8"))
    d = work / cid
    (d / "repo" / ".git").mkdir(parents=True, exist_ok=True)
    profile = Path(m.create_profile(case["project"], output_path=d / "repo"))
    modes = []
    for i, f in enumerate(case["fixtures"], start=1):
        home = d / f"home{i}"
        (home / ".config").mkdir(parents=True, exist_ok=True)
        shutil.copyfile(fx(f), home / ".config" / "user_config.yml")
        env = dict(os.environ, USERNAME=case["user"], USER=case["user"], USERPROFILE=str(home),
                   PYTHONPATH=str(PKG_ROOT) + os.pathsep + os.environ.get("PYTHONPATH", ""))
        code = (f"exec(compile(open({str(profile)!r}, encoding='utf-8').read(), 'profile', 'exec'));"
                "print(f'MODE={dw_mode}')")
        res = subprocess.run([sys.executable, "-c", code], cwd=d / "repo", env=env,
                             capture_output=True, text=True)
        hit = [ln for ln in res.stdout.splitlines() if ln.startswith("MODE=")]
        modes.append(hit[0][len("MODE="):] if res.returncode == 0 and hit else None)
    out_json({"modes": modes}, cid)


def compare_diagnose(cid: str) -> None:
    plain()
    ref = m.dw_use(fx("compare_reference.csv"))
    cur = m.dw_use(fx("compare_current.csv"))
    p = m.dw_compare(cur, ref, by=["REF_AREA", "TIME_PERIOD"], value_cols=["OBS_VALUE"],
                     numeric_value_cols=["OBS_VALUE"], tol=1e-6, diagnose=True)["profile"]
    mag = p["magnitude"].set_index("column")
    def vals(df):
        return df.loc[df["key"] == "REF_AREA", "value"].tolist()
    out_json({"columns": p["columns"]["column"].tolist(),
              "n_changed": [int(x) for x in p["columns"]["n_changed"]],
              "rel_q50": float(mag.loc["OBS_VALUE", "rel_q50"]),
              "keys": vals(p["keys"]), "added": vals(p["added"]), "removed": vals(p["removed"])}, cid)


def compare_same_file(cid: str) -> None:
    plain()
    p = fx("compare_reference.csv")
    err = None
    try:
        m.dw_compare(p, p, by=["REF_AREA", "TIME_PERIOD"])
    except Exception as e:  # noqa: BLE001
        err = e
    out_json({"refused": err is not None, "envelope": err is not None and is_envelope(err)}, cid)


def deposit_fetch_inputs(cid: str) -> None:
    plain()
    local = work / cid / "local"
    shutil.rmtree(local, ignore_errors=True)
    mf = m.dw_fetch_inputs(local, "inputs", pattern=r"_20(23|24|25)\.csv$",
                           teams_root=str(fix_dir / "deposit" / "teams"), z_root=None,
                           verbose=False)
    out_csv(mf[["file", "sha256", "origin", "teams", "z"]], cid)


def provenance_diff_status(cid: str) -> None:
    plain()
    d = work / cid
    d.mkdir(parents=True, exist_ok=True)
    p = d / "out.csv"
    for f in (p, Path(str(p) + ".provenance.json")):
        f.unlink(missing_ok=True)

    def inp(files, shas):
        return pd.DataFrame({"file": files, "sha256": shas})

    def run(df, inputs):
        meta = {"title": "parity"}
        if inputs is not None:
            meta["inputs"] = inputs
        m.dw_save(df, path=str(p), metadata=meta, overwrite=True)

    df1 = pd.DataFrame({"k": ["x", "y"], "v": [1.0, 2.0]})
    in1 = inp(["a.csv", "b.csv"], ["aaa", "bbb"])
    st = []
    run(df1, in1)
    st.append(m.dw_provenance_diff(None, p, verbose=False)["status"])
    prev = m.dw_read_provenance(p, verbose=False)
    run(df1, in1)
    st.append(m.dw_provenance_diff(prev, p, verbose=False)["status"])
    prev = m.dw_read_provenance(p, verbose=False)
    run(df1.assign(v=df1["v"] * 10), in1)
    st.append(m.dw_provenance_diff(prev, p, warn=False, verbose=False)["status"])
    prev = m.dw_read_provenance(p, verbose=False)
    run(df1, inp(["a.csv", "c.csv"], ["aaa2", "ccc"]))
    r4 = m.dw_provenance_diff(prev, p, verbose=False)
    st.append(r4["status"])
    prev = m.dw_read_provenance(p, verbose=False)
    run(df1, None)
    st.append(m.dw_provenance_diff(prev, p, verbose=False)["status"])
    out_json({"statuses": st, "inputs_added": r4["inputs_added"],
              "inputs_removed": r4["inputs_removed"], "inputs_changed": r4["inputs_changed"]}, cid)


def collab_out_of_band(cid: str) -> None:
    plain()
    state.configure(dw_collaboration_model="multi-producer",
                    dw_session_start="2999-01-01T00:00:00+0000")
    old = os.environ.get("USERNAME")
    os.environ["USERNAME"] = "certify"
    try:
        p = work / f"{cid}.csv"
        for f in (p, Path(str(p) + ".provenance.json")):
            f.unlink(missing_ok=True)
        m.dw_save(pd.DataFrame({"a": [1, 2]}), path=str(p), overwrite=True)
        with open(p, "a", encoding="utf-8") as fh:
            fh.write("9\n")                                # changed without dw_save()
        err = None
        try:
            m.dw_save(pd.DataFrame({"a": [5]}), path=str(p), overwrite=True)
        except Exception as e:  # noqa: BLE001
            err = e
        m.dw_save(pd.DataFrame({"a": [5]}), path=str(p), overwrite=True, takeover=True)
        back = m.dw_use(str(p))
        out_json({"blocked": err is not None, "envelope": err is not None and is_envelope(err),
                  "takeover_written": len(back) == 1 and int(back["a"].iloc[0]) == 5}, cid)
    finally:
        if old is None:
            os.environ.pop("USERNAME", None)
        else:
            os.environ["USERNAME"] = old
        plain()


CASES = {
    "io_roundtrip_csv": lambda cid: roundtrip("indicators.csv", "csv", cid),
    "io_roundtrip_dta": lambda cid: roundtrip("indicators.csv", "dta", cid),
    "io_edge_values": lambda cid: roundtrip("edge_values.csv", "csv", cid),
    "save_isid_duplicate": save_isid_duplicate,
    "reviewer_refuses_api": reviewer_refuses_api,
    "provenance_sidecar": provenance_sidecar,
    "compare_counts": compare_counts,
    "aggregate_weighted_mean": aggregate_weighted_mean,
    "version_compare": version_compare,
    "config_user_block": config_user_block,
    "compare_diagnose": compare_diagnose,
    "compare_same_file": compare_same_file,
    "deposit_fetch_inputs": deposit_fetch_inputs,
    "provenance_diff_status": provenance_diff_status,
    "collab_out_of_band": collab_out_of_band,
}

for cid in case_ids:
    fn = CASES.get(cid)
    if fn is None:
        continue                                           # not implemented in Python
    try:
        fn(cid)
    except Exception:  # noqa: BLE001
        (out_dir / f"{cid}.error.txt").write_text(traceback.format_exc(), encoding="utf-8")

out_json({"language": "python", "version": sys.version.split()[0],
          "toolkit": m.dw_toolkit_version()}, "_versions")
