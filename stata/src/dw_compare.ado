*! version 1.0 24MAY2026 cso-toolkit cso-toolkit@unicef.org
*! Author: João Pedro Azevedo (port); original by Kristoffer Bjärkefur

* dw_compare — Stata sibling of the R dw_compare() helper.
*
* Compare two Stata datasets on a declared id key, classify each value
* column as identical / numerically-equivalent (within `tol()`) /
* differs, and report:
*   - added rows (present in `current`, missing in `reference`)
*   - removed rows (present in `reference`, missing in `current`)
*   - changed rows (id present in both; at least one value differs)
*
* Tolerates different row counts, no sorting required.
*
* Ported from the World Bank EduAnalyticsToolkit `edukit_comparefiles`
* / `comparefiles` family (Author: Kristoffer Bjärkefur). The
* upstream command is 562 lines and emits a rich Markdown report; this
* port keeps the core diff logic and adds an optional Markdown summary
* via `report()`. For the rich markdown report (per-row diff tables,
* wiggle room, varlist length controls), continue to use the upstream
* {bf:comparefiles} command directly — this helper is sized for the
* cso-toolkit IO contract, not for full editorial diffs.

cap program drop dw_compare
program define   dw_compare, rclass

    syntax , CURrent(string) REFerence(string) IDvars(string) ///
        [ VALuevars(string) TOL(real 1e-8) REPort(string) LABel(string) ]

    *----------------------------------------------------------
    * 1. Validate inputs
    *----------------------------------------------------------
    foreach side in current reference {
        local f ``side''
        if substr("`f'", -4, .) != ".dta" local f "`f'.dta"
        cap confirm file "`f'"
        if _rc {
            noi di as error "{phang}dw_compare: file not found ({it:`side'}): `f'{p_end}"
            error 601
        }
        local `side'_path "`f'"
    }
    if "`label'" == "" local label "dw_compare"

    *----------------------------------------------------------
    * 2. Load reference, rename value-columns with _ref suffix
    *----------------------------------------------------------
    preserve

    quietly use "`reference_path'", clear
    quietly isid `idvars'
    if _rc {
        noi di as error "{phang}dw_compare: reference is not unique on idvars [`idvars'].{p_end}"
        restore
        error _rc
    }
    quietly count
    local n_ref = r(N)

    * If valuevars not specified, default to "every variable other than idvars"
    if "`valuevars'" == "" {
        unab _all_ : _all
        local valuevars : list _all_ - idvars
    } else {
        unab valuevars : `valuevars'
    }
    if "`valuevars'" == "" {
        noi di as error "{phang}dw_compare: no value columns to compare (after removing idvars).{p_end}"
        restore
        error 198
    }

    quietly keep `idvars' `valuevars'
    foreach v of varlist `valuevars' {
        quietly rename `v' `v'_ref
    }

    tempfile ref_tmp
    quietly save "`ref_tmp'"

    *----------------------------------------------------------
    * 3. Load current, merge against reference
    *----------------------------------------------------------
    quietly use "`current_path'", clear
    quietly isid `idvars'
    if _rc {
        noi di as error "{phang}dw_compare: current is not unique on idvars [`idvars'].{p_end}"
        restore
        error _rc
    }
    quietly count
    local n_cur = r(N)
    quietly keep `idvars' `valuevars'

    quietly merge 1:1 `idvars' using "`ref_tmp'"

    quietly count if _merge == 1
    local n_added = r(N)
    quietly count if _merge == 2
    local n_removed = r(N)
    quietly count if _merge == 3
    local n_common = r(N)

    *----------------------------------------------------------
    * 4. Per-column classification on _merge == 3
    *----------------------------------------------------------
    local n_changed_total = 0
    local col_changed
    local col_identical
    foreach v of local valuevars {
        local n_diff = 0
        capture confirm numeric variable `v'
        if !_rc {
            * Numeric: tolerance-aware compare
            quietly count if _merge == 3 & ///
                ( (missing(`v') != missing(`v'_ref)) ///
                  | (!missing(`v') & !missing(`v'_ref) & abs(`v' - `v'_ref) > `tol') )
            local n_diff = r(N)
        }
        else {
            * String: exact compare
            quietly count if _merge == 3 & `v' != `v'_ref
            local n_diff = r(N)
        }
        if `n_diff' > 0 {
            local col_changed `"`col_changed' `v'(`n_diff')"'
            local n_changed_total = `n_changed_total' + `n_diff'
        }
        else {
            local col_identical `"`col_identical' `v'"'
        }
    }

    *----------------------------------------------------------
    * 5. Console summary
    *----------------------------------------------------------
    noi di ""
    noi di as txt "{hline 60}"
    noi di as txt "dw_compare [{result:`label'}]"
    noi di as txt "{hline 60}"
    noi di as txt "  reference : `reference_path' (`n_ref' rows)"
    noi di as txt "  current   : `current_path' (`n_cur' rows)"
    noi di as txt "  idvars    : `idvars'"
    noi di as txt "  tolerance : `tol' (numeric columns)"
    noi di ""
    noi di as txt "  added     (in current, not reference): {result:`n_added'}"
    noi di as txt "  removed   (in reference, not current): {result:`n_removed'}"
    noi di as txt "  common rows                          : {result:`n_common'}"
    noi di as txt "  changed cells (across common rows)   : {result:`n_changed_total'}"
    if `"`col_changed'"' != "" {
        noi di as txt "  columns differing (n_diff)           :`col_changed'"
    }
    if `"`col_identical'"' != "" {
        noi di as txt "  columns identical                    :`col_identical'"
    }
    noi di as txt "{hline 60}"

    *----------------------------------------------------------
    * 6. Optional Markdown report
    *----------------------------------------------------------
    if "`report'" != "" {
        tempname mh
        file open `mh' using "`report'", write text replace
        file write `mh' "# dw_compare report — `label'" _n _n
        file write `mh' "- Reference: ``"reference_path"''" _n
        file write `mh' "- Current  : ``"current_path"''" _n
        file write `mh' "- ID vars  : ``"idvars"''" _n
        file write `mh' "- Tolerance: `tol' (numeric)" _n _n
        file write `mh' "## Row counts" _n _n
        file write `mh' "| segment | rows |" _n
        file write `mh' "|---|---:|" _n
        file write `mh' "| reference | `n_ref' |" _n
        file write `mh' "| current   | `n_cur' |" _n
        file write `mh' "| added (in current only)   | `n_added' |" _n
        file write `mh' "| removed (in reference only) | `n_removed' |" _n
        file write `mh' "| common (id present in both) | `n_common' |" _n
        file write `mh' "| changed cells across common rows | `n_changed_total' |" _n _n
        file write `mh' "## Per-column status" _n _n
        file write `mh' "| column | n_diff |" _n
        file write `mh' "|---|---:|" _n
        foreach v of local valuevars {
            local n_diff_v = 0
            capture confirm numeric variable `v'
            if !_rc {
                quietly count if _merge == 3 & ///
                    ( (missing(`v') != missing(`v'_ref)) ///
                      | (!missing(`v') & !missing(`v'_ref) & abs(`v' - `v'_ref) > `tol') )
                local n_diff_v = r(N)
            }
            else {
                quietly count if _merge == 3 & `v' != `v'_ref
                local n_diff_v = r(N)
            }
            file write `mh' "| `v' | `n_diff_v' |" _n
        }
        file close `mh'
        noi di as txt "  report written -> `report'"
    }

    *----------------------------------------------------------
    * 7. Returns
    *----------------------------------------------------------
    return scalar n_ref       = `n_ref'
    return scalar n_cur       = `n_cur'
    return scalar n_added     = `n_added'
    return scalar n_removed   = `n_removed'
    return scalar n_common    = `n_common'
    return scalar n_changed   = `n_changed_total'
    return local  col_changed `"`col_changed'"'
    return local  col_identical `"`col_identical'"'

    restore
end
