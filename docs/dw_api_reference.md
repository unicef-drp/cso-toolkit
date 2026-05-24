# `dw_api.R` — uniform mode-aware API wrapper reference

Detailed per-function reference for the API wrapper shipped in
[`r/R/dw_api.R`](../r/R/dw_api.R). Companion overview lives in the top-level
[README](../README.md); the producer / reviewer mode contract this wrapper
enforces is documented in
[`mode_contract_integration.md`](mode_contract_integration.md).

## `dw_api_fetch(api, cache_key, ...)`

The companion to `dw_io.R` for **external API calls**. Sector scripts should
stop calling `fromJSON()` / `readSDMX()` / `wbstats::wb_data()` / `httr::GET` /
`httr::POST` directly and use this wrapper instead.

**Behaviour:**

| Session | Cache state | Action |
|---|---|---|
| Producer | cache present, `refresh = FALSE` | reads cache |
| Producer | cache missing OR `refresh = TRUE` | hits live API, writes cache (via `dw_save`), returns |
| Reviewer | cache present (canonical) | reads cache |
| Reviewer | cache missing | **STOPS** with `dw_require_no_api()` message — Database Manager must run producer mode to populate |

**Cache layout** in the deposit:

```
<rawdata>/_apis/
    <api>/
        <cache_key>.<ext>
        <cache_key>.<ext>.provenance.json
```

The provenance sidecar records the API endpoint, parameters, fetch
timestamp, elapsed time, user, mode, and sha256.

## Supported APIs (`api =` values)

| `api` | Replaces | Args |
|---|---|---|
| `"uis"` | `fromJSON("https://api.uis.unesco.org/...")` | `endpoint`, `params` |
| `"sdmx"` | `rsdmx::readSDMX(providerId = ..., flowRef = ..., key = ...)` | `providerId`, `flowRef`, `key`, `version`, `start`, `end` |
| `"sdmx_codelist"` | `httr::GET("https://sdmx.data.unicef.org/.../codelist/...")` + JSON parse | `agency`, `codelist`, `version` |
| `"wb"` | `wbstats::wb_data(indicator = ...)` | `indicator`, `start_date`, `end_date` |
| `"ilo"` | `rsdmx::readSDMX(providerId = "ILO", ...)` | `flowRef`, `key`, `start`, `end` |
| `"unsd_sdg"` | `httr::POST("https://unstats.un.org/SDGAPI/v1/sdg/Series/DataCSV", ...)` | `series_codes`, `endpoint` |
| `"github_raw"` | `read_csv("https://raw.githubusercontent.com/...")` | `owner_repo`, `ref`, `path` |
| `"http"` | `httr::GET(url, ...)` returning text | `url`, `headers` |
| `"json_get"` | `jsonlite::fromJSON(url)` | `url` |

## Worked example: replace 14 hand-coded SDMX GETs with a loop

**Before** (excerpt from `nt/00_fetch_codebook.R` prior to 2026-05-23):

```r
# --- UNICEF CL_RESIDENCE ---
residence_url <- "https://sdmx.data.unicef.org/ws/public/sdmxapi/rest/codelist/UNICEF/CL_RESIDENCE/1.0?..."
residence_resp <- httr::GET(residence_url)
stop_for_status(residence_resp)
residence_json <- httr::content(residence_resp, as = "parsed", type = "application/json")
residence_codes <- residence_json$data$codelists[[1]]$codes
codebook_residence <- tibble(
  code = vapply(residence_codes, function(x) x$id, character(1)),
  ...
)
# (repeated 14 times for different codelists)
```

**After** (current file, ~50 lines instead of ~290):

```r
codelist_manifest <- tibble::tribble(
  ~sheet,                          ~agency,      ~codelist,                ~version,
  "UNICEF_CL_RESIDENCE",           "UNICEF",     "CL_RESIDENCE",           "1.0",
  # ... 13 more rows
)

codebook_sheets <- lapply(seq_len(nrow(codelist_manifest)), function(i) {
  row <- codelist_manifest[i, ]
  dw_api_fetch(
    api       = "sdmx_codelist",
    agency    = row$agency,
    codelist  = row$codelist,
    version   = row$version,
    cache_key = sprintf("sdmx_codelist_%s_%s_%s",
                        row$agency, row$codelist,
                        gsub("[^A-Za-z0-9]+", "_", row$version))
  )
})
names(codebook_sheets) <- codelist_manifest$sheet
```

## `dw_api_cached(api, cache_key)`

Read-only access to a previously-fetched cache. Never hits the network.
Stops if the cache is missing. Useful in analysis scripts that want to be
explicit about not refreshing.

## `dw_api_inventory(api = NULL)`

Lists every cached API fetch, optionally filtered to one `api`. Reads the
provenance sidecars and returns a data frame with `api`, `cache_key`, `ext`,
`size_bytes`, `mtime`, `fetched_at`. Useful for the Database Manager to
audit cache freshness:

```r
dw_api_inventory("wb")
#   api  cache_key                     ext  size_bytes  mtime               fetched_at
# 1 wb   wb_learning_poverty_primary   csv  142136      2026-05-23 16:42    2026-05-23T16:42:31+0000
```

## Migration checklist for a sector script

1. Identify the API call (`fromJSON` / `readSDMX` / `httr::GET` / etc.).
2. Pick the matching `api =` value from the table above.
3. Choose a stable, descriptive `cache_key` (snake_case, includes
   distinguishing parameters in the name — e.g., `wb_lp_primary_2000_2025`).
4. Replace the call with `dw_api_fetch(api = ..., cache_key = ..., ...)`.
5. Run once in producer mode to populate the cache.
6. Open a PR; smoke-test passes if reviewer mode can run from the cached
   result without any network access.
