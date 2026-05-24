*! version 1.0 24MAY2026 cso-toolkit cso-toolkit@unicef.org
*! Author: João Pedro Azevedo (port); original by Diana Goldemberg

* dw_save — Stata sibling of the R dw_save() helper.
*
* Behaviour:
*   1. Validate that the target directory exists.
*   2. Enforce row uniqueness on `idvars()` via `isid`.
*   3. `compress` the dataset.
*   4. `save, replace` to <path>/<filename>(.dta).
*   5. Write a sibling .provenance.json sidecar with the same shape the
*      R helpers emit, so reviewer-mode integrity checks work across
*      both languages.
*
* Mode contract: if `$dw_mode == "reviewer"` and the target path matches
* the canonical roots ($teamsWrkDataCanonical / $teamsRawDataCanonical),
* the save is BLOCKED unless `allow_canonical_write` is passed. This
* mirrors dw_save() in r/R/dw_io.R.
*
* Ported from World Bank EduAnalyticsToolkit `edukit_save` /
* `savemetadata` (v1.2 20MAR2020, Author: Diana Goldemberg), simplified
* and adjusted to align with the cso-toolkit provenance-sidecar pattern
* instead of edukit's `char _dta[]` metadata model.

cap program drop dw_save
program define   dw_save, rclass

    syntax , FILEname(string) Path(string) IDvars(string) ///
        [ METAdata(string asis)              ///
          TItle(string asis)                 ///
          PROducer(string asis)              ///
          SOurces(string asis)               ///
          CONtact(string)                    ///
          VIntage(string)                    ///
          ALLOW_CANONICAL_write              ///
          NOCompress                         ///
          NOSidecar ]

    *----------------------------------------------------------
    * 1. Mode contract — block canonical writes in reviewer mode
    *----------------------------------------------------------
    if "$dw_mode" == "reviewer" & "`allow_canonical_write'" == "" {
        local canonical_roots `"$teamsWrkDataCanonical $teamsRawDataCanonical"'
        foreach root of local canonical_roots {
            if "`root'" != "" & strpos("`path'", "`root'") == 1 {
                noi di as error "{phang}dw_save: reviewer mode is forbidden to write under canonical root [`root']. Pass -allow_canonical_write- to override (DBM bootstraps only).{p_end}"
                error 459
            }
        }
    }

    *----------------------------------------------------------
    * 2. Validate path
    *----------------------------------------------------------
    mata : st_numscalar("r(dirExist)", direxists("`path'"))
    if `r(dirExist)' == 0 {
        noi di as error "{phang}dw_save: directory does not exist: `path'. Create it first (see dw_mkdir).{p_end}"
        error 601
    }

    *----------------------------------------------------------
    * 3. Normalise filename
    *----------------------------------------------------------
    if strrpos("`filename'", ".dta") == length("`filename'") - 3 {
        local filename = substr("`filename'", 1, length("`filename'") - 4)
    }
    local fullpath `"`path'/`filename'.dta"'
    local sidecarpath `"`fullpath'.provenance.json"'

    *----------------------------------------------------------
    * 4. isid contract
    *----------------------------------------------------------
    capture isid `idvars'
    if _rc != 0 {
        noi di as error "{phang}dw_save: idvars [`idvars'] do not uniquely identify the dataset (or contain missing). No file written.{p_end}"
        error _rc
    }

    *----------------------------------------------------------
    * 5. Compress (unless suppressed)
    *----------------------------------------------------------
    if "`nocompress'" == "" {
        quietly compress
    }

    *----------------------------------------------------------
    * 6. Capture schema for provenance sidecar (before save)
    *----------------------------------------------------------
    quietly count
    local n_rows = r(N)
    quietly describe, varlist
    local n_cols = r(k)
    local varnames `"`r(varlist)'"'

    * datasignature gives a content hash (SHA-1 of variables/values).
    * It is Stata-native, no external dep, and survives AppLocker.
    quietly datasignature
    local datasig `"`r(datasignature)'"'

    *----------------------------------------------------------
    * 7. Save
    *----------------------------------------------------------
    quietly save `"`fullpath'"', replace
    noi di as txt `"{pstd}dw_save: wrote `n_rows' x `n_cols' to `fullpath'{p_end}"'

    *----------------------------------------------------------
    * 8. Provenance sidecar (unless suppressed)
    *----------------------------------------------------------
    if "`nosidecar'" == "" {
        local now `"`c(current_date)' `c(current_time)'"'
        local user `"`c(username)'"'
        local dwm  `"$dw_mode"'

        tempname fh
        file open `fh' using `"`sidecarpath'"', write text replace

        file write `fh' "{" _n
        file write `fh' `"  "format": "dw_save.provenance/1","' _n
        file write `fh' `"  "path": ""' _q
        file write `fh' `"`fullpath'""' _q
        file write `fh' "," _n
        file write `fh' `"  "written_at": ""' _q
        file write `fh' `"`now'""' _q
        file write `fh' "," _n
        file write `fh' `"  "user": ""' _q
        file write `fh' `"`user'""' _q
        file write `fh' "," _n
        file write `fh' `"  "dw_mode": ""' _q
        file write `fh' `"`dwm'""' _q
        file write `fh' "," _n
        file write `fh' `"  "datasignature": ""' _q
        file write `fh' `"`datasig'""' _q
        file write `fh' "," _n
        file write `fh' `"  "schema": { "rows": `n_rows', "cols": `n_cols' },"' _n
        file write `fh' `"  "idvars": ""' _q
        file write `fh' `"`idvars'""' _q
        file write `fh' "," _n

        * Optional explicit metadata block
        file write `fh' `"  "metadata": {"' _n
        if `"`title'"' != "" {
            file write `fh' `"    "title": ""' _q
            file write `fh' `"`title'""' _q
            file write `fh' "," _n
        }
        if `"`producer'"' != "" {
            file write `fh' `"    "producer": ""' _q
            file write `fh' `"`producer'""' _q
            file write `fh' "," _n
        }
        if `"`sources'"' != "" {
            file write `fh' `"    "sources": ""' _q
            file write `fh' `"`sources'""' _q
            file write `fh' "," _n
        }
        if "`contact'" != "" {
            file write `fh' `"    "contact": ""' _q
            file write `fh' `"`contact'""' _q
            file write `fh' "," _n
        }
        if "`vintage'" != "" {
            file write `fh' `"    "vintage": ""' _q
            file write `fh' `"`vintage'""' _q
            file write `fh' "," _n
        }
        * Pass-through `metadata("key1 value1; key2 value2")` semicolon-separated
        if `"`metadata'"' != "" {
            local meta_remainder `"`metadata'"'
            while `"`meta_remainder'"' != "" {
                gettoken pair meta_remainder : meta_remainder, parse(";")
                local pair = trim(`"`pair'"')
                if `"`pair'"' != "" & `"`pair'"' != ";" {
                    gettoken k v : pair
                    local v = trim(`"`v'"')
                    file write `fh' `"    ""' _q
                    file write `fh' `"`k'""' _q
                    file write `fh' `"": ""' _q
                    file write `fh' `"`v'""' _q
                    file write `fh' "," _n
                }
                local meta_remainder = subinstr(`"`meta_remainder'"', ";", "", 1)
            }
        }
        file write `fh' `"    "_end": "true""' _n
        file write `fh' "  }" _n
        file write `fh' "}" _n
        file close `fh'

        noi di as txt `"{pstd}dw_save: wrote provenance sidecar -> `sidecarpath'{p_end}"'
    }

    *----------------------------------------------------------
    * 9. Returns
    *----------------------------------------------------------
    return local path          `"`fullpath'"'
    return local sidecar       `"`sidecarpath'"'
    return scalar n_rows       = `n_rows'
    return scalar n_cols       = `n_cols'
    return local datasignature `"`datasig'"'

end
