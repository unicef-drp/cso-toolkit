{smcl}
{* *! version 1.0 26MAY2026}{...}
{viewerjumpto "Syntax" "dw_require_no_api##syntax"}{...}
{viewerjumpto "Description" "dw_require_no_api##description"}{...}
{viewerjumpto "Options" "dw_require_no_api##options"}{...}
{viewerjumpto "Examples" "dw_require_no_api##examples"}{...}
{viewerjumpto "Returns" "dw_require_no_api##returns"}{...}
{viewerjumpto "Author" "dw_require_no_api##author"}{...}

{title:Title}

{phang}
{bf:dw_require_no_api} {hline 2} Block live API calls in reviewer mode.

{marker syntax}{...}
{title:Syntax}

{p 8 17 2}
{cmd:dw_require_no_api} [ {cmd:,} {cmdab:con:text(}{it:string}{cmd:)} ]

{marker description}{...}
{title:Description}

{pstd}
{cmd:dw_require_no_api} asserts the cso-toolkit reviewer-mode no-API
contract: when {bf:$dw_mode == "reviewer"} the call aborts (Stata
error 459) with the envelope-shaped {bf:[cso_toolkit.<func>]} WHAT /
Why / Fix message. In any other mode (producer, empty, anything
non-reviewer) the call returns silently.{p_end}

{pstd}
The rationale is the same as for the R + Python siblings: reviewer
sessions must read frozen producer-deposited caches so vintage
permanence is preserved. Any live network call (UIS, ILO, IGME, World
Bank, SDMX, generic HTTP) breaks that contract -- so call sites that
would otherwise issue one should preflight via
{cmd:dw_require_no_api}.{p_end}

{marker options}{...}
{title:Options}

{phang}
{cmdab:context(}{it:string}{cmd:)} -- optional label included in the
error message so the failing call site is easy to find in a long
session log (typically the sector + script stub, e.g.
{cmd:context("ed/06_pull_uis")}).{p_end}

{marker examples}{...}
{title:Examples}

{phang}
Generic preflight at the top of an API-fetcher script:{p_end}
{phang2}
{cmd:. dw_require_no_api , context("ed/06_pull_uis")}{p_end}

{phang}
Inside a wrapper that decides between cache and live fetch:{p_end}
{phang2}
{cmd:. capture confirm file "`cache_path'"}{p_end}
{phang2}
{cmd:. if _rc != 0 {c -(}}{p_end}
{phang2}
{cmd:.     dw_require_no_api , context("`sector'/live_fetch")}{p_end}
{phang2}
{cmd:.     // ... live API call goes here ...}{p_end}
{phang2}
{cmd:. {c )-}}{p_end}

{marker returns}{...}
{title:Returns}

{pstd}
{cmd:r(dw_mode)} -- session mode at the time of the check{break}
{cmd:r(context)} -- the {bf:context()} argument if supplied{p_end}

{marker author}{...}
{title:Author}

{pstd}
João Pedro Azevedo (UNICEF Data, Analytics, Planning and Monitoring).
Mirrors the R helper {bf:dw_require_no_api()} shipped in
{bf:r/R/profile_helpers.R} and the Python equivalent in
{bf:python/src/profile_helpers.py}.{p_end}
