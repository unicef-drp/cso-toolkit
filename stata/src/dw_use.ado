*! version 1.0 26MAY2026 cso-toolkit cso-toolkit@unicef.org
*! Author: João Pedro Azevedo

* dw_use -- Stata sibling of the R / Python dw_use() helper.
*
* Read a file from the warehouse, dispatching on the extension. Same
* mode contract as the R / Python siblings: producer-mode reads are
* local-first (fall back to canonical), reviewer-mode reads are
* network-first (Teams -> Z: -> local with provenance warning ->
* hard-stop).
*
* Supported extensions:
*   .dta   -> use
*   .csv   -> import delimited
*   .xlsx  -> import excel, firstrow
*
* For each canonical read the helper also runs a non-blocking Z:
* drive integrity check (size by default; Stata `datasignature` deep
* hash when verify_z(sha256) is passed). Mismatch emits a warning;
* the read still completes.
*
* Provenance: when a sibling .provenance.json sidecar exists, the
* helper stashes the recorded datasignature into r(prov_datasignature)
* and computes the live datasignature post-read; mismatches are
* surfaced via r(prov_status) without aborting the read.
*
* Out of scope (Stata-side, v0.4.0): .parquet, .rds / .rdata. Pipelines
* needing those formats should route through R / Python on the
* producer side and dw_save() to .dta for Stata consumption.

cap program drop dw_use
program define   dw_use, rclass

    syntax , FILEname(string) ///
        [ Path(string)        ///
          AS(string)          ///
          COLs(string)        ///
          VERIFY_z(string)    ///
          FALLBACK_canonical  ///
          NOFALLBACK_canonical ]

    *---------------------------------------------------------------
    * 1. Defaults + flag normalisation
    *---------------------------------------------------------------
    * `fallback_canonical` defaults to TRUE (matches R / Python).
    * Allow `nofallback_canonical` as the explicit opt-out.
    if "`nofallback_canonical'" != "" {
        local fb 0
    }
    else {
        local fb 1
    }

    * verify_z accepts: empty (default = size), "size", "sha256",
    * or "off". Anything else errors.
    if "`verify_z'" == "" local verify_z "size"
    if !inlist("`verify_z'", "size", "sha256", "off") {
        noi di as error ///
            "{phang}[cso_toolkit.dw_use] verify_z() must be one of `size', `sha256', or `off'; got `verify_z'.{p_end}"
        noi di as error ///
            "{phang}  Fix: drop verify_z() to take the default (`size'), or pick a supported value.{p_end}"
        error 198
    }

    * Path may be empty when the caller passes an absolute filename.
    if `"`path'"' != "" {
        local fullpath `"`path'/`filename'"'
    }
    else {
        local fullpath `"`filename'"'
    }

    *---------------------------------------------------------------
    * 2. Resolve the read path (mode-branched)
    *---------------------------------------------------------------
    local resolved ""
    local resolution "literal"

    if "$dw_mode" == "reviewer" {
        * Network-first: Teams canonical -> Z: drive -> repo-local
        local teams_alt ""
        if "$teamsWrkDataCanonical" != "" & strpos(`"`fullpath'"', "$teamsWrkData") == 1 {
            local rel = substr(`"`fullpath'"', length("$teamsWrkData") + 1, .)
            local teams_alt `"$teamsWrkDataCanonical`rel'"'
        }
        else if "$teamsRawDataCanonical" != "" & strpos(`"`fullpath'"', "$teamsRawData") == 1 {
            local rel = substr(`"`fullpath'"', length("$teamsRawData") + 1, .)
            local teams_alt `"$teamsRawDataCanonical`rel'"'
        }

        * 2a. Try Teams canonical
        if `"`teams_alt'"' != "" {
            capture confirm file `"`teams_alt'"'
            if _rc == 0 {
                local resolved `"`teams_alt'"'
                local resolution "teams_canonical"
            }
        }

        * 2b. Try Z: drive mirror (derived from Teams canonical)
        if "`resolved'" == "" & "$dwZDrive" != "" & "$teamsFolderCanonical" != "" {
            if `"`teams_alt'"' != "" & strpos(`"`teams_alt'"', "$teamsFolderCanonical") == 1 {
                local zrel = substr(`"`teams_alt'"', length("$teamsFolderCanonical") + 1, .)
                local z_alt `"$dwZDrive`zrel'"'
                capture confirm file `"`z_alt'"'
                if _rc == 0 {
                    local resolved `"`z_alt'"'
                    local resolution "z_mirror"
                }
            }
        }

        * 2c. Repo-local fallback with provenance warning
        if "`resolved'" == "" & `fb' == 1 {
            capture confirm file `"`fullpath'"'
            if _rc == 0 {
                noi di as text ///
                    "{phang}[cso_toolkit.dw_use] Reviewer-mode canonical paths unavailable; falling back to repo-local copy at `fullpath'. This breaks provenance -- re-mount Teams / Z: before relying on this output.{p_end}"
                local resolved `"`fullpath'"'
                local resolution "local_fallback"
            }
        }

        * 2d. Hard-stop
        if "`resolved'" == "" {
            noi di as error ///
                "{phang}[cso_toolkit.dw_use] Reviewer-mode read: file `filename' not found on Teams, Z:, or in the repo.{p_end}"
            noi di as error ///
                "{phang}  Fix: the producer has not deposited this artifact yet, or your network mount is missing. Contact the sector producer.{p_end}"
            error 601
        }
    }
    else {
        * Producer / unknown mode -- local-first with canonical fallback (v0.3.0)
        capture confirm file `"`fullpath'"'
        if _rc == 0 {
            local resolved `"`fullpath'"'
            local resolution "literal"
        }
        else if `fb' == 1 {
            * Try canonical equivalents
            if "$teamsWrkDataCanonical" != "" & strpos(`"`fullpath'"', "$teamsWrkData") == 1 {
                local rel = substr(`"`fullpath'"', length("$teamsWrkData") + 1, .)
                local alt `"$teamsWrkDataCanonical`rel'"'
                capture confirm file `"`alt'"'
                if _rc == 0 {
                    local resolved `"`alt'"'
                    local resolution "teams_canonical"
                }
            }
            if "`resolved'" == "" & "$teamsRawDataCanonical" != "" & strpos(`"`fullpath'"', "$teamsRawData") == 1 {
                local rel = substr(`"`fullpath'"', length("$teamsRawData") + 1, .)
                local alt `"$teamsRawDataCanonical`rel'"'
                capture confirm file `"`alt'"'
                if _rc == 0 {
                    local resolved `"`alt'"'
                    local resolution "teams_canonical"
                }
            }
        }
        if "`resolved'" == "" {
            noi di as error ///
                "{phang}[cso_toolkit.dw_use] File not found at literal path or under any configured canonical root: `fullpath'.{p_end}"
            noi di as error ///
                "{phang}  Fix: confirm the file was produced by the upstream pipeline, or that team*Canonical globals are set to the right roots.{p_end}"
            error 601
        }
    }

    *---------------------------------------------------------------
    * 3. Read sibling .provenance.json (if present) -- best effort
    *---------------------------------------------------------------
    local sidecar `"`resolved'.provenance.json"'
    local prov_datasig ""
    capture confirm file `"`sidecar'"'
    if _rc == 0 {
        * Naive substring scan rather than a real JSON parse to keep
        * the helper dependency-free. Looks for `"datasignature": "..."`.
        tempname pfh
        file open `pfh' using `"`sidecar'"', read text
        file read `pfh' pline
        while r(eof) == 0 {
            local p `"`pline'"'
            local idx = strpos(`"`p'"', `""datasignature""')
            if `idx' > 0 {
                local rest = substr(`"`p'"', `idx', .)
                local q1 = strpos(`"`rest'"', ":") + 1
                local tail = trim(substr(`"`rest'"', `q1', .))
                * `tail' looks like:  "abc123...",
                if substr(`"`tail'"', 1, 1) == `"""' {
                    local tail = substr(`"`tail'"', 2, .)
                    local q2 = strpos(`"`tail'"', `"""')
                    if `q2' > 0 {
                        local prov_datasig = substr(`"`tail'"', 1, `q2' - 1)
                    }
                }
            }
            file read `pfh' pline
        }
        file close `pfh'
    }

    *---------------------------------------------------------------
    * 4. Auto-dispatch by extension
    *---------------------------------------------------------------
    local fname_lc = strlower(`"`filename'"')
    local ext ""
    local dot = strrpos(`"`fname_lc'"', ".")
    if `dot' > 0 {
        local ext = substr(`"`fname_lc'"', `dot' + 1, .)
    }

    local cols_clause ""
    if `"`cols'"' != "" {
        local cols_clause `"keepvars(`cols')"'
    }

    if "`ext'" == "dta" {
        if `"`cols'"' != "" {
            quietly use `cols' using `"`resolved'"', clear
        }
        else {
            quietly use `"`resolved'"', clear
        }
    }
    else if "`ext'" == "csv" {
        quietly import delimited `"`resolved'"', clear varnames(1) bindquote(strict) stringcols(_all)
        * Promote numeric-looking columns. Destring with force so
        * non-numeric values stay strings (no data loss).
        capture quietly destring _all, replace
    }
    else if "`ext'" == "xlsx" {
        quietly import excel `"`resolved'"', firstrow clear
    }
    else {
        noi di as error ///
            "{phang}[cso_toolkit.dw_use] Unsupported file extension `.`ext'' (path: `resolved').{p_end}"
        noi di as error ///
            "{phang}  Supported on the Stata side: .dta, .csv, .xlsx. For .parquet / .rds route through R / Python and dw_save() to .dta.{p_end}"
        error 198
    }

    quietly count
    local n_rows = r(N)
    quietly describe, varlist
    local n_cols = r(k)
    local varnames `"`r(varlist)'"'

    *---------------------------------------------------------------
    * 5. Provenance check (best effort -- non-blocking)
    *---------------------------------------------------------------
    local prov_status "no_sidecar"
    local live_datasig ""
    if "`ext'" == "dta" {
        capture quietly datasignature
        if _rc == 0 {
            local live_datasig `"`r(datasignature)'"'
        }
        if "`prov_datasig'" != "" & "`live_datasig'" != "" {
            if "`prov_datasig'" == "`live_datasig'" {
                local prov_status "match"
            }
            else {
                local prov_status "mismatch"
                noi di as text ///
                    "{phang}[dw_use] Provenance datasignature mismatch: sidecar reports `prov_datasig', live `live_datasig'. Read still completed.{p_end}"
            }
        }
        else if "`prov_datasig'" != "" {
            local prov_status "stata_live_failed"
        }
    }

    *---------------------------------------------------------------
    * 6. Z: integrity check (non-blocking)
    *---------------------------------------------------------------
    local z_status "skipped"
    if "`verify_z'" != "off" & "$dwZDrive" != "" & "$teamsFolderCanonical" != "" {
        if strpos(`"`resolved'"', "$teamsFolderCanonical") == 1 {
            local zrel = substr(`"`resolved'"', length("$teamsFolderCanonical") + 1, .)
            local z_path `"$dwZDrive`zrel'"'
            capture confirm file `"`z_path'"'
            if _rc != 0 {
                local z_status "z_missing"
                noi di as text ///
                    "{phang}[dw_use] Z: mirror missing for: `z_path'. Teams read OK; Z: deposit has not been mirrored yet.{p_end}"
            }
            else if "`verify_z'" == "size" {
                local primary_size = filesize(`"`resolved'"')
                local z_size       = filesize(`"`z_path'"')
                if `primary_size' == `z_size' {
                    local z_status "match_size"
                }
                else {
                    local z_status "size_mismatch"
                    noi di as text ///
                        "{phang}[dw_use] Z: mirror size mismatch: Teams `primary_size' bytes vs Z: `z_size' bytes. Read still completed.{p_end}"
                }
            }
            else if "`verify_z'" == "sha256" {
                * Compare via Stata-native datasignature -- only works
                * for the .dta path that is currently in memory; the
                * helper requires a temporary swap to load the Z:
                * sibling, hash it, and reload the primary.
                if "`ext'" == "dta" {
                    preserve
                    capture noisily use `"`z_path'"', clear
                    if _rc == 0 {
                        capture quietly datasignature
                        local z_sig `"`r(datasignature)'"'
                    }
                    restore
                    if "`z_sig'" != "" & "`live_datasig'" != "" {
                        if "`z_sig'" == "`live_datasig'" {
                            local z_status "match_sha256"
                        }
                        else {
                            local z_status "sha256_mismatch"
                            noi di as text ///
                                "{phang}[dw_use] Z: mirror content hash mismatch: Teams `live_datasig' vs Z: `z_sig'. Read still completed.{p_end}"
                        }
                    }
                    else {
                        local z_status "sha256_unavailable"
                    }
                }
                else {
                    local z_status "sha256_unsupported_for_ext"
                }
            }
        }
    }

    *---------------------------------------------------------------
    * 7. as() coercion (only `as(data.frame)`-equivalent supported in
    *    Stata; documented for parity with R/Python signatures)
    *---------------------------------------------------------------
    if `"`as'"' != "" & "`as'" != "data.frame" {
        noi di as text ///
            "{phang}[dw_use] Note: as(`as') is documented for R / Python parity; Stata returns the read dataset in memory regardless.{p_end}"
    }

    *---------------------------------------------------------------
    * 8. Returns
    *---------------------------------------------------------------
    return local resolved          `"`resolved'"'
    return local resolution        "`resolution'"
    return local sidecar           `"`sidecar'"'
    return local prov_datasignature `"`prov_datasig'"'
    return local live_datasignature `"`live_datasig'"'
    return local prov_status       "`prov_status'"
    return local z_status          "`z_status'"
    return scalar n_rows           = `n_rows'
    return scalar n_cols           = `n_cols'

    noi di as txt `"{pstd}dw_use: read `n_rows' x `n_cols' from `resolved' (resolution=`resolution', z=`z_status').{p_end}"'

end
