# cso-toolkit sector dashboard

A static single-page dashboard summarising sector pipeline state for the DW-Production / cso-toolkit ecosystem. Hosted at `docs/dashboard/` so GitHub Pages serves it directly.

## What it shows

Eight tabs:

1. **Landing** — KPIs, pipeline-phase distribution, activity feed, watch list of stalled sectors.
2. **Sectors** — per-sector cards (status, rows, indicators, wall-time, fixes, toolkit findings, blockers) plus five summary charts.
3. **Pipeline phases** — kanban board: Production / Review / Live. (A "Publishing" phase is not yet emitted because `state.json` carries no field that can drive it; it will be added once such a signal exists.)
4. **Branches** — cso-toolkit branches table: name, link, SHA, protected flag.
5. **Issues** — cso-toolkit issues grouped by milestone (v0.4.6 / v0.5.0 / unlabelled), severity badge.
6. **DBM actions** — TODO / IN-PROGRESS / DONE kanban sourced from `data/actions/<id>.yml`.
7. **History** — line charts of state over time (placeholder on day 1; grows nightly).
8. **cso-toolkit** — toolkit version per branch, open v0.4.6 issues, cycle burndown.

## How to view

- **GitHub Pages**: once `docs/dashboard/index.html` lands on `main`, point a browser at the published Pages URL.
- **Local**: open `docs/dashboard/index.html` directly in a browser (`file://` works — the page is self-contained, no fetch / no server).

## How to update

The dashboard regenerates from `data/state.json`. Two scripts:

### `collect.R`

Assembles state from four sources:

- **UNICEF SDMX** — lightweight HTTP reachability probe (`url()` open + `setTimeLimit`); the `rsdmx` package is checked only as a gate (full SDMX parsing is not performed). Caches the probe result to `data/sdmx_cache_latest.json`; falls back to the cache on network failure.
- **cso-toolkit GitHub** — `gh api` using `GITHUB_TOKEN`. Pulls PRs, branches, issues, milestones.
- **DW-Production GitHub** — `gh api` using `DW_PROD_READ_TOKEN` (a PAT). Same fields. The PR target repo is private; this token is the read-only handle.
- **Operator snapshots** — reads `data/snapshots/teams_snapshot_latest.json` plus `data/snapshots/replication_<sector>_latest.json` files.

Writes `data/state.json` (master) and a dated copy under `data/history/YYYY-MM-DD/state.json`.

Each source has its own `tryCatch`; a missing source warns and is recorded as empty in `state.json`.

### `render.R`

Reads `data/state.json`, inlines five chart SVGs from `charts/` plus the data-flow diagram, and writes a self-contained `index.html` (vanilla JS tab switching, inline CSS + SVG).

### Operator snapshot script

Operator runs a separate script (not in this folder; lives outside the repo) that overwrites `data/snapshots/teams_snapshot_latest.json` and `data/snapshots/replication_<sector>_latest.json` with the latest measured state.

### CI

A GitHub Action on push-to-develop should run:

```sh
Rscript docs/dashboard/collect.R
Rscript docs/dashboard/render.R
git add docs/dashboard/data docs/dashboard/index.html
git diff --cached --quiet || git commit -m "chore(dashboard): refresh state"
```

## Schemas

### `data/state.json`

Top-level:

| key | type | purpose |
| --- | --- | --- |
| `schema_version` | string | `"1.0.0"` |
| `generated_at` | ISO-8601 | UTC timestamp of this collect run |
| `generated_on` | YYYY-MM-DD | local date |
| `sectors` | array | sector codes in canonical order |
| `sdmx` | object | live-or-cache SDMX probe result |
| `cso_toolkit` | object | `{repo, fetched_at, prs, branches, issues, milestones}` |
| `dw_production` | object | same shape as `cso_toolkit`; `reachable: false` when token missing |
| `teams_snapshot` | object | operator-committed Teams deposit state |
| `replication` | object | per-sector replication result (one key per sector) |
| `actions` | array | parsed DBM action YAMLs |

### `data/actions/<id>.yml`

```yaml
id: <slug>
title: <human-readable title>
sector: <sector code or null>
severity: HIGH | MEDIUM | LOW | INFO
status: TODO | IN-PROGRESS | DONE
owner: <github handle or team name>
created_at: YYYY-MM-DD
due_at: YYYY-MM-DD | null
blocker_for_dbm: <one-line summary or null>
description: |
  Free-form multi-line description.
references:
  - <link or file:line citation>
```

## Charts directory

`charts/` is empty initially. Five SVGs are expected (`3way_parity.svg`, `coverage_matrix.svg`, `walltime.svg`, `pr_funnel.svg`, `toolkit_drift.svg`) plus the diagram `data_flow_diagram.svg`. Each is inlined into `index.html` via `paste(readLines(file), collapse = "\n")`. Missing charts render as an italic "chart not yet generated" placeholder.
