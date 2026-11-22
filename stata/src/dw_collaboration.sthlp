{smcl}
{* *! version 1.0 21NOV2026}{...}
{viewerjumpto "Syntax" "dw_collaboration##syntax"}{...}
{viewerjumpto "Description" "dw_collaboration##description"}{...}
{viewerjumpto "Options" "dw_collaboration##options"}{...}
{viewerjumpto "Returns" "dw_collaboration##returns"}{...}

{title:Title}

{phang}
{bf:dw_collaboration} {hline 2} The project's collaboration model:
single- or multi-producer.

{marker syntax}{...}
{title:Syntax}

{p 8 17 2}
{cmd:dw_collaboration} [ {cmd:,} {cmd:root(}{it:string}{cmd:)} {cmd:refresh} ]

{marker description}{...}
{title:Description}

{pstd}
Session modes stay per person ({bf:dw_mode}: producer | reviewer). How many
people may {it:produce} is a property of the project, committed as
{bf:cso_project.yml} at the repository root:{p_end}

        {bf:schema: cso_project/1}
        {bf:collaboration: multi-producer}
        {bf:collaboration_since: 2026-11-20}

{pstd}
{cmd:dw_collaboration} finds the file by walking up from the working
directory and stopping at the repository root (the first folder holding
{bf:.git}), validates it, and caches the result for the session in
{bf:$dw_collaboration_model}, {bf:$dw_project_file} and
{bf:$dw_session_start} (ISO-8601 UTC; it needs Stata's Python integration,
Stata 16+). No file means {bf:single-producer}.{p_end}

{pstd}
{help dw_save} calls it. Call it in the profile do-file so the session start
is the start of the work. In a multi-producer project {cmd:dw_save} refuses
out-of-band and concurrent writes unless {cmd:takeover}. The switch itself
({bf:dw_set_collaboration()}, which also baselines the existing sidecars) is
made from R or Python in one reviewed pull request. Mirrors R/Python
{bf:dw_collaboration()} (#168).{p_end}

{marker options}{...}
{title:Options}

{phang}
{cmd:root(}{it:string}{cmd:)} -- start the search there instead of the
working directory; implies {cmd:refresh}.{p_end}

{phang}
{cmd:refresh} -- resolve again instead of returning the cached model.{p_end}

{marker returns}{...}
{title:Returns}

{pstd}
{cmd:r(model)}, {cmd:r(file)} (empty when there is none),
{cmd:r(session_start)}.{p_end}
