<!-- vendored from unicef-drp/unicefData @ v2.4.2 — do not hand-edit; refresh via _manifest.yml.
     Generated from the package NAMESPACE and tests/fixtures/expected/expected_columns.csv. -->

*Surface as of unicefData **v2.4.2** — R 2.4.1 (CRAN) · Python 2.4.2 (PyPI) · Stata 2.4.1 (SSC); bundled-metadata vintage 2026-04-20. Counts and columns drift with releases; this table is pinned, and the package's own documentation is canonical.*

**Core public surface — the same functions in all three languages.**

| Purpose | R / Python | Stata |
|---|---|---|
| Fetch an indicator series (dataflow auto-detected) | `unicefData(indicator=, countries=, year=)` | `unicefdata, indicator() countries() year() clear` |
| Search the indicator catalogue | `search_indicators("mortality")` | `unicefdata, search(mortality)` |
| List categories / dataflows | `list_categories()` | `unicefdata, flows` |
| Indicators by category / SDG | `get_indicators_by_category()` · `get_indicators_by_sdg()` | *(via `search`)* |
| Clear the metadata cache | `clear_unicef_cache()` (R) · `clear_cache()` (Python) | `unicefdata, clearcache` |

**Normalized output schema** — every fetch returns the same tidy columns regardless of language (SDMX column → output column):

| SDMX column | Output column | Type | Required |
|---|---|---|---|
| `DATAFLOW` | `dataflow` | string | yes |
| `REF_AREA` | `iso3` | string | yes |
| `INDICATOR` | `indicator` | string | yes |
| `SEX` | `sex` | string | no |
| `AGE` | `age` | string | no |
| `TIME_PERIOD` | `period` | numeric | yes |
| `OBS_VALUE` | `value` | numeric | yes |
| `UNIT_MEASURE` | `unit` | string | no |
| `OBS_STATUS` | `obs_status` | string | no |
| `DATA_SOURCE` | `data_source` | string | no |
