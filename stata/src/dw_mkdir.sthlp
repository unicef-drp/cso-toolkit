{smcl}
{* *! version 1.0 24MAY2026}{...}
{viewerjumpto "Syntax" "dw_mkdir##syntax"}{...}
{viewerjumpto "Description" "dw_mkdir##description"}{...}
{viewerjumpto "Options" "dw_mkdir##options"}{...}
{viewerjumpto "Examples" "dw_mkdir##examples"}{...}
{viewerjumpto "Author" "dw_mkdir##author"}{...}

{title:Title}

{phang}
{bf:dw_mkdir} {hline 2} Recursive mkdir for the cso-toolkit Stata side.

{marker syntax}{...}
{title:Syntax}

{p 8 17 2}
{cmd:dw_mkdir} {cmd:,} {cmdab:parent(}{it:string}{cmd:)} {cmdab:newfolders(}{it:string}{cmd:)}

{marker description}{...}
{title:Description}

{pstd}
{cmd:dw_mkdir} creates {it:newfolders} (which may be a nested path with
forward or back slashes) underneath {it:parent}. Every intermediate
folder is created on demand. The command is idempotent: folders that
already exist are left alone.{p_end}

{pstd}
This mirrors R's {bf:dir.create(..., recursive = TRUE)} and is a port of
the World Bank EduAnalyticsToolkit {bf:rmkdir} command (v1.0 18SEP2019),
renamed to align with the cso-toolkit {bf:dw_*} family.{p_end}

{marker options}{...}
{title:Options}

{phang}
{cmdab:parent(}{it:string}{cmd:)} must already exist. Passing a non-existent
parent path raises Stata error 601.{p_end}

{phang}
{cmdab:newfolders(}{it:string}{cmd:)} is the path (relative to {it:parent})
to create. Use forward slashes for portability; back slashes are
normalised.{p_end}

{marker examples}{...}
{title:Examples}

{phang}
Create a sector subtree under the canonical deposit:{p_end}
{phang2}
{cmd:. dw_mkdir, parent("$teamsRawData") newfolders("ws/output/final")}
{p_end}

{phang}
Returned macros:{p_end}
{phang2}
{cmd:. return list}
{p_end}
{phang2}
{cmd:. local created `"`r(folder)'"'}
{p_end}

{marker author}{...}
{title:Author}

{pstd}
João Pedro Azevedo (port).{p_end}
{pstd}
Original {bf:rmkdir} by Kristoffer Bjärkefur, World Bank EduAnalyticsToolkit
({browse "https://github.com/worldbank/EduAnalyticsToolkit":github.com/worldbank/EduAnalyticsToolkit}).{p_end}
