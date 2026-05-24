*! version 1.0 24MAY2026 cso-toolkit cso-toolkit@unicef.org
*! Author: João Pedro Azevedo (port); original by Kristoffer Bjärkefur

* dw_mkdir — recursive mkdir for cso-toolkit.
*
* Stata's built-in `mkdir` does not accept nested paths; this helper
* creates every missing folder along the path you provide. Mirrors
* R's dir.create(..., recursive = TRUE) and matches the behaviour of
* the World Bank EduAnalyticsToolkit `edukit_rmkdir` / `rmkdir`
* (v1.0 18SEP2019, Author: Kristoffer Bjärkefur), from which this
* port descends.
*
* The command does NOT fail when intermediate folders already exist
* (idempotent) — it only fails if `parent()` does not exist, since
* that usually signals a typo in the call site.

cap program drop dw_mkdir
program define   dw_mkdir, rclass

    syntax , parent(string) newfolders(string)

    * Test that parent folder exists
    mata : st_numscalar("r(dirExist)", direxists("`parent'"))
    if `r(dirExist)' == 0 {
        noi di as error `"{phang}Parent folder [`parent'] does not exist. Pass an existing parent.{p_end}"'
        error 601
    }

    * Normalise slashes for cross-platform behaviour
    local this  = subinstr(`"`newfolders'"', "\", "/", .)
    local firstSlash = strpos(`"`this'"',"/")

    * If a slash is present, split into this segment and the rest
    if `firstSlash' != 0 {
        local rest = substr(`"`this'"', `firstSlash'+1, .)
        local this = substr(`"`this'"', 1, `firstSlash'-1)
    }

    local this_full_path `"`parent'/`this'"'

    * Test if this segment exists; create it if not
    mata : st_numscalar("r(dirExist)", direxists(`"`this_full_path'"'))
    if `r(dirExist)' == 0 mkdir `"`this_full_path'"'

    * Recurse on the rest, if any
    if (`firstSlash' > 0 & "`rest'" != "") qui dw_mkdir , parent(`"`this_full_path'"') newfolders(`"`rest'"')

    * Display and return result
    local resultfolder `"`parent'/`newfolders'"'
    noi di as txt `"{pstd}Folder [`resultfolder'] was created or already existed.{p_end}"'
    return local folder `"`resultfolder'"'

end
