*! version 1.2 21NOV2026 cso-toolkit cso-toolkit@unicef.org
*! Author: João Pedro Azevedo (port); original by Diana Goldemberg
*! v1.1 (v0.4.0): reviewer-mode guard broadened to canonical OR Z: drive
*! v1.2: the sidecar's JSON escaping no longer stops with invalid syntax
*!       (found by the parity certificate, #190)

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
* the canonical roots ($teamsWrkDataCanonical / $teamsRawDataCanonical)
* OR the Z: drive root ($dwZDrive; v0.4.0 broadening), the save is
* BLOCKED unless `allow_canonical_write` is passed. This mirrors
* dw_save() in r/R/dw_io.R and dw_save() in python/src/dw_io.py.
*
* Ported from World Bank EduAnalyticsToolkit `edukit_save` /
* `savemetadata` (v1.2 20MAR2020, Author: Diana Goldemberg), simplified
* and adjusted to align with the cso-toolkit provenance-sidecar pattern
* instead of edukit's `char _dta[]` metadata model.

* JSON-string escape: backslashes first, then double-quotes, then control
* characters. Order matters — escape `\` first so the `\"` we introduce next
* is not double-escaped. Returns r(out).
cap program drop _dwsave_jsonesc
program define   _dwsave_jsonesc, rclass
    syntax , string(string asis)
    local bs = char(92)
    local dq = char(34)
    local tb = char(9)
    local lf = char(10)
    local cr = char(13)
    * Macro functions, not subinstr() expressions: in an expression the
    * double-quote step expanded to subinstr(..., """, ...), invalid
    * syntax, so every dw_save with a sidecar stopped after writing the
    * .dta (#190). Assigning `string' without `=' also drops the compound
    * quotes that -asis- keeps.
    local s `string'
    local s : subinstr local s "`bs'" "`bs'`bs'", all
    local s : subinstr local s `"`dq'"' `"`bs'`dq'"', all
    local s : subinstr local s "`tb'" "`bs't", all
    local s : subinstr local s "`cr'" "`bs'r", all
    local s : subinstr local s "`lf'" "`bs'n", all
    return local out `"`s'"'
end

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

    * -asis- keeps the caller's quotes: title("x") arrives as "x" and
    * title(`"say "hi""') with its compound quotes, which the sidecar then
    * wrote as literal quotes or lost. Strip one level of quoting (#190).
    foreach o in metadata title producer sources {
        local `o' ``o''
    }

    *----------------------------------------------------------
    * 1. Mode contract -- block canonical OR Z: writes in reviewer mode
    *
    * v0.4.0 (issue #14) broadens the v0.3.0 canonical-only guard to
    * also cover the Z: drive root, matching the R + Python siblings.
    * Reviewer sessions must keep canonical + Z: deposits read-only.
    *----------------------------------------------------------
    if "$dw_mode" == "reviewer" & "`allow_canonical_write'" == "" {
        local guarded_roots `"$teamsWrkDataCanonical $teamsRawDataCanonical $dwZDrive"'
        foreach root of local guarded_roots {
            if "`root'" != "" & strpos("`path'", "`root'") == 1 {
                local where "canonical (Teams) deposit"
                if "`root'" == "$dwZDrive" local where "Z: drive"
                noi di as error "{phang}[cso_toolkit.dw_save] Reviewer mode forbids writes to `where' [`root']. Pass -allow_canonical_write- to override (DBM bootstraps only).{p_end}"
                error 459
            }
        }
    }

    *----------------------------------------------------------
    * 2. Validate path
    *----------------------------------------------------------
    mata : st_numscalar("r(dirExist)", direxists("`path'"))
    if `r(dirExist)' == 0 {
        noi di as error "{phang}[cso_toolkit.dw_save] Directory does not exist: `path'.{p_end}"
        noi di as error "{phang}  Why: dw_save writes into an existing folder; it does not create one.{p_end}"
        noi di as error "{phang}  Fix: create it first (dw_mkdir), or correct path().{p_end}"
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
        local rc = _rc
        noi di as error "{phang}[cso_toolkit.dw_save] idvars [`idvars'] do not uniquely identify the dataset (or contain missing). No file written.{p_end}"
        noi di as error "{phang}  Why: every output must be unique on its id variables, so a later merge or dw_compare is well defined.{p_end}"
        noi di as error "{phang}  Fix: find the duplicates with -duplicates report `idvars'-, then drop them or add the variable that tells them apart.{p_end}"
        error `rc'
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

        * Escape every value the user (or system) can influence before it
        * lands in the JSON. Windows paths contain backslashes; metadata
        * may contain quotes or newlines; downstream R dw_io readers will
        * reject malformed JSON.
        _dwsave_jsonesc, string(`"`fullpath'"')
        local esc_fullpath `"`r(out)'"'
        _dwsave_jsonesc, string(`"`now'"')
        local esc_now `"`r(out)'"'
        _dwsave_jsonesc, string(`"`user'"')
        local esc_user `"`r(out)'"'
        _dwsave_jsonesc, string(`"`dwm'"')
        local esc_dwm `"`r(out)'"'
        _dwsave_jsonesc, string(`"`datasig'"')
        local esc_datasig `"`r(out)'"'
        _dwsave_jsonesc, string(`"`idvars'"')
        local esc_idvars `"`r(out)'"'

        tempname fh
        file open `fh' using `"`sidecarpath'"', write text replace

        file write `fh' "{" _n
        file write `fh' `"  "format": "dw_save.provenance/1","' _n
        file write `fh' `"  "path": "`esc_fullpath'","' _n
        file write `fh' `"  "written_at": "`esc_now'","' _n
        file write `fh' `"  "user": "`esc_user'","' _n
        file write `fh' `"  "dw_mode": "`esc_dwm'","' _n
        file write `fh' `"  "datasignature": "`esc_datasig'","' _n
        file write `fh' `"  "schema": { "rows": `n_rows', "cols": `n_cols' },"' _n
        file write `fh' `"  "idvars": "`esc_idvars'","' _n

        * Optional explicit metadata block
        file write `fh' `"  "metadata": {"' _n
        if `"`title'"' != "" {
            _dwsave_jsonesc, string(`"`title'"')
            file write `fh' `"    "title": "`r(out)'","' _n
        }
        if `"`producer'"' != "" {
            _dwsave_jsonesc, string(`"`producer'"')
            file write `fh' `"    "producer": "`r(out)'","' _n
        }
        if `"`sources'"' != "" {
            _dwsave_jsonesc, string(`"`sources'"')
            file write `fh' `"    "sources": "`r(out)'","' _n
        }
        if "`contact'" != "" {
            _dwsave_jsonesc, string(`"`contact'"')
            file write `fh' `"    "contact": "`r(out)'","' _n
        }
        if "`vintage'" != "" {
            _dwsave_jsonesc, string(`"`vintage'"')
            file write `fh' `"    "vintage": "`r(out)'","' _n
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
                    _dwsave_jsonesc, string(`"`k'"')
                    local esc_k `"`r(out)'"'
                    _dwsave_jsonesc, string(`"`v'"')
                    local esc_v `"`r(out)'"'
                    file write `fh' `"    "`esc_k'": "`esc_v'","' _n
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
