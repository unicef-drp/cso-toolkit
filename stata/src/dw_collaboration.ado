*! version 1.0 21NOV2026 cso-toolkit cso-toolkit@unicef.org
*! Author: João Pedro Azevedo

* dw_collaboration -- the project's collaboration model (#168).
*
* Stata sibling of R/Python dw_collaboration(). How many people may
* PRODUCE is a property of the project, committed as cso_project.yml at
* the repository root:
*
*     schema: cso_project/1
*     collaboration: multi-producer      # or single-producer
*     collaboration_since: 2026-11-20
*
* The file is found by walking up from root() (default: the working
* directory) and stopping at the repository root (the first folder that
* holds .git), so a repository without it never picks up a parent
* folder's. No file means single-producer: existing projects are
* unchanged.
*
* The result is resolved once per session and cached in the globals
* $dw_collaboration_model, $dw_project_file and $dw_session_start (the
* ISO-8601 UTC time the session state was set up; it needs Stata's Python
* integration, see -_dw_py-, and stays empty without it). root() or
* -refresh- resolve again. dw_save calls it; a profile can call it first
* so the session start is the start of the work.
*
* Returns r(model), r(file), r(session_start).

cap program drop dw_collaboration
program define dw_collaboration, rclass

    syntax , [ ROOT(string) REFRESH ]

    if `"`root'"' == "" & "`refresh'" == "" & ///
        inlist("$dw_collaboration_model", "single-producer", "multi-producer") {
        return local model "$dw_collaboration_model"
        return local file `"$dw_project_file"'
        return local session_start "$dw_session_start"
        exit
    }

    *---------------------------------------------------------------
    * 1. Find cso_project.yml, stopping at the repository root
    *---------------------------------------------------------------
    local d = cond(`"`root'"' != "", `"`root'"', `"`c(pwd)'"')
    local d = subinstr(`"`d'"', "\", "/", .)
    if substr(`"`d'"', -1, 1) == "/" & length(`"`d'"') > 1 local d = substr(`"`d'"', 1, length(`"`d'"') - 1)
    local file ""
    forvalues i = 1/64 {
        capture confirm file `"`d'/cso_project.yml"'
        if !_rc {
            local file `"`d'/cso_project.yml"'
            continue, break
        }
        mata: st_local("isrepo", strofreal(direxists(st_local("d") + "/.git") | fileexists(st_local("d") + "/.git")))
        if `isrepo' continue, break
        local slash = strrpos(`"`d'"', "/")
        if `slash' <= 1 continue, break
        local d = substr(`"`d'"', 1, `slash' - 1)
    }

    *---------------------------------------------------------------
    * 2. Read and validate it (top-level schema: and collaboration:)
    *---------------------------------------------------------------
    local model "single-producer"
    if `"`file'"' != "" {
        local schema ""
        local collab ""
        tempname fh
        file open `fh' using `"`file'"', read text
        file read `fh' line
        while r(eof) == 0 {
            local raw `"`line'"'
            if substr(`"`raw'"', 1, 1) != " " & substr(`"`raw'"', 1, 1) != char(9) {
                local colon = strpos(`"`raw'"', ":")
                if `colon' > 0 {
                    local key = trim(substr(`"`raw'"', 1, `colon' - 1))
                    local value = trim(substr(`"`raw'"', `colon' + 1, .))
                    local hash = strpos(`"`value'"', "#")
                    if `hash' > 0 local value = trim(substr(`"`value'"', 1, `hash' - 1))
                    if length(`"`value'"') >= 2 {
                        local lq = substr(`"`value'"', 1, 1)
                        local rq = substr(`"`value'"', length(`"`value'"'), 1)
                        if (`"`lq'"' == `"""' & `"`rq'"' == `"""') | (`"`lq'"' == "'" & `"`rq'"' == "'") {
                            local value = substr(`"`value'"', 2, length(`"`value'"') - 2)
                        }
                    }
                    if "`key'" == "schema" local schema `"`value'"'
                    if "`key'" == "collaboration" local collab `"`value'"'
                }
            }
            file read `fh' line
        }
        file close `fh'
        if `"`schema'"' != "" & `"`schema'"' != "cso_project/1" {
            noi di as error `"{phang}[cso_toolkit.dw_collaboration] `file' declares schema '`schema''; this toolkit reads 'cso_project/1'.{p_end}"'
            noi di as error "{phang}  Fix: upgrade cso-toolkit, or correct the -schema:- line.{p_end}"
            error 459
        }
        if `"`collab'"' != "" {
            if !inlist(`"`collab'"', "single-producer", "multi-producer") {
                noi di as error `"{phang}[cso_toolkit.dw_collaboration] `file' sets -collaboration: `collab'-; it must be 'single-producer' or 'multi-producer'.{p_end}"'
                noi di as error "{phang}  Fix: correct the value, or set it with R or Python dw_set_collaboration().{p_end}"
                error 459
            }
            local model `"`collab'"'
        }
    }

    *---------------------------------------------------------------
    * 3. Cache for the session
    *---------------------------------------------------------------
    global dw_collaboration_model "`model'"
    global dw_project_file `"`file'"'
    if "$dw_session_start" == "" {
        quietly _dw_py
        if r(ok) {
            python: import sfi, dw_stata_helpers as _h; sfi.Macro.setGlobal("dw_session_start", _h.utc_now())
        }
    }
    return local model "`model'"
    return local file `"`file'"'
    return local session_start "$dw_session_start"
end
