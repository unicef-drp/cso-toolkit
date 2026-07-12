*! test_dw_map_drive.do -- smoke test for dw_map_drive (Windows-only).
* Uses dryrun so nothing is actually mapped. Documented local gate (the
* toolkit has no Stata CI). Run from the repository root:
*     do stata/tests/test_dw_map_drive.do

version 15
clear all
run "stata/src/dw_load_config.ado"
run "stata/src/dw_map_drive.ado"

* 1. explicit letter + unc, dryrun -> no config needed. force keeps the test
*    machine-independent (dryrun never executes, so nothing is mapped).
dw_map_drive, letter(Y:) unc(\\host\share) dryrun force
assert "`r(status)'"=="dryrun"
assert "`r(letter)'"=="Y:"
assert `"`r(unc)'"'=="\\host\share"

* 2. config-driven dryrun: picks up dwZDrive + dwZDriveUNC via dw_load_config
tempfile cfg
tempname fh
file open `fh' using "`cfg'", write text replace
file write `fh' "dw_mode: reviewer"              _n
file write `fh' `"dwZDrive: "Z:/""'              _n
file write `fh' `"dwZDriveUNC: '\\srv\dwshare'"' _n
file close `fh'
global dwZDrive ""
global dwZDriveUNC ""
dw_map_drive, config("`cfg'") dryrun force
assert "`r(status)'"=="dryrun"
assert "`r(letter)'"=="Z:"
assert `"`r(unc)'"'=="\\srv\dwshare"

* 3. no share configured -> envelope-shaped error 198
tempfile cfg2
file open `fh' using "`cfg2'", write text replace
file write `fh' "dw_mode: reviewer" _n
file write `fh' `"dwZDrive: "Z:/""' _n
file close `fh'
global dwZDrive ""
global dwZDriveUNC ""
cap dw_map_drive, config("`cfg2'") dryrun
assert _rc==198

display as result "PASS: dw_map_drive dryrun + config read + no-share error OK."
