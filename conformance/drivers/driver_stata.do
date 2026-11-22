*===================================================================
* Parity certificate driver -- Stata
*-------------------------------------------------------------------
* Runs the parity cases Stata implements against the ado files in this
* working tree (stata/src) and writes one output per case into
* $CERT_OUT: <id>.csv (kind "values") or <id>.json (kind "json"); a case
* that stops writes <id>.error.txt. Mirror of driver_r.R.
*
* conformance/certify.py writes a small do-file that sets the globals
* below, then runs this one in batch (Windows: StataMP-64.exe /e do ...).
*   CERT_CASES  case ids, space separated
*   CERT_FIX    conformance/fixtures
*   CERT_OUT    output folder for this language
*   CERT_ADO    stata/src
*===================================================================

version 17
clear all
set more off
set varabbrev off
adopath ++ "$CERT_ADO"
global dw_mode ""
capture mkdir "$CERT_OUT/_work"
global CERT_WORK "$CERT_OUT/_work"

* ---- helpers -------------------------------------------------------

* Write one line of JSON as <id>.json.
program define _cert_json
    syntax , id(string) body(string asis)
    tempname fh
    file open `fh' using "$CERT_OUT/`id'.json", write text replace
    file write `fh' `body' _n
    file close `fh'
end

* Run a command under capture; return its rc and whether its output
* carried the [cso_toolkit.<fn>] envelope (Stata cannot catch the text
* of an error, so the command runs inside a log that is then searched).
program define _cert_try, rclass
    syntax , id(string) cmd(string asis)
    local lf "$CERT_WORK/`id'_try.log"
    capture log close _certtry
    quietly log using "`lf'", text replace name(_certtry)
    capture noisily `cmd'
    local rc = _rc
    quietly log close _certtry
    local env 0
    tempname fh
    file open `fh' using "`lf'", read text
    file read `fh' line
    while r(eof) == 0 {
        if strpos(`"`macval(line)'"', "[cso_toolkit.") local env 1
        file read `fh' line
    }
    file close `fh'
    return scalar rc = `rc'
    return scalar envelope = `env'
end

program define _cert_bool, rclass
    args x
    return local s = cond(`x', "true", "false")
end

* Export the data in memory as <id>.csv, numbers at full precision.
program define _cert_export
    args id
    quietly ds, has(type numeric)
    if "`r(varlist)'" != "" format `r(varlist)' %24.17g
    export delimited using "$CERT_OUT/`id'.csv", replace datafmt
end

* Read a fixture with dw_use, save it with dw_save (Stata writes .dta),
* read it back with dw_use and export it.
program define _cert_roundtrip
    args fixture id keys
    dw_use, filename(`fixture') path("$CERT_FIX")
    capture rename *, upper
    dw_save, filename(`id') path("$CERT_WORK") idvars(`keys') nosidecar
    dw_use, filename(`id'.dta) path("$CERT_WORK")
    _cert_export `id'
end

* ---- cases ---------------------------------------------------------

program define case_io_roundtrip_csv
    _cert_roundtrip indicators.csv io_roundtrip_csv "REF_AREA INDICATOR SEX AGE TIME_PERIOD"
end

program define case_io_roundtrip_dta
    _cert_roundtrip indicators.csv io_roundtrip_dta "REF_AREA INDICATOR SEX AGE TIME_PERIOD"
end

program define case_io_edge_values
    _cert_roundtrip edge_values.csv io_edge_values "REF_AREA TIME_PERIOD"
end

program define case_save_isid_duplicate
    local id save_isid_duplicate
    dw_use, filename(duplicate_keys.csv) path("$CERT_FIX")
    capture rename *, upper
    capture erase "$CERT_WORK/`id'.dta"
    _cert_try, id(`id') cmd(dw_save, filename(`id') path("$CERT_WORK") idvars(REF_AREA TIME_PERIOD) nosidecar)
    local err = r(rc) != 0
    local env = r(envelope)
    capture confirm file "$CERT_WORK/`id'.dta"
    local written = _rc == 0
    _cert_bool `err'
    local s_err `r(s)'
    _cert_bool `env'
    local s_env `r(s)'
    _cert_bool `written'
    local s_wr `r(s)'
    _cert_json, id(`id') body(`"{"error": `s_err', "envelope": `s_env', "file_written": `s_wr'}"')
end

program define case_reviewer_refuses_api
    local id reviewer_refuses_api
    global dw_mode "reviewer"
    _cert_try, id(`id') cmd(dw_require_no_api, context(certify))
    local refused = r(rc) != 0
    local env = r(envelope)
    global dw_mode ""
    _cert_bool `refused'
    local s_ref `r(s)'
    _cert_bool `env'
    local s_env `r(s)'
    _cert_json, id(`id') body(`"{"refused": `s_ref', "envelope": `s_env'}"')
end

program define case_provenance_sidecar
    local id provenance_sidecar
    dw_use, filename(indicators.csv) path("$CERT_FIX")
    capture rename *, upper
    dw_save, filename(`id') path("$CERT_WORK") idvars(REF_AREA INDICATOR SEX AGE TIME_PERIOD)
    local sc "$CERT_WORK/`id'.dta.provenance.json"
    capture confirm file "`sc'"
    local have = _rc == 0
    local rows "null"
    local cols "null"
    local found ""
    if `have' {
        tempname fh
        file open `fh' using "`sc'", read text
        file read `fh' line
        while r(eof) == 0 {
            foreach k in path written_at user dw_mode sha256 schema {
                if strpos(`"`macval(line)'"', `""`k'":"') local found `found' `k'
            }
            if ustrregexm(`"`macval(line)'"', `""rows": *([0-9]+)"') local rows = ustrregexs(1)
            if ustrregexm(`"`macval(line)'"', `""cols": *([0-9]+)"') local cols = ustrregexs(1)
            file read `fh' line
        }
        file close `fh'
    }
    local missing ""
    foreach k in path written_at user dw_mode sha256 schema {
        local in : list k in found
        if !`in' {
            if `"`missing'"' != "" local missing `"`missing', "'
            local missing `"`missing'"`k'""'
        }
    }
    * Stata has no sha256 of its own: a sidecar without the key cannot match.
    local shaok : list posof "sha256" in found
    local shaok = `shaok' > 0
    if `shaok' {
        * Verify through Stata's Python integration when the key exists.
        python: import hashlib, json, sfi; p = sfi.Macro.getLocal("sc"); d = json.load(open(p, encoding="utf-8")); f = p[:-len(".provenance.json")]; sfi.Macro.setLocal("shaok", "1" if d.get("sha256") == hashlib.sha256(open(f, "rb").read()).hexdigest() else "0")
    }
    _cert_bool `have'
    local s_have `r(s)'
    _cert_bool `shaok'
    local s_sha `r(s)'
    _cert_json, id(`id') body(`"{"sidecar": `s_have', "missing_keys": [`missing'], "sha256_matches": `s_sha', "rows": `rows', "cols": `cols'}"')
end

program define case_compare_counts
    local id compare_counts
    import delimited using "$CERT_FIX/compare_reference.csv", clear varnames(1) case(preserve) asdouble
    quietly save "$CERT_WORK/cmp_ref.dta", replace
    import delimited using "$CERT_FIX/compare_current.csv", clear varnames(1) case(preserve) asdouble
    quietly save "$CERT_WORK/cmp_cur.dta", replace
    dw_compare, current("$CERT_WORK/cmp_cur.dta") reference("$CERT_WORK/cmp_ref.dta") ///
        idvars(REF_AREA TIME_PERIOD) valuevars(OBS_VALUE) tol(1e-6)
    _cert_json, id(`id') body(`"{"added": `=r(n_added)', "removed": `=r(n_removed)', "changed": `=r(n_changed)'}"')
end

program define case_config_user_block
    * The fixtures, user and project of cases/config_user_block.json, in
    * its order (Stata reads no JSON; a reordered case fails visibly).
    local id config_user_block
    local body ""
    foreach f in user_block project_override other_project flat top_level_map missing {
        macro drop dw_mode
        capture dw_load_config, filepath("$CERT_FIX/config/`f'.yml") user(tester) project(proj-x)
        local rc = _rc
        if `"`body'"' != "" local body `"`body', "'
        if `rc' local body `"`body'null"'
        else local body `"`body'"$dw_mode""'
    }
    global dw_mode ""
    _cert_json, id(`id') body(`"{"modes": [`body']}"')
end

program define case_collab_out_of_band
    local id collab_out_of_band
    local d "$CERT_WORK/`id'"
    capture mkdir "`d'"
    capture mkdir "`d'/.git"
    tempname fh
    file open `fh' using "`d'/cso_project.yml", write text replace
    file write `fh' "schema: cso_project/1" _n "collaboration: multi-producer" _n
    file close `fh'
    dw_collaboration, root("`d'") refresh
    global dw_session_start "2999-01-01T00:00:00+0000"
    capture erase "`d'/x.dta"
    capture erase "`d'/x.dta.provenance.json"
    clear
    set obs 2
    gen a = _n
    dw_save, filename(x) path("`d'") idvars(a)
    gen b = 9
    quietly save "`d'/x.dta", replace                  // changed without dw_save
    clear
    set obs 1
    gen a = 5
    _cert_try, id(`id') cmd(dw_save, filename(x) path("`d'") idvars(a))
    local blocked = r(rc) != 0
    local env = r(envelope)
    dw_save, filename(x) path("`d'") idvars(a) takeover
    use "`d'/x.dta", clear
    local ok = (_N == 1 & a[1] == 5)
    * Back to the plain session the other cases expect.
    global dw_collaboration_model "single-producer"
    global dw_project_file ""
    global dw_session_start ""
    _cert_bool `blocked'
    local s_b `r(s)'
    _cert_bool `env'
    local s_e `r(s)'
    _cert_bool `ok'
    local s_ok `r(s)'
    _cert_json, id(`id') body(`"{"blocked": `s_b', "envelope": `s_e', "takeover_written": `s_ok'}"')
end

program define case_compare_same_file
    local id compare_same_file
    import delimited using "$CERT_FIX/compare_reference.csv", clear varnames(1) case(preserve) asdouble
    quietly save "$CERT_WORK/same.dta", replace
    _cert_try, id(`id') cmd(dw_compare, current("$CERT_WORK/same.dta") reference("$CERT_WORK/same.dta") idvars(REF_AREA TIME_PERIOD))
    local refused = r(rc) != 0
    local env = r(envelope)
    _cert_bool `refused'
    local s_r `r(s)'
    _cert_bool `env'
    local s_e `r(s)'
    _cert_json, id(`id') body(`"{"refused": `s_r', "envelope": `s_e'}"')
end

* ---- run -----------------------------------------------------------

foreach id of global CERT_CASES {
    capture program list case_`id'
    if _rc continue
    capture noisily case_`id'
    local rc = _rc
    if `rc' {
        tempname fh
        file open `fh' using "$CERT_OUT/`id'.error.txt", write text replace
        file write `fh' "Stata error r(`rc') in case_`id'" _n
        file close `fh'
    }
}

_cert_json, id(_versions) body(`"{"language": "stata", "version": "`c(stata_version)'", "edition": "`c(edition_real)'", "toolkit": null}"')
