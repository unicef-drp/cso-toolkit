{smcl}
{* *! version 1.0 24MAY2026}{...}
{viewerjumpto "Syntax" "dw_compare##syntax"}{...}
{viewerjumpto "Description" "dw_compare##description"}{...}
{viewerjumpto "Options" "dw_compare##options"}{...}
{viewerjumpto "Examples" "dw_compare##examples"}{...}
{viewerjumpto "Returns" "dw_compare##returns"}{...}
{viewerjumpto "See also" "dw_compare##seealso"}{...}
{viewerjumpto "Author" "dw_compare##author"}{...}

{title:Title}

{phang}
{bf:dw_compare} {hline 2} Compare two Stata datasets on an id key, classify drift per column.

{marker syntax}{...}
{title:Syntax}

{p 8 17 2}
{cmd:dw_compare} {cmd:,} {cmdab:cur:rent(}{it:string}{cmd:)} {cmdab:ref:erence(}{it:string}{cmd:)} {cmdab:id:vars(}{it:string}{cmd:)}
{break}    [ {cmdab:val:uevars(}{it:string}{cmd:)} {cmd:tol(}{it:#}{cmd:)} {cmdab:rep:ort(}{it:string}{cmd:)} {cmdab:lab:el(}{it:string}{cmd:)} ]

{marker description}{...}
{title:Description}

{pstd}
{cmd:dw_compare} is the Stata sibling of the R {bf:dw_compare()} helper.
Given two {bf:.dta} files and a set of id columns, it merges them on
the id key and classifies each value column as identical,
numerically-equivalent within {bf:tol()}, or different.{p_end}

{pstd}
The summary reports four counts:{p_end}
{phang}
  - {bf:added}: id present in {it:current}, absent in {it:reference}.{p_end}
{phang}
  - {bf:removed}: id present in {it:reference}, absent in {it:current}.{p_end}
{phang}
  - {bf:common}: id present in both — eligible for value comparison.{p_end}
{phang}
  - {bf:changed cells}: total cell-level drift across the common rows.{p_end}

{pstd}
For a richer Markdown report (per-row diff tables, wiggle room, varlist
length controls), use the upstream
{browse "https://github.com/worldbank/EduAnalyticsToolkit":comparefiles}
command directly. {cmd:dw_compare} is sized for the cso-toolkit IO
contract (publication-gate sized), not for full editorial diffs.{p_end}

{marker options}{...}
{title:Options}

{phang}
{cmdab:current(}{it:string}{cmd:)} — path to the new/current dataset
({bf:.dta} extension optional).{p_end}

{phang}
{cmdab:reference(}{it:string}{cmd:)} — path to the prior/canonical dataset.{p_end}

{phang}
{cmdab:idvars(}{it:string}{cmd:)} — variables that uniquely identify a
row in {bf:both} datasets. {bf:isid} runs on each side; a non-unique
key aborts the compare.{p_end}

{phang}
{cmdab:valuevars(}{it:string}{cmd:)} — variables to compare. If omitted,
all non-id columns common to both files are compared.{p_end}

{phang}
{cmd:tol(}{it:#}{cmd:)} — numeric tolerance for value differences (default
{bf:1e-8}). Strings are compared exactly.{p_end}

{phang}
{cmdab:report(}{it:string}{cmd:)} — optional path for a Markdown summary
file (row counts + per-column n_diff).{p_end}

{phang}
{cmdab:label(}{it:string}{cmd:)} — label printed in the summary header
and the Markdown report title (default {bf:dw_compare}).{p_end}

{marker examples}{...}
{title:Examples}

{phang}
Compare a fresh production run against the canonical deposit:{p_end}
{phang2}
{cmd:. dw_compare, current("$wrkdir/dw_ws.dta") ///}
{break}{cmd:    reference("$teamsWrkDataCanonical/ws/dw_ws.dta") ///}
{break}{cmd:    idvars(REF_AREA INDICATOR TIME_PERIOD) ///}
{break}{cmd:    valuevars(OBS_VALUE DATA_SOURCE) tol(1e-5) ///}
{break}{cmd:    label("ws prod vs canonical") ///}
{break}{cmd:    report("$tempdir/ws_compare.md")}
{p_end}

{marker returns}{...}
{title:Returns}

{pstd}
{cmd:r(n_ref)}     — row count of reference{break}
{cmd:r(n_cur)}     — row count of current{break}
{cmd:r(n_added)}   — rows in current, not in reference{break}
{cmd:r(n_removed)} — rows in reference, not in current{break}
{cmd:r(n_common)}  — rows in both{break}
{cmd:r(n_changed)} — total cells differing on common rows{break}
{cmd:r(col_changed)}   — columns with at least one diff{break}
{cmd:r(col_identical)} — columns with zero diffs{p_end}

{marker seealso}{...}
{title:See also}

{phang}
{help dw_save:dw_save} — the IO contract writer this helper validates against.{p_end}
{phang}
{help dw_mkdir:dw_mkdir} — recursive mkdir, for staging compare-report output folders.{p_end}
{phang}
{browse "https://github.com/worldbank/EduAnalyticsToolkit":comparefiles} — the full upstream EduAnalyticsToolkit command (richer Markdown report).{p_end}

{marker author}{...}
{title:Author}

{pstd}
João Pedro Azevedo (port).{p_end}
{pstd}
Original {bf:comparefiles} / {bf:edukit_comparefiles} by
Kristoffer Bjärkefur, World Bank EduAnalyticsToolkit.{p_end}
