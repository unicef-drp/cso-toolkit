*! test_indent_guard.do -- regression test for dw_load_config's indent guard.
*
* Verifies that a `datalib:` block sharing the same ~/.config/user_config.yml
* cannot corrupt the toolkit's session globals: its indented children are
* skipped (even when a child name collides with a toolkit dispatch key such
* as `sandboxRoot`), the block header is an ignored unknown key, and a
* top-level toolkit key AFTER the block still parses.
*
* The toolkit has no Stata CI runner; this is a documented local gate.
* Run from the repository root:
*     do stata/tests/test_indent_guard.do

version 14
clear all

run "stata/src/dw_load_config.ado"

* Build a shared-style config: toolkit flat keys at column 0, and a
* `datalib:` block whose indented children include a COLLIDING key name.
tempfile cfg
tempname fh
file open `fh' using "`cfg'", write text replace
file write `fh' "dw_mode: reviewer"                 _n
file write `fh' `"sandboxRoot: "C:/legit/sandbox""' _n
file write `fh' "datalib:"                          _n
file write `fh' `"  root: "Z:/datalib""'            _n
file write `fh' `"  sandboxRoot: "Z:/EVIL""'        _n
file write `fh' "dwZDrive: Z:/"                     _n
file close `fh'

* Start from a clean slate so a stale global cannot mask a failure.
macro drop dw_mode sandboxRoot dwZDrive root teamsWrkData

dw_load_config, filepath("`cfg'")

* --- assertions ---------------------------------------------------------
* Top-level toolkit keys parse normally:
assert "$dw_mode"     == "reviewer"
assert "$dwZDrive"    == "Z:/"                 // column-0 key AFTER the block still parses
* The indent guard held: the nested (colliding) key did NOT win, and the
* datalib block's own keys never leaked into toolkit globals:
assert "$sandboxRoot" == "C:/legit/sandbox"    // NOT "Z:/EVIL" from the datalib block
assert "$root"        == ""                    // datalib block's `root:` never became a global

display as result ///
    "PASS: indent guard ignored the nested datalib: block; toolkit globals intact."
