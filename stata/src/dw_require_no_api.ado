*! version 1.0 26MAY2026 cso-toolkit cso-toolkit@unicef.org
*! Author: João Pedro Azevedo

* dw_require_no_api -- Stata sibling of the R / Python no-API gate.
*
* Reviewer-mode sessions must NOT call live external APIs (UIS, ILO,
* IGME, World Bank, SDMX endpoints, ...). All API access must route
* through frozen producer-deposited caches. This helper asserts that
* contract at any call site that is about to make a live network call:
*
*     dw_require_no_api , context("ed/06_pull_uis")
*
* On `$dw_mode == "reviewer"` the call aborts (Stata error 459) with
* the envelope-shaped message:
*
*     [cso_toolkit.dw_require_no_api] Reviewer mode forbids live API
*       calls (context: ed/06_pull_uis).
*       Why: reviewer sessions must read frozen producer caches to
*       preserve vintage permanence; any live API call breaks
*       provenance.
*       Fix: switch the call to dw_use() against the frozen cache,
*       or re-run in producer mode.
*
* When `$dw_mode` is empty or set to anything OTHER than "reviewer"
* (typically "producer") the call returns silently. This means
* producer + unknown / unset modes both pass through; only reviewer
* is blocked. Same shape as the R `dw_require_no_api()` helper in
* r/R/profile_helpers.R.

cap program drop dw_require_no_api
program define   dw_require_no_api, rclass

    syntax , [ CONtext(string) ]

    if "$dw_mode" == "reviewer" {
        local ctx_clause ""
        if `"`context'"' != "" {
            local ctx_clause `" (context: `context')"'
        }
        noi di as error ///
            "{phang}[cso_toolkit.dw_require_no_api] Reviewer mode forbids live API calls`ctx_clause'.{p_end}"
        noi di as error ///
            "{phang}  Why: reviewer sessions must read frozen producer caches to preserve vintage permanence; any live API call breaks provenance.{p_end}"
        noi di as error ///
            "{phang}  Fix: switch the call to dw_use() against the frozen cache, or re-run in producer mode.{p_end}"
        error 459
    }

    return local dw_mode "$dw_mode"
    if `"`context'"' != "" return local context `"`context'"'

end
