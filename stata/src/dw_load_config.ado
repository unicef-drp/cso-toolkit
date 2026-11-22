*! version 1.3 21NOV2026 cso-toolkit cso-toolkit@unicef.org
*! Author: João Pedro Azevedo
*! v1.3: reads the user's block of user_config.yml (DW-Production's
*!       layout) with top-level keys as the fallback, and resolves dw_mode
*!       as dw_mode_by_project[<project>], then dw_mode, like the R and
*!       Python profiles (#180).

* dw_load_config -- read `~/.config/user_config.yml` (or any caller-
* supplied YAML file) and populate the cso-toolkit session globals.
*
* Stata cannot link external YAML packages on AppLocker-locked
* corporate Windows installs, so this helper ships a minimal
* hand-rolled parser for the documented subset of the user-config
* schema. One file serves every cso-toolkit project: each person's
* settings sit in a block named after their user name, and top-level
* keys are read as a fallback (the older, flat layout):
*
*     jpazevedo:                         <- the user block
*       dw_mode: "reviewer"              <- default for every project
*       dw_mode_by_project:              <- optional, per repository
*         learning-mobility: "producer"
*       teamsWrkData: "C:/Users/<you>/Teams/.../013_wrkdata"
*     sandboxRoot: "C:/Users/<you>/sandbox"   <- top level: fallback
*     datalib:                           <- another tool's block: ignored
*       root: "Z:/datalib"
*
* Recognised keys: dw_mode, dw_mode_by_project, teamsWrkData,
* teamsRawData, teamsWrkDataCanonical, teamsRawDataCanonical,
* teamsFolderCanonical, dwZDrive, dwZDriveUNC (consumed by dw_map_drive),
* sandboxRoot.
*
* Behaviour:
*   - The user is user() if given, else the USERNAME environment
*     variable, then USER, then c(username): the R and Python profiles'
*     order.
*   - The project is project() if given, else the name of the folder
*     that holds the repository (.git), searched upward from the working
*     directory. A profile should pass project() explicitly: a git
*     worktree's folder name is not the project name.
*   - Each key is read from the user block first, then from the top
*     level. dw_mode resolves as dw_mode_by_project[<project>] (the
*     user block's map if it has one, else the top-level map), then
*     dw_mode. There is no default: a missing or invalid dw_mode stops
*     with error 459 and the exact YAML to add. DW-Production's
*     dw_mode_by_sector stays a DW-Production extension, ahead of both.
*   - Lines: `key: value`, comments (`#`) and blank lines skipped; values
*     may be quoted or bare; a trailing inline comment is stripped.
*     Nesting is read by indentation, two levels deep (user block, then
*     dw_mode_by_project). Lists, anchors and multi-line strings are NOT
*     supported, and any other block (e.g. `datalib:`) is skipped whole,
*     so its keys never become toolkit globals.
*   - Unknown keys are ignored.
*
* Returns the parsed values in r() and sets each one as a matching
* global ($dw_mode, $teamsWrkData, ...), plus r(user), r(project) and
* r(dw_mode_source). It does NOT derive mode-aware globals from the
* canonical keys -- it sets exactly what the YAML provides. Profile
* scripts that want to flip `$teamsWrkData` to the canonical root in
* producer mode (and the sandbox root in reviewer mode) should do that
* swap themselves after `dw_load_config` returns.

cap program drop dw_load_config
program define   dw_load_config, rclass

    syntax , [ FILEpath(string) USER(string) PROJect(string) ]

    *---------------------------------------------------------------
    * 1. Resolve config path, user and project
    *---------------------------------------------------------------
    if `"`filepath'"' == "" {
        * Default: ~/.config/user_config.yml. Stata exposes the home
        * directory via c(sysdir_personal) on some platforms, but the
        * portable form is $HOME / %USERPROFILE%.
        local home : env HOME
        if "`home'" == "" {
            local home : env USERPROFILE
        }
        if "`home'" == "" {
            noi di as error ///
                "{phang}[cso_toolkit.dw_load_config] Cannot resolve default config path: neither HOME nor USERPROFILE is set.{p_end}"
            noi di as error ///
                "{phang}  Fix: pass filepath() explicitly, or set HOME / USERPROFILE in your environment.{p_end}"
            error 459
        }
        local filepath `"`home'/.config/user_config.yml"'
    }

    capture confirm file `"`filepath'"'
    if _rc != 0 {
        noi di as error ///
            "{phang}[cso_toolkit.dw_load_config] Config file not found: `filepath'{p_end}"
        noi di as error ///
            "{phang}  Why: cso-toolkit needs `dw_mode` and the team* path globals before any helper call.{p_end}"
        noi di as error ///
            "{phang}  Fix: create `filepath' with your user block and a dw_mode (see help dw_load_config), or pass a different filepath().{p_end}"
        error 601
    }

    if `"`user'"' == "" {
        local user : env USERNAME
        if `"`user'"' == "" local user : env USER
        if `"`user'"' == "" local user `"`c(username)'"'
    }

    if `"`project'"' == "" {
        * The folder that holds .git (a folder in a clone, a file in a
        * worktree), searched upward from the working directory.
        local d = subinstr(`"`c(pwd)'"', "\", "/", .)
        forvalues i = 1/64 {
            mata: st_local("isrepo", strofreal(direxists(st_local("d") + "/.git") | fileexists(st_local("d") + "/.git")))
            if `isrepo' {
                local slash = strrpos(`"`d'"', "/")
                local project = substr(`"`d'"', `slash' + 1, .)
                continue, break
            }
            local slash = strrpos(`"`d'"', "/")
            if `slash' <= 1 continue, break
            local d = substr(`"`d'"', 1, `slash' - 1)
        }
    }

    local keys dw_mode teamsWrkData teamsRawData teamsWrkDataCanonical ///
        teamsRawDataCanonical teamsFolderCanonical dwZDrive dwZDriveUNC sandboxRoot

    *---------------------------------------------------------------
    * 2. Walk the file: top-level keys (t_*), the user block (u_*),
    *    and the two dw_mode_by_project maps
    *---------------------------------------------------------------
    local blk ""            // "", "user", "top_bp", "other"
    local sub ""            // "bp" inside the user block's dw_mode_by_project
    local uind ""           // indentation of the user block's keys
    local u_has_bp 0
    local t_has_bp 0
    local u_bp ""
    local t_bp ""
    local bp_scalar ""

    tempname fh
    file open `fh' using `"`filepath'"', read text
    file read `fh' line
    while r(eof) == 0 {
        local raw `"`line'"'
        local trimmed = ustrtrim(`"`raw'"')
        if `"`trimmed'"' == "" | substr(`"`trimmed'"', 1, 1) == "#" {
            file read `fh' line
            continue
        }
        local ind = ustrlen(`"`raw'"') - ustrlen(ustrltrim(`"`raw'"'))

        * Split on the first ":" (a value such as "C:/..." keeps its own).
        local colon = strpos(`"`trimmed'"', ":")
        if `colon' == 0 {
            file read `fh' line
            continue
        }
        local key   = trim(substr(`"`trimmed'"', 1, `colon' - 1))
        local value = trim(substr(`"`trimmed'"', `colon' + 1, .))

        * Strip a trailing inline comment.
        local hash = strpos(`"`value'"', "#")
        if `hash' > 0 {
            local value = trim(substr(`"`value'"', 1, `hash' - 1))
        }

        * Strip wrapping single or double quotes, from the value and the
        * key. Compound quotes around the first/last characters: a bare
        * "`lq'" would expand to """ for a double-quoted value (r(133)).
        foreach part in value key {
            if length(`"``part''"') >= 2 {
                local lq = substr(`"``part''"', 1, 1)
                local rq = substr(`"``part''"', length(`"``part''"'), 1)
                if (`"`lq'"' == `"""' & `"`rq'"' == `"""') | (`"`lq'"' == "'" & `"`rq'"' == "'") {
                    local `part' = substr(`"``part''"', 2, length(`"``part''"') - 2)
                }
            }
        }

        if `ind' == 0 {
            * A top-level line closes any open block.
            local blk ""
            local sub ""
            if `"`value'"' == "" {
                if `"`key'"' == `"`user'"' & `"`user'"' != "" {
                    local blk "user"
                    local uind ""
                }
                else if "`key'" == "dw_mode_by_project" {
                    local blk "top_bp"
                    local t_has_bp 1
                }
                else local blk "other"
            }
            else if "`key'" == "dw_mode_by_project" {
                local t_has_bp 1
                local bp_scalar "top"
            }
            else if `: list posof "`key'" in keys' > 0 {
                local t_`key' `"`value'"'
                local t_set_`key' 1
            }
        }
        else if "`blk'" == "user" {
            if "`uind'" == "" local uind `ind'
            if `ind' == `uind' {
                local sub ""
                if "`key'" == "dw_mode_by_project" {
                    local u_has_bp 1
                    if `"`value'"' == "" local sub "bp"
                    else local bp_scalar "user"
                }
                else if `"`value'"' != "" & `: list posof "`key'" in keys' > 0 {
                    local u_`key' `"`value'"'
                    local u_set_`key' 1
                }
            }
            else if `ind' > `uind' & "`sub'" == "bp" {
                if `"`key'"' == `"`project'"' & `"`project'"' != "" local u_bp `"`value'"'
            }
        }
        else if "`blk'" == "top_bp" {
            if `"`key'"' == `"`project'"' & `"`project'"' != "" local t_bp `"`value'"'
        }
        * Any other block ("other") is skipped whole.

        file read `fh' line
    }
    file close `fh'

    *---------------------------------------------------------------
    * 3. Resolve: user block first, then top level
    *---------------------------------------------------------------
    local where = cond(`"`project'"' == "", "this project", `"`project'"')
    local pname = cond(`"`project'"' == "", "<project>", `"`project'"')
    local uname = cond(`"`user'"' == "", "<username>", `"`user'"')

    * dw_mode_by_project: the user block's map if it has one, else the
    * top level's (as R's user_setting("dw_mode_by_project")).
    if (`u_has_bp' & "`bp_scalar'" == "user") | (!`u_has_bp' & `t_has_bp' & "`bp_scalar'" == "top") {
        noi di as error `"[cso_toolkit.dw_load_config] dw_mode_by_project must map project names to "producer" or "reviewer", not a single value (`filepath')."'
        _dwcfg_hint, filepath(`"`filepath'"') user(`"`uname'"') project(`"`pname'"')
        error 459
    }
    local mode ""
    local source ""
    local bp = cond(`u_has_bp', `"`u_bp'"', `"`t_bp'"')
    if `"`bp'"' != "" {
        local mode `"`bp'"'
        local source "dw_mode_by_project"
    }
    else if "`u_set_dw_mode'" == "1" {
        local mode `"`u_dw_mode'"'
        local source "dw_mode (user block)"
    }
    else if "`t_set_dw_mode'" == "1" {
        local mode `"`t_dw_mode'"'
        local source "dw_mode (top level)"
    }
    if !inlist(`"`mode'"', "producer", "reviewer") {
        local found = cond(`"`mode'"' == "", "none found", `"found "`mode'" in `source'"')
        noi di as error `"[cso_toolkit.dw_load_config] No valid dw_mode ("producer" or "reviewer") for `where' (`found')."'
        noi di as error "  Why: every cso-toolkit helper reads \$dw_mode to choose its producer or reviewer behaviour; there is no default."
        _dwcfg_hint, filepath(`"`filepath'"') user(`"`uname'"') project(`"`pname'"')
        error 459
    }
    global dw_mode `"`mode'"'
    return local dw_mode `"`mode'"'
    return local dw_mode_source "`source'"

    foreach k of local keys {
        if "`k'" == "dw_mode" continue
        if "`u_set_`k''" == "1" {
            global `k' `"`u_`k''"'
            return local `k' `"`u_`k''"'
        }
        else if "`t_set_`k''" == "1" {
            global `k' `"`t_`k''"'
            return local `k' `"`t_`k''"'
        }
    }

    return local filepath `"`filepath'"'
    return local user `"`user'"'
    return local project `"`project'"'
    noi di as txt `"{pstd}dw_load_config: loaded `filepath' (user `uname', project `pname'; dw_mode = $dw_mode from `source').{p_end}"'

end

* The YAML to add, with the user and project filled in (as the R and
* Python profiles print it).
cap program drop _dwcfg_hint
program define _dwcfg_hint
    syntax , filepath(string) user(string) project(string)
    noi di as error `"  Fix: in `filepath', inside your user block:"'
    noi di as error `"      `user':"'
    noi di as error `"        dw_mode: "reviewer""'
    noi di as error `"    or, for this project only:"'
    noi di as error `"      `user':"'
    noi di as error `"        dw_mode_by_project:"'
    noi di as error `"          `project': "producer""'
end
