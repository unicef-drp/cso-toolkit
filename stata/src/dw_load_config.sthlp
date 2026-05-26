{smcl}
{* *! version 1.0 26MAY2026}{...}
{viewerjumpto "Syntax" "dw_load_config##syntax"}{...}
{viewerjumpto "Description" "dw_load_config##description"}{...}
{viewerjumpto "Schema" "dw_load_config##schema"}{...}
{viewerjumpto "Options" "dw_load_config##options"}{...}
{viewerjumpto "Examples" "dw_load_config##examples"}{...}
{viewerjumpto "Returns" "dw_load_config##returns"}{...}
{viewerjumpto "Author" "dw_load_config##author"}{...}

{title:Title}

{phang}
{bf:dw_load_config} {hline 2} Load cso-toolkit session globals from a
YAML config file.

{marker syntax}{...}
{title:Syntax}

{p 8 17 2}
{cmd:dw_load_config} [ {cmd:,} {cmdab:file:path(}{it:string}{cmd:)} ]

{marker description}{...}
{title:Description}

{pstd}
{cmd:dw_load_config} reads a YAML file (defaulting to
{bf:~/.config/user_config.yml}) and populates the cso-toolkit session
globals. It uses a hand-rolled key:value parser so the helper has no
external dependencies and runs cleanly on AppLocker-locked corporate
Stata installs that block third-party YAML packages.{p_end}

{pstd}
Only the documented subset of YAML is supported: one
{bf:key: value} mapping per line, comments after {bf:#}, optional
single or double quotes around values, and trailing inline comments.
Nested mappings, lists, anchors, and multi-line strings are NOT
handled -- if your config grows past these constraints, parse it
upstream and pass the resolved globals in directly.{p_end}

{pstd}
The helper hard-stops (Stata error 459) when {bf:dw_mode} is missing
or set to anything other than {bf:producer} or {bf:reviewer}. This
mirrors the R sibling validation in {bf:profile_helpers.R}.{p_end}

{marker schema}{...}
{title:Schema (recognised keys)}

{pstd}
The following keys are recognised; unknown keys are silently ignored
so the same YAML can also hold settings other tooling needs.{p_end}

{phang}
{bf:dw_mode}      -- required; one of {bf:producer} | {bf:reviewer}.{p_end}

{phang}
{bf:teamsWrkData} -- session working-data root (sandbox in reviewer
mode; canonical in producer mode -- the profile typically wires the
right one in).{p_end}

{phang}
{bf:teamsRawData} -- session raw-data root.{p_end}

{phang}
{bf:teamsWrkDataCanonical},
{bf:teamsRawDataCanonical} -- canonical (frozen-deposit) roots used by
the v0.4.0 mode contract for the redundant-write + network-first-read
behaviour.{p_end}

{phang}
{bf:teamsFolderCanonical} -- top-level canonical Teams folder.
{bf:dw_use} uses this together with {bf:dwZDrive} to derive Z: drive
mirror paths during reviewer-mode resolution and the integrity check.{p_end}

{phang}
{bf:dwZDrive} -- mount point for the Z: drive carbon-copy mirror
(e.g. {bf:Z:/}). When set together with {bf:teamsFolderCanonical},
{bf:dw_use} extends the reviewer-mode lookup chain past Teams to the
Z: mirror and runs the size / hash integrity check.{p_end}

{phang}
{bf:sandboxRoot}  -- sandbox root for reviewer-mode writes; surfaced
to scripts that need an explicit per-user scratch area.{p_end}

{marker options}{...}
{title:Options}

{phang}
{cmdab:filepath(}{it:string}{cmd:)} -- override the default config
path. Useful for testing fixtures and per-project overrides.{p_end}

{marker examples}{...}
{title:Examples}

{phang}
Default location (typical session start in {bf:profile.do}):{p_end}
{phang2}
{cmd:. dw_load_config}{p_end}

{phang}
Test fixture:{p_end}
{phang2}
{cmd:. dw_load_config , filepath("`c(tmpdir)'/dw_test_config.yml")}{p_end}

{marker returns}{...}
{title:Returns}

{pstd}
Every key read from the YAML is also returned in r() (and set as the
matching global). Missing keys mean missing r() entries.{p_end}

{pstd}
{cmd:r(dw_mode)},
{cmd:r(teamsWrkData)},
{cmd:r(teamsRawData)},
{cmd:r(teamsWrkDataCanonical)},
{cmd:r(teamsRawDataCanonical)},
{cmd:r(teamsFolderCanonical)},
{cmd:r(dwZDrive)},
{cmd:r(sandboxRoot)},
{cmd:r(filepath)}.{p_end}

{marker author}{...}
{title:Author}

{pstd}
João Pedro Azevedo (UNICEF Data, Analytics, Planning and Monitoring).
Mirrors the schema validated by the R sibling
{bf:create_profile()} / {bf:review_profile()} in
{bf:r/R/profile_helpers.R}.{p_end}
