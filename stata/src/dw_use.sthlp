{smcl}
{* *! version 1.0 26MAY2026}{...}
{viewerjumpto "Syntax" "dw_use##syntax"}{...}
{viewerjumpto "Description" "dw_use##description"}{...}
{viewerjumpto "Options" "dw_use##options"}{...}
{viewerjumpto "Mode contract" "dw_use##mode"}{...}
{viewerjumpto "Z: integrity" "dw_use##z_integrity"}{...}
{viewerjumpto "Examples" "dw_use##examples"}{...}
{viewerjumpto "Returns" "dw_use##returns"}{...}
{viewerjumpto "Author" "dw_use##author"}{...}

{title:Title}

{phang}
{bf:dw_use} {hline 2} Read a file under the cso-toolkit IO contract.

{marker syntax}{...}
{title:Syntax}

{p 8 17 2}
{cmd:dw_use} {cmd:,} {cmdab:file:name(}{it:string}{cmd:)}
{break}    [ {cmdab:p:ath(}{it:string}{cmd:)} {cmd:as(}{it:string}{cmd:)} {cmdab:col:s(}{it:string}{cmd:)}
{break}      {cmdab:verify_z(}{it:string}{cmd:)} {cmd:nofallback_canonical} ]

{marker description}{...}
{title:Description}

{pstd}
{cmd:dw_use} is the Stata sibling of the R {bf:dw_use()} helper. It
reads a file from the warehouse, dispatching on the extension, and
applies the v0.4.0 mode-contract resolution order plus a non-blocking
Z: drive integrity check on canonical reads.{p_end}

{pstd}
Supported extensions on the Stata side: {bf:.dta}, {bf:.csv},
{bf:.xlsx}. For {bf:.parquet} / {bf:.rds} route the producer pipeline
through R or Python and {bf:dw_save()} the result to {bf:.dta} before
calling {cmd:dw_use} from Stata.{p_end}

{marker mode}{...}
{title:Mode contract (v0.4.0)}

{pstd}
The read resolution order depends on {bf:$dw_mode}.{p_end}

{phang}
{bf:Producer / unknown mode (v0.3.0 preserved).} Local-first: try the
literal path first; if missing and {bf:nofallback_canonical} is not
set, retry under the canonical equivalent
({bf:$teamsWrkDataCanonical} / {bf:$teamsRawDataCanonical}).{p_end}

{phang}
{bf:Reviewer mode.} Network-first: try the Teams canonical equivalent
first, then the Z: drive mirror (when {bf:$dwZDrive} and
{bf:$teamsFolderCanonical} are set), then fall back to the repo-local
literal path with an envelope-shaped provenance warning. If all four
miss, the helper aborts with the "contact the sector producer"
envelope (Stata error 601).{p_end}

{marker z_integrity}{...}
{title:Z: drive integrity check}

{pstd}
For canonical reads (path under {bf:$teamsFolderCanonical}) the helper
optionally compares the Teams primary against the Z: mirror. Cheap
default {bf:verify_z(size)} compares byte counts; {bf:verify_z(sha256)}
loads both sides in turn and compares Stata-native {bf:datasignature}
content hashes; {bf:verify_z(off)} disables the check. Failures emit a
warning but do NOT abort the read -- the integrity status is surfaced
in {bf:r(z_status)} for callers that want to act on it.{p_end}

{pstd}
The sibling {bf:.provenance.json} sidecar (when present) is parsed
for the recorded {bf:datasignature}; the helper computes the live
signature post-read and reports mismatches via {bf:r(prov_status)}.
This is also non-blocking.{p_end}

{marker options}{...}
{title:Options}

{phang}
{cmdab:filename(}{it:string}{cmd:)} -- file basename (may include
extension); resolved against {bf:path()} if both are given, or used as
an absolute path when {bf:path()} is empty.{p_end}

{phang}
{cmdab:path(}{it:string}{cmd:)} -- optional source directory. Use
either this + {bf:filename()} or pass an absolute path through
{bf:filename()}.{p_end}

{phang}
{cmd:as(}{it:string}{cmd:)} -- documented for R / Python parity. Stata
always returns the read dataset in memory; passing
{bf:as(data.frame)} is a no-op, anything else emits an advisory.{p_end}

{phang}
{cmdab:cols(}{it:string}{cmd:)} -- whitespace-separated subset of
variables to keep. Only honoured for {bf:.dta} reads (passed as the
{bf:varlist} argument to {bf:use}).{p_end}

{phang}
{cmdab:verify_z(}{it:string}{cmd:)} -- one of {bf:size} (default),
{bf:sha256}, or {bf:off}. Controls the Z: drive integrity check.{p_end}

{phang}
{cmd:nofallback_canonical} -- in producer mode, skip the canonical
fallback when the literal path is missing. In reviewer mode, skip the
local fallback so a missing Teams / Z: artefact aborts immediately
rather than reading an unverified local copy.{p_end}

{marker examples}{...}
{title:Examples}

{phang}
Producer-mode read of a working file:{p_end}
{phang2}
{cmd:. dw_use , filename("dw_ed_edu.dta") path("$teamsWrkData/ed")}{p_end}

{phang}
Reviewer-mode read with full provenance + Z: integrity check:{p_end}
{phang2}
{cmd:. dw_use , filename("dw_ed_edu.dta") path("$teamsWrkData/ed") verify_z(sha256)}{p_end}

{phang}
Subset columns (Stata .dta only):{p_end}
{phang2}
{cmd:. dw_use , filename("dw_ed_edu.dta") path("$teamsWrkData/ed") cols(REF_AREA INDICATOR OBS_VALUE)}{p_end}

{marker returns}{...}
{title:Returns}

{pstd}
{cmd:r(resolved)} -- final path actually read{break}
{cmd:r(resolution)} -- which branch the resolver picked
({bf:literal}, {bf:teams_canonical}, {bf:z_mirror},
{bf:local_fallback}){break}
{cmd:r(sidecar)} -- expected sibling sidecar path (whether or not it
exists){break}
{cmd:r(prov_datasignature)} -- datasignature recorded in the sidecar
(empty when no sidecar){break}
{cmd:r(live_datasignature)} -- datasignature of the dataset just read
(empty for non-.dta){break}
{cmd:r(prov_status)} -- one of {bf:no_sidecar}, {bf:match},
{bf:mismatch}, {bf:stata_live_failed}{break}
{cmd:r(z_status)} -- one of {bf:skipped}, {bf:z_missing},
{bf:match_size}, {bf:size_mismatch}, {bf:match_sha256},
{bf:sha256_mismatch}, {bf:sha256_unavailable},
{bf:sha256_unsupported_for_ext}{break}
{cmd:r(n_rows)}, {cmd:r(n_cols)} -- shape of the read dataset.{p_end}

{marker author}{...}
{title:Author}

{pstd}
João Pedro Azevedo (UNICEF Data, Analytics, Planning and Monitoring).
Mirrors the R / Python {bf:dw_use()} contract documented in
{bf:docs/dw_io_reference.md} and {bf:docs/dw_io_python_reference.md}.{p_end}
