# stata/src/ — Stata helpers (scaffolded)

Empty in v0.1.0-rc1. Stata-side helpers ship in v0.2 and will mirror the R API:

- `dw_save.do` / `dw_save.ado` — uniform `save` wrapper honouring the mode
  contract; emits `.provenance.json`.
- `dw_use.do` — uniform read wrapper with isid + schema check.
- `dw_compare.do` — wrapper around `cf` + a small grouping reducer to produce
  per-segment compare reports.
- `dw_require_no_api.do` — reviewer-mode hard-stop helper, invoked at the top
  of any `.do` that would otherwise hit a remote.
- `profile_DW-Production.do` excerpt — recommended snippet for sector profiles
  to read `dw_mode` from `~/.config/user_config.yml`.

Until v0.2 ships, HIV (`hva/`) and WASH (`ws/`) sectors retain their existing
`save` calls into canonical paths. Reviewers should not run those sectors
unless their `dw_mode = "producer"`. See
[`docs/roles_and_workflow.md`](../../docs/roles_and_workflow.md) for the
boundary.
