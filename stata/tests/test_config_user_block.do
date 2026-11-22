*! test_config_user_block.do -- dw_load_config reads the user's block (#180).
*
* user_config.yml nests each person's settings under their user name
* (DW-Production's template). dw_load_config reads that block first and
* top-level keys as a fallback, resolves dw_mode as
* dw_mode_by_project[<project>], then dw_mode, with no default, and skips
* any other block. Mirror of r/tests/testthat/test-create-profile-user-block.R
* and python/tests/test_profile_user_block.py.
*
* The toolkit has no Stata CI runner; this is a documented local gate
* (and the parity certificate's Stata driver runs on the same machine).
* Run from the repository root:
*     do stata/tests/test_config_user_block.do

version 14
clear all
run "stata/src/dw_load_config.ado"

program define _write_cfg
    * _write_cfg <file> <line> [<line> ...]: one argument per YAML line.
    gettoken f 0 : 0
    tempname fh
    file open `fh' using `"`f'"', write text replace
    while `"`0'"' != "" {
        gettoken ln 0 : 0
        file write `fh' `"`ln'"' _n
    }
    file close `fh'
end

program define _reset
    macro drop dw_mode teamsWrkData teamsRawData sandboxRoot dwZDrive root
end

tempfile cfg

* 1. The user block wins; top-level keys fill the gaps; other blocks are ignored.
_write_cfg "`cfg'" ///
    `"someone_else:"' `"  dw_mode: "producer""' `"  sandboxRoot: "C:/not/mine""' ///
    `"tester:"' `"  dw_mode: "reviewer""' `"  teamsWrkData: "C:/mine/wrk""' ///
    `"  sandboxRoot: "C:/mine/sandbox""' ///
    `"sandboxRoot: "C:/top/sandbox""' `"dwZDrive: Z:/"' ///
    `"datalib:"' `"  root: "Z:/datalib""' `"  dw_mode: "producer""'
_reset
dw_load_config, filepath("`cfg'") user(tester) project(proj-x)
assert "$dw_mode" == "reviewer"
assert "`r(dw_mode_source)'" == "dw_mode (user block)"
assert "$teamsWrkData" == "C:/mine/wrk"
assert "$sandboxRoot" == "C:/mine/sandbox"     // the block beats the top level
assert "$dwZDrive" == "Z:/"                    // a top-level key fills the gap
assert "$root" == ""                           // datalib's keys never leak
assert "`r(user)'" == "tester" & "`r(project)'" == "proj-x"

* 2. dw_mode_by_project for this project beats dw_mode; other projects do not.
_write_cfg "`cfg'" ///
    `"tester:"' `"  dw_mode: "reviewer""' `"  dw_mode_by_project:"' ///
    `"    proj-x: "producer""' `"    other-repo: "reviewer""'
_reset
dw_load_config, filepath("`cfg'") user(tester) project(proj-x)
assert "$dw_mode" == "producer"
assert "`r(dw_mode_source)'" == "dw_mode_by_project"
_reset
dw_load_config, filepath("`cfg'") user(tester) project(another)
assert "$dw_mode" == "reviewer"

* 3. The flat layout (top-level keys only) still works.
_write_cfg "`cfg'" `"dw_mode: producer"' `"teamsWrkData: "C:/flat/wrk""'
_reset
dw_load_config, filepath("`cfg'") user(tester) project(proj-x)
assert "$dw_mode" == "producer" & "$teamsWrkData" == "C:/flat/wrk"
assert "`r(dw_mode_source)'" == "dw_mode (top level)"

* 4. A top-level dw_mode_by_project map applies when the user block has none.
_write_cfg "`cfg'" ///
    `"dw_mode_by_project:"' `"  proj-x: "producer""' `"tester:"' `"  dw_mode: "reviewer""'
_reset
dw_load_config, filepath("`cfg'") user(tester) project(proj-x)
assert "$dw_mode" == "producer"

* 5. No dw_mode for this user: stop (another user's block is not adopted).
_write_cfg "`cfg'" `"someone_else:"' `"  dw_mode: "producer""'
_reset
capture noisily dw_load_config, filepath("`cfg'") user(tester) project(proj-x)
assert _rc == 459
assert "$dw_mode" == ""

* 6. An invalid value stops too.
_write_cfg "`cfg'" `"tester:"' `"  dw_mode: "author""'
capture noisily dw_load_config, filepath("`cfg'") user(tester) project(proj-x)
assert _rc == 459

* 7. dw_mode_by_project given a single value stops (it must be a map).
_write_cfg "`cfg'" `"tester:"' `"  dw_mode_by_project: "producer""'
capture noisily dw_load_config, filepath("`cfg'") user(tester) project(proj-x)
assert _rc == 459

* 8. The default project is the repository folder's name.
_write_cfg "`cfg'" `"tester:"' `"  dw_mode: "reviewer""'
_reset
dw_load_config, filepath("`cfg'") user(tester)
assert "`r(project)'" != ""

display as result "PASS: dw_load_config reads the user block, the project override and the top-level fallback."
