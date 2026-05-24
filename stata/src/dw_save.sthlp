{smcl}
{* *! version 1.0 24MAY2026}{...}
{viewerjumpto "Syntax" "dw_save##syntax"}{...}
{viewerjumpto "Description" "dw_save##description"}{...}
{viewerjumpto "Options" "dw_save##options"}{...}
{viewerjumpto "Mode contract" "dw_save##mode"}{...}
{viewerjumpto "Provenance sidecar" "dw_save##sidecar"}{...}
{viewerjumpto "Examples" "dw_save##examples"}{...}
{viewerjumpto "Returns" "dw_save##returns"}{...}
{viewerjumpto "Author" "dw_save##author"}{...}

{title:Title}

{phang}
{bf:dw_save} {hline 2} Save a Stata dataset under the cso-toolkit IO contract.

{marker syntax}{...}
{title:Syntax}

{p 8 17 2}
{cmd:dw_save} {cmd:,} {cmdab:file:name(}{it:string}{cmd:)} {cmdab:p:ath(}{it:string}{cmd:)} {cmdab:id:vars(}{it:string}{cmd:)}
{break}    [ {cmdab:meta:data(}{it:string asis}{cmd:)} {cmdab:ti:tle(}{it:string asis}{cmd:)} {cmdab:pro:ducer(}{it:string asis}{cmd:)}
{break}      {cmdab:so:urces(}{it:string asis}{cmd:)} {cmdab:con:tact(}{it:string}{cmd:)} {cmdab:vi:ntage(}{it:string}{cmd:)}
{break}      {cmd:allow_canonical_write} {cmd:nocompress} {cmd:nosidecar} ]

{marker description}{...}
{title:Description}

{pstd}
{cmd:dw_save} is the Stata sibling of the R {bf:dw_save()} helper. It
enforces a four-step quality contract before writing:{p_end}

{phang}
1. {bf:Mode contract}: if {bf:$dw_mode == "reviewer"} and {it:path}
   resolves under a canonical root ({bf:$teamsWrkDataCanonical} /
   {bf:$teamsRawDataCanonical}), the call is BLOCKED (Stata error 459)
   unless {bf:allow_canonical_write} is passed.{p_end}

{phang}
2. {bf:Path validation}: {it:path} must already exist; create it first
   with {help dw_mkdir:dw_mkdir} if needed.{p_end}

{phang}
3. {bf:Row uniqueness}: {bf:isid `idvars'} is run; the save aborts if
   {it:idvars} do not uniquely identify the dataset or contain
   missings.{p_end}

{phang}
4. {bf:Compress + save}: {bf:compress} (unless {bf:nocompress}) and
   {bf:save, replace} to {it:path}/{it:filename}.dta.{p_end}

{pstd}
After saving, {cmd:dw_save} emits a {bf:.provenance.json} sidecar next
to the {bf:.dta} file recording when, who, mode, schema, idvars, and
any caller-supplied metadata. The sidecar uses Stata's native
{bf:datasignature} (content hash of variable values) rather than a
file-level SHA-256 so no external dependency or AppLocker-restricted
shell call is required.{p_end}

{marker options}{...}
{title:Options}

{phang}
{cmdab:filename(}{it:string}{cmd:)} — base filename (with or without
{bf:.dta} extension; if omitted it is added).{p_end}

{phang}
{cmdab:path(}{it:string}{cmd:)} — target directory (must exist).{p_end}

{phang}
{cmdab:idvars(}{it:string}{cmd:)} — variables that uniquely identify a
row. Stata's {bf:isid} runs against these; failure aborts the save.{p_end}

{phang}
{cmdab:metadata(}{it:string asis}{cmd:)} — pass-through key/value pairs,
semicolon-separated. Example: {cmd:metadata("key1 value1; key2 value2")}.
Written verbatim into the {bf:metadata} block of the sidecar.{p_end}

{phang}
{cmdab:title(}{it:string asis}{cmd:)},
{cmdab:producer(}{it:string asis}{cmd:)},
{cmdab:sources(}{it:string asis}{cmd:)},
{cmdab:contact(}{it:string}{cmd:)},
{cmdab:vintage(}{it:string}{cmd:)} — named convenience metadata fields.{p_end}

{phang}
{cmd:allow_canonical_write} — escape hatch for reviewer-mode writes
under canonical roots (DBM bootstraps only; never use in regular
review work).{p_end}

{phang}
{cmd:nocompress} — skip the {bf:compress} step.{p_end}

{phang}
{cmd:nosidecar} — skip writing the {bf:.provenance.json} sidecar (not
recommended; use only for one-off scratch saves).{p_end}

{marker examples}{...}
{title:Examples}

{phang}
Producer-mode save with full metadata:{p_end}
{phang2}
{cmd:. dw_save, filename(dw_ws_water) path("$teamsWrkData/ws") idvars(REF_AREA INDICATOR TIME_PERIOD) ///}
{break}{cmd:    title("WASH indicators - UNICEF DW format") ///}
{break}{cmd:    producer("01_dw_prep/012_codes/ws/02_aggregate.do") ///}
{break}{cmd:    sources("JMP 2024; MICS6 latest") ///}
{break}{cmd:    contact("@karavan88") ///}
{break}{cmd:    vintage("2026-05")}
{p_end}

{phang}
Reviewer-mode bootstrap (rare):{p_end}
{phang2}
{cmd:. dw_save, filename(seed) path("$teamsRawDataCanonical/_apis/bootstrap") ///}
{break}{cmd:    idvars(key) allow_canonical_write}
{p_end}

{marker returns}{...}
{title:Returns}

{pstd}
{cmd:r(path)} — full .dta path written{break}
{cmd:r(sidecar)} — path of the .provenance.json sidecar{break}
{cmd:r(n_rows)} — row count at write time{break}
{cmd:r(n_cols)} — column count at write time{break}
{cmd:r(datasignature)} — content hash from {bf:datasignature}{p_end}

{marker author}{...}
{title:Author}

{pstd}
João Pedro Azevedo (port).{p_end}
{pstd}
Original {bf:edukit_save} / {bf:savemetadata} by Diana Goldemberg,
World Bank EduAnalyticsToolkit
({browse "https://github.com/worldbank/EduAnalyticsToolkit":github.com/worldbank/EduAnalyticsToolkit}).{p_end}
