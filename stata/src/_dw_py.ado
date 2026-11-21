*! version 1.0 21NOV2026 cso-toolkit cso-toolkit@unicef.org
*! Author: João Pedro Azevedo

* _dw_py -- load dw_stata_helpers.py into Stata's Python (Stata 16+).
*
* Internal. Returns r(ok) = 1 when Stata's Python integration works and
* the helper module (shipped next to the .ado files, found on the adopath)
* is imported; 0 otherwise (no Python configured: see -help python-,
* -set python_exec-). Idempotent: a second call only re-checks the import.

cap program drop _dw_py
program define _dw_py, rclass
    version 16
    capture python: import dw_stata_helpers
    if _rc {
        capture findfile dw_stata_helpers.py
        if !_rc {
            local f `"`r(fn)'"'
            capture python: import os, sys, sfi; sys.path.insert(0, os.path.dirname(os.path.abspath(sfi.Macro.getLocal("f")))); import dw_stata_helpers
        }
    }
    return scalar ok = (_rc == 0)
end
