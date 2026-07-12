*! version 1.2 12JUL2026 cso-toolkit cso-toolkit@unicef.org
*! Author: João Pedro Azevedo

* dw_load_config -- read `~/.config/user_config.yml` (or any caller-
* supplied YAML file) and populate the cso-toolkit session globals.
*
* Stata cannot link external YAML packages on AppLocker-locked
* corporate Windows installs, so this helper ships a minimal
* hand-rolled key:value parser that handles the documented subset of
* the cso-toolkit user-config schema:
*
*     dw_mode: producer
*     teamsWrkData: "C:/Users/<you>/Teams/.../013_wrkdata"
*     teamsRawData: "C:/Users/<you>/Teams/.../011_rawdata"
*     teamsWrkDataCanonical: "C:/Users/<you>/.../DW-MASTER/.../013_wrkdata"
*     teamsRawDataCanonical: "C:/Users/<you>/.../DW-MASTER/.../011_rawdata"
*     teamsFolderCanonical: "C:/Users/<you>/.../DW-MASTER"
*     dwZDrive: "Z:/"
*     dwZDriveUNC: '\\<server>\<share>'    (optional; consumed by dw_map_drive)
*     sandboxRoot: "C:/Users/<you>/sandbox"
*
* Behaviour:
*   - One `key: value` per line. Comments (`#`) and blank lines skipped.
*   - Values may be quoted (`"..."` / `'...'`) or bare; surrounding
*     whitespace and quotes are stripped.
*   - Nested mappings, lists, anchors, multi-line strings, and `null`
*     literals are NOT supported -- this is a deliberate subset to
*     keep the parser auditable in a single .ado file.
*   - Only TOP-LEVEL (column-0) keys are read. A line that begins with
*     whitespace is nested under some parent block and is skipped by the
*     indent guard, and a top-level block header (e.g. `datalib:`) is an
*     unknown key and is ignored. This is what lets a SHARED
*     `~/.config/user_config.yml` carry a `datalib:` block alongside the
*     toolkit's flat keys without the parser mis-adopting a nested key
*     (e.g. a datalib block's `sandboxRoot`) as a toolkit global.
*   - Unknown keys are silently ignored (the YAML may contain entries
*     other helpers care about).
*   - Hard-stops with envelope-shaped error 459 when `dw_mode` is
*     missing or is anything other than {"producer", "reviewer"} --
*     this mirrors the R `profile_helpers` validation.
*
* Returns the parsed values in r() and sets each one as a matching
* global ($dw_mode, $teamsWrkData, ...).  Note: this helper does NOT
* derive mode-aware globals from the canonical keys -- it sets exactly
* what the YAML provides.  Profile scripts that want to flip
* `$teamsWrkData` to the canonical root in producer mode (and the
* sandbox root in reviewer mode) should do that swap themselves after
* `dw_load_config` returns.

cap program drop dw_load_config
program define   dw_load_config, rclass

    syntax , [ FILEpath(string) ]

    *---------------------------------------------------------------
    * 1. Resolve config path
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
            "{phang}  Fix: create `filepath' with at minimum `dw_mode: producer` (or reviewer), or pass a different filepath().{p_end}"
        error 601
    }

    *---------------------------------------------------------------
    * 2. Walk the file line by line
    *---------------------------------------------------------------
    tempname fh
    file open `fh' using `"`filepath'"', read text
    file read `fh' line

    * Track which keys we have seen so we can warn on missing dw_mode.
    local seen_dw_mode 0

    while r(eof) == 0 {
        local raw `"`line'"'

        * Indent guard (checked on the RAW line, before trimming): a line
        * that begins with whitespace is nested under a parent key -- for
        * example a child of a `datalib:` block in a shared user_config.yml.
        * This flat parser reads only top-level keys, so an indented line is
        * never one of ours; skip it rather than mis-adopting a nested key
        * (e.g. a datalib block's `sandboxRoot`) as a toolkit global.
        local ind = substr(`"`raw'"', 1, 1)
        if "`ind'" == " " | "`ind'" == char(9) {
            file read `fh' line
            continue
        }

        * Strip leading / trailing whitespace.
        local raw = trim(`"`raw'"')

        * Skip blank lines and comments.
        if `"`raw'"' == "" {
            file read `fh' line
            continue
        }
        local first = substr(`"`raw'"', 1, 1)
        if "`first'" == "#" {
            file read `fh' line
            continue
        }

        * Find the first ":" separator. We use strpos rather than
        * gettoken so a value containing ":" (e.g. a Windows path
        * "C:/...") is preserved intact.
        local colon = strpos(`"`raw'"', ":")
        if `colon' == 0 {
            file read `fh' line
            continue
        }

        local key   = trim(substr(`"`raw'"', 1, `colon' - 1))
        local value = trim(substr(`"`raw'"', `colon' + 1, .))

        * Strip a trailing inline comment.
        local hash = strpos(`"`value'"', "#")
        if `hash' > 0 {
            local value = trim(substr(`"`value'"', 1, `hash' - 1))
        }

        * Strip wrapping single or double quotes if present. Compound
        * quotes are required around the macro-expanded first/last chars:
        * a bare "`lq'" expands to """ when the value is double-quoted,
        * which Stata mis-parses as r(133) -- so a quoted value such as
        * `teamsWrkData: "C:/..."` (exactly as the schema documents) would
        * otherwise crash the parser (fixed in v1.1).
        if length(`"`value'"') >= 2 {
            local lq = substr(`"`value'"', 1, 1)
            local rq = substr(`"`value'"', length(`"`value'"'), 1)
            if (`"`lq'"' == `"""' & `"`rq'"' == `"""') | (`"`lq'"' == "'" & `"`rq'"' == "'") {
                local value = substr(`"`value'"', 2, length(`"`value'"') - 2)
            }
        }

        *-----------------------------------------------------------
        * 3. Dispatch on the recognised keys
        *-----------------------------------------------------------
        if "`key'" == "dw_mode" {
            * Validate
            if !inlist("`value'", "producer", "reviewer") {
                noi di as error ///
                    "{phang}[cso_toolkit.dw_load_config] Invalid dw_mode `value' (must be `producer' or `reviewer').{p_end}"
                noi di as error ///
                    "{phang}  Fix: edit `filepath' so `dw_mode' is set to one of the two supported modes.{p_end}"
                file close `fh'
                error 459
            }
            global dw_mode `"`value'"'
            return local dw_mode `"`value'"'
            local seen_dw_mode 1
        }
        else if "`key'" == "teamsWrkData" {
            global teamsWrkData `"`value'"'
            return local teamsWrkData `"`value'"'
        }
        else if "`key'" == "teamsRawData" {
            global teamsRawData `"`value'"'
            return local teamsRawData `"`value'"'
        }
        else if "`key'" == "teamsWrkDataCanonical" {
            global teamsWrkDataCanonical `"`value'"'
            return local teamsWrkDataCanonical `"`value'"'
        }
        else if "`key'" == "teamsRawDataCanonical" {
            global teamsRawDataCanonical `"`value'"'
            return local teamsRawDataCanonical `"`value'"'
        }
        else if "`key'" == "teamsFolderCanonical" {
            global teamsFolderCanonical `"`value'"'
            return local teamsFolderCanonical `"`value'"'
        }
        else if "`key'" == "dwZDrive" {
            global dwZDrive `"`value'"'
            return local dwZDrive `"`value'"'
        }
        else if "`key'" == "dwZDriveUNC" {
            global dwZDriveUNC `"`value'"'
            return local dwZDriveUNC `"`value'"'
        }
        else if "`key'" == "sandboxRoot" {
            global sandboxRoot `"`value'"'
            return local sandboxRoot `"`value'"'
        }
        * Unknown keys are intentionally ignored.

        file read `fh' line
    }
    file close `fh'

    *---------------------------------------------------------------
    * 4. Hard-stop if dw_mode is missing
    *---------------------------------------------------------------
    if `seen_dw_mode' == 0 {
        noi di as error ///
            "{phang}[cso_toolkit.dw_load_config] Required key `dw_mode' is missing from `filepath'.{p_end}"
        noi di as error ///
            "{phang}  Why: every cso-toolkit helper (dw_save, dw_use, dw_require_no_api, ...) reads `$dw_mode' to dispatch its producer / reviewer behaviour.{p_end}"
        noi di as error ///
            "{phang}  Fix: add `dw_mode: producer' (or `reviewer') to the top of `filepath'.{p_end}"
        error 459
    }

    return local filepath `"`filepath'"'
    noi di as txt `"{pstd}dw_load_config: loaded `filepath' (dw_mode = $dw_mode).{p_end}"'

end
