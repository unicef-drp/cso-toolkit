*! test_collab_guards.do -- multi-producer guards in Stata dw_save (#168).
*
* Mirrors r/tests/testthat/test-dw_project.R and
* python/tests/test_dw_project.py: in a multi-producer project
* (cso_project.yml) dw_save stops on an out-of-band change or a concurrent
* write unless -takeover-, a write that arrived through git is not
* concurrent, a follow-on write only prints a note, reviewer mode skips the
* guards, and a project without the file is single-producer. Needs Stata's
* Python integration (Stata 16+) and git.
*
* A local gate (no Stata runner in CI, #133). From the repository root:
*     do stata/tests/test_collab_guards.do

version 16
clear all
local repo = subinstr(c(pwd), "\", "/", .)
adopath ++ "`repo'/stata/src/"
global dw_mode ""

* Helpers --------------------------------------------------------------
program define _proj
    * _proj <dir> <model>: a repository folder with cso_project.yml.
    args d model
    capture mkdir "`d'"
    capture mkdir "`d'/.git"
    if "`model'" != "" {
        tempname fh
        file open `fh' using "`d'/cso_project.yml", write text replace
        file write `fh' "schema: cso_project/1" _n "collaboration: `model'" _n "collaboration_since: 2026-11-20" _n
        file close `fh'
    }
end

program define _data
    args n
    clear
    set obs `n'
    gen id = _n
    gen v = _n * 10
end

program define _sidecar, rclass
    * r(user), r(sha_ok), r(keys): the sidecar of <file>.dta, read in Python.
    args f
    python: import json, sfi, hashlib; p = sfi.Macro.getLocal("f"); d = json.load(open(p + ".provenance.json", encoding="utf-8")); sfi.Macro.setLocal("u", d.get("user", "")); sfi.Macro.setLocal("ok", "1" if d.get("sha256") == hashlib.sha256(open(p, "rb").read()).hexdigest() else "0"); sfi.Macro.setLocal("k", " ".join(sorted(d))); sfi.Macro.setLocal("over", " ".join((d.get("takeover") or {}).get("overrode", [])))
    return local user "`u'"
    return local sha_ok "`ok'"
    return local keys "`k'"
    return local overrode "`over'"
end

program define _set_sidecar_user
    * Rewrite the sidecar's user and written_at (as if someone else wrote it).
    args f user at
    python: import json, sfi; p = sfi.Macro.getLocal("f") + ".provenance.json"; d = json.load(open(p, encoding="utf-8")); d["user"] = sfi.Macro.getLocal("user"); d["written_at"] = sfi.Macro.getLocal("at"); json.dump(d, open(p, "w", encoding="utf-8"), indent=2)
end

tempfile base
local root "`base'_collab"
local root = subinstr("`root'", "\", "/", .)
capture mkdir "`root'"

* 1. No cso_project.yml: single-producer; the sidecar has sha256 and an ISO time.
local d "`root'/single"
_proj "`d'" ""
cd "`d'"
dw_collaboration, refresh
assert "`r(model)'" == "single-producer"
_data 3
dw_save, filename(x) path("`d'") idvars(id)
_sidecar "`d'/x.dta"
assert "`r(sha_ok)'" == "1"
assert !strpos("`r(keys)'", "collaboration")     // no lineage fields
python: import json, sfi; t = json.load(open(sfi.Macro.getLocal("d") + "/x.dta.provenance.json", encoding="utf-8"))["written_at"]; sfi.Macro.setLocal("t", t)
assert ustrregexm("`t'", "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\+0000$")

* 2. Out-of-band change: stops, file untouched; takeover writes and records it.
local d "`root'/oob"
_proj "`d'" "multi-producer"
cd "`d'"
dw_collaboration, refresh
assert "`r(model)'" == "multi-producer"
global dw_session_start "2999-01-01T00:00:00+0000"
_data 2
dw_save, filename(x) path("`d'") idvars(id)
_data 5
quietly save "`d'/x.dta", replace                   // changed without dw_save
_data 1
capture noisily dw_save, filename(x) path("`d'") idvars(id)
assert _rc == 459
use "`d'/x.dta", clear
assert _N == 5                                       // the out-of-band bytes are still there
_data 1
dw_save, filename(x) path("`d'") idvars(id) takeover
_sidecar "`d'/x.dta"
assert "`r(overrode)'" == "out_of_band"
assert strpos("`r(keys)'", "previous_sha256") & strpos("`r(keys)'", "collaboration")

* 3. Concurrent write: someone else wrote it after this session started.
local d "`root'/conc"
_proj "`d'" "multi-producer"
cd "`d'"
dw_collaboration, refresh
global dw_session_start "2000-01-01T00:00:00+0000"
_data 2
dw_save, filename(x) path("`d'") idvars(id)
_set_sidecar_user "`d'/x.dta" "karen" "2026-11-20T10:00:00+0000"
_data 3
capture noisily dw_save, filename(x) path("`d'") idvars(id)
assert _rc == 459
dw_save, filename(x) path("`d'") idvars(id) takeover
_sidecar "`d'/x.dta"
assert "`r(overrode)'" == "concurrent"

* 4. A follow-on write (karen wrote before this session started): a note only.
global dw_session_start "2999-01-01T00:00:00+0000"
_set_sidecar_user "`d'/x.dta" "karen" "2026-11-20T10:00:00+0000"
_data 4
dw_save, filename(x) path("`d'") idvars(id)

* 5. Arrived through git: committed and unmodified, so not concurrent (#178).
local d "`root'/git"
_proj "`d'" "multi-producer"
capture rmdir "`d'/.git"
cd "`d'"
python: import subprocess, sfi; d = sfi.Macro.getLocal("d"); [subprocess.run(["git", "-C", d] + a, check=True, capture_output=True) for a in (["init", "-q"], ["config", "user.email", "t@example.org"], ["config", "user.name", "t"])]
dw_collaboration, refresh
global dw_session_start "2000-01-01T00:00:00+0000"
_data 2
dw_save, filename(x) path("`d'") idvars(id)
_set_sidecar_user "`d'/x.dta" "karen" "2026-11-20T10:00:00+0000"
python: import subprocess, sfi; d = sfi.Macro.getLocal("d"); [subprocess.run(["git", "-C", d] + a, check=True, capture_output=True) for a in (["add", "x.dta", "x.dta.provenance.json"], ["commit", "-q", "-m", "karen-output"])]
_data 3
dw_save, filename(x) path("`d'") idvars(id)                // no takeover needed
* ...but the same write, uncommitted, is concurrent again.
_set_sidecar_user "`d'/x.dta" "karen" "2026-11-20T11:00:00+0000"
_data 4
capture noisily dw_save, filename(x) path("`d'") idvars(id)
assert _rc == 459

* 6. Reviewer mode skips the guards.
local d "`root'/rev"
_proj "`d'" "multi-producer"
cd "`d'"
dw_collaboration, refresh
global dw_session_start "2999-01-01T00:00:00+0000"
_data 2
dw_save, filename(x) path("`d'") idvars(id)
_data 5
quietly save "`d'/x.dta", replace
global dw_mode "reviewer"
_data 1
dw_save, filename(x) path("`d'") idvars(id)
global dw_mode ""

* 7. An invalid collaboration value stops.
local d "`root'/bad"
_proj "`d'" "two-producer"
cd "`d'"
capture noisily dw_collaboration, refresh
assert _rc == 459

macro drop dw_collaboration_model dw_project_file dw_session_start
cd "`repo'"
display as result "PASS: Stata dw_save multi-producer guards (out-of-band, concurrent, git, follow-on, reviewer, takeover)."
