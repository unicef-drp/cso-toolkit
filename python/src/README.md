# python/src/ — Python helpers (scaffolded)

Empty in v0.1.0-rc1. Python-side helpers ship in v0.2 and will cover the
non-R / non-Stata pipelines (notably the geospatial / CCRI Python paths and
the SDMX MCP servers):

- `dw_io.py` — uniform read / write / compare / isid wrappers using
  `pandas` + `pyarrow`. `.provenance.json` sidecar emitter.
- `dw_api.py` — cached `httpx` / `requests` client honouring the mode
  contract; reviewer-mode `dw_require_no_api()` raises immediately.
- `cso_toolkit_sync.py` — version-drift detection mirroring the R sync.
- `profile_DW-Production.py` — sector-profile snippet that reads
  `~/.config/user_config.yml` and exports `DW_MODE`, `SANDBOX_ROOT`,
  `TEAMS_FOLDER`, `TEAMS_FOLDER_CANONICAL` to subprocesses.

Until v0.2 ships, climate / CCRI workflows that use Python should set
`DW_MODE=reviewer` in their environment and refuse network calls themselves.
