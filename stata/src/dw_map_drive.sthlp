{smcl}
{* *! version 1.0 12JUL2026}{...}
{viewerjumpto "Syntax" "dw_map_drive##syntax"}{...}
{viewerjumpto "Description" "dw_map_drive##description"}{...}
{viewerjumpto "Options" "dw_map_drive##options"}{...}
{viewerjumpto "Examples" "dw_map_drive##examples"}{...}
{viewerjumpto "Returns" "dw_map_drive##returns"}{...}
{viewerjumpto "Author" "dw_map_drive##author"}{...}

{title:Title}

{phang}
{bf:dw_map_drive} {hline 2} Map the configured network drive (default Z:).

{marker syntax}{...}
{title:Syntax}

{p 8 17 2}
{cmd:dw_map_drive} [ {cmd:,} {cmdab:let:ter(}{it:string}{cmd:)}
{cmd:unc(}{it:string}{cmd:)} {cmdab:con:fig(}{it:string}{cmd:)}
{cmd:persistent(}{it:yes|no}{cmd:)} {cmd:force} {cmdab:dry:run}
{cmdab:disc:over} ]

{marker description}{...}
{title:Description}

{pstd}
{cmd:dw_map_drive} maps the team network drive on Windows. With no options it
reads the mount letter ({bf:dwZDrive}, default {bf:Z:}) and the share
({bf:dwZDriveUNC}) from your {bf:user_config.yml} via {help dw_load_config},
then runs {bf:net use} when the drive is not already available. It is
{it:safe by default}: an existing mapping is never disturbed unless {bf:force}
is given, and {bf:dryrun} prints the command without changing anything.{p_end}

{pstd}
This is the toolkit counterpart of datalib's {bf:mapzdrive}, kept under the
{bf:dw_*} prefix because drive mapping is shared onboarding across the CSO
estate. It is Windows-only; on any other OS it stops with error 198.{p_end}

{marker options}{...}
{title:Options}

{phang}
{cmdab:let:ter(}{it:string}{cmd:)} -- drive letter to map (e.g. {bf:Z:}).
Overrides {bf:dwZDrive} from the config.{p_end}

{phang}
{cmd:unc(}{it:string}{cmd:)} -- the {bf:\\server\share} to map. Overrides
{bf:dwZDriveUNC} from the config.{p_end}

{phang}
{cmdab:con:fig(}{it:string}{cmd:)} -- path to a config file passed through to
{help dw_load_config} (default {bf:~/.config/user_config.yml}).{p_end}

{phang}
{cmd:persistent(}{it:yes|no}{cmd:)} -- whether the mapping survives reboots
(default {bf:yes}).{p_end}

{phang}
{cmd:force} -- remap {bf:letter} even when it is already mapped to a different
share.{p_end}

{phang}
{cmdab:dry:run} -- print the {bf:net use} command(s) without executing.{p_end}

{phang}
{cmdab:disc:over} -- report the UNC that {bf:letter} is currently mapped to
(useful for filling {bf:dwZDriveUNC} in your config), then exit.{p_end}

{marker examples}{...}
{title:Examples}

{phang}
Map Z: from the config if it is not already present:{p_end}
{phang2}{cmd:. dw_map_drive}{p_end}

{phang}
Preview the command without changing anything:{p_end}
{phang2}{cmd:. dw_map_drive , dryrun}{p_end}

{phang}
Read the UNC of an already-mapped Z: (to record in your config):{p_end}
{phang2}{cmd:. dw_map_drive , discover}{p_end}

{phang}
Map an explicit letter and share, no config needed:{p_end}
{phang2}{cmd:. dw_map_drive , letter(Y:) unc(\\host\share)}{p_end}

{marker returns}{...}
{title:Returns}

{pstd}
{cmd:r(status)} -- {bf:mapped} / {bf:already-mapped} / {bf:dryrun} / {bf:failed}{break}
{cmd:r(letter)} -- the drive letter acted on{break}
{cmd:r(unc)} -- the share (or, under {bf:discover}, the current remote){p_end}

{marker author}{...}
{title:Author}

{pstd}
João Pedro Azevedo (UNICEF Data & Analytics, Office of Strategy and Evidence).
Ported from datalib's {bf:mapzdrive}; consumes {bf:dwZDrive} / {bf:dwZDriveUNC}
via {help dw_load_config}.{p_end}
