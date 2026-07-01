#-------------------------------------------------------------------
# 00_functions/dw_api.R
# Purpose: Uniform mode-aware wrapper around external API fetches.
#          Companion to dw_io.R. Sector scripts call dw_api_fetch()
#          instead of fromJSON / readSDMX / wbstats::wb_data / httr::GET /
#          httr::POST directly. The wrapper:
#            - Producer session: hit the live API, cache to deposit
#              (via dw_save -> Z: mirror + provenance sidecar), return
#            - Reviewer session: read from deposit cache; if missing, stop
#              with the standard provenance-contract message
#              (via dw_require_no_api())
#            - Records every fetch in the cache's .provenance.json sidecar
#              (endpoint, params, fetched_at, user, mode, sha256)
#
# Cache layout in the deposit:
#   teamsRawData/_apis/<api>/<cache_key>.<ext>
#   teamsRawData/_apis/<api>/<cache_key>.<ext>.provenance.json
#
# Cache freshness: never expires automatically. Refresh is explicit
# (`refresh = TRUE`). The DBM owns refresh cadence per cache.
#
# Mode is a SESSION property (set in user_config.yml -> dw_mode, read by
# profile_DW-Production.R). dw_api_fetch has no `mode` argument.
#
# Public entry points:
#   dw_api_fetch(api, cache_key, ..., refresh = FALSE)
#   dw_api_cached(api, cache_key)         # always read cache; never fetch
#   dw_api_inventory(api = NULL)          # list cached fetches for an api
#
# Supported `api` values (from cross-sector audit 2026-05-23):
#   "uis"            UNESCO UIS indicators / generic JSON endpoints
#   "sdmx"           SDMX data fetch via rsdmx (any provider + flowRef)
#   "sdmx_codelist"  SDMX codelist GET + JSON parse to (code, name, description)
#   "wb"             World Bank wbstats::wb_data
#   "ilo"            ILO SDMX via rsdmx (provider = "ILO")
#   "unsd_sdg"       UNSD SDG API: httr::POST with form-encoded seriesCodes
#   "github_raw"     Pinned-commit raw.githubusercontent.com fetch
#   "http"           Generic HTTP GET returning text
#   "json_get"       Generic JSON GET -> parsed object
#-------------------------------------------------------------------

# ============================================================================
# Cache path resolution
# ============================================================================

#' Sandbox cache path for an API fetch
#'
#' Internal. Builds the cache path under `teamsRawData/_apis/<api>/`.
#'
#' @param api Character. API identifier (see file header for supported
#'   values).
#' @param cache_key Character. Short snake_case identifier; becomes the
#'   cache filename basename.
#' @param ext Character. File extension. Default `"csv"`.
#'
#' @return Character path under the sandbox raw-data root.
#'
#' @keywords internal
#' @noRd
.dw_api_cache_path <- function(api, cache_key, ext = "csv") {
	root <- .try_get("teamsRawData")
	if (is.na(root)) {
		stop("[cso_toolkit.dw_api] teamsRawData global is not set.\n  This usually means profile_<repo>.R has not been sourced yet.\n  Fix: source('profile_<repo>.R') first, or set teamsRawData <- '/path/to/raw' explicitly.",
		     call. = FALSE)
	}
	file.path(root, "_apis", api, paste0(cache_key, ".", ext))
}

#' Per-API default cache extension
#'
#' Internal. Some APIs return data shapes that don't serialise cleanly to
#' CSV (e.g. `wbstats::wb_indicators` has list-columns), so they default to
#' RDS. Callers can still override via the `ext =` argument to
#' [dw_api_fetch()].
#'
#' @param api Character. API identifier.
#'
#' @return Character. Default extension (`"csv"`, `"rds"`, ...).
#'
#' @keywords internal
#' @noRd
.dw_api_default_ext <- function(api) {
	switch(api,
		"wb_indicators" = "rds",
		"json_get"      = "rds",   # returns nested lists
		"http"          = "rds",   # plain text; CSV would mis-shape
		"github_raw"    = "rds",   # arbitrary text / binary by ref
		# everything else flat-tabular -> csv
		"csv"
	)
}

#' Canonical cache path for an API fetch
#'
#' Internal. Mirrors [.dw_api_cache_path()] but resolves against
#' `teamsRawDataCanonical` (the read-side fallback for reviewers).
#'
#' @param api Character. API identifier.
#' @param cache_key Character. Cache filename basename.
#' @param ext Character. File extension. Default `"csv"`.
#'
#' @return Character path under the canonical raw-data root.
#'
#' @keywords internal
#' @noRd
.dw_api_canonical_cache_path <- function(api, cache_key, ext = "csv") {
	root <- .try_get("teamsRawDataCanonical")
	if (is.na(root)) {
		stop("[cso_toolkit.dw_api] teamsRawDataCanonical global is not set.\n  Reviewer-mode reads fall back to this canonical root when the sandbox cache is missing.\n  Fix: set teamsRawDataCanonical to the read-only Teams root that holds the deposit's _apis/ folder.",
		     call. = FALSE)
	}
	file.path(root, "_apis", api, paste0(cache_key, ".", ext))
}

# ============================================================================
# dw_api_fetch — main entry point
# ============================================================================

#' Fetch from an external API, mode-aware, with deposit cache
#'
#' Behaviour by session mode:
#' \itemize{
#'   \item **Producer**, cache present, `refresh = FALSE` — reads the cache.
#'   \item **Producer**, `refresh = TRUE` OR cache missing — hits the live
#'         API, writes the cache via [dw_save()] (which mirrors to Z: when
#'         mapped and emits a `.provenance.json` sidecar), and returns the
#'         result.
#'   \item **Reviewer** — reads the cache from the canonical deposit; if
#'         missing, stops via `dw_require_no_api()`.
#' }
#'
#' Cache layout: `teamsRawData/_apis/<api>/<cache_key>.<ext>` with a
#' sibling `.provenance.json` recording endpoint, params, `fetched_at`,
#' user, mode, and sha256.
#'
#' @param api Character. API identifier. One of `"uis"`, `"sdmx"`,
#'   `"sdmx_codelist"`, `"wb"`, `"wb_indicators"`, `"ilo"`, `"unsd_sdg"`,
#'   `"github_raw"`, `"http"`, `"json_get"`. See file header for details.
#' @param cache_key Character. Short snake_case identifier used as the
#'   cache filename basename.
#' @param refresh Logical. If `TRUE`, hit the API even when a cache exists
#'   (producer only). Default `FALSE`.
#' @param ext Character. Cache file extension. Default `NULL` (= per-API
#'   default via `.dw_api_default_ext`).
#' @param metadata Named list merged into the cache's
#'   `.provenance.json` sidecar.
#' @param ... API-specific arguments — see the per-API helpers
#'   (`.api_fetch_uis`, `.api_fetch_sdmx`, etc.).
#'
#' @return The fetched (or cached) object, typed per the API's shape
#'   (tibble / data frame / list).
#'
#' @examples
#' \dontrun{
#' entrance_age_primary <- dw_api_fetch(
#'   api      = "uis",
#'   endpoint = "indicators",
#'   params   = list(indicator = "299905"),
#'   cache_key = "uis_entrance_age_primary"
#' )
#' }
#' @seealso [dw_api_cached()] for cache-only reads; [dw_api_inventory()]
#'   to list existing caches; [dw_save()] (used to write the cache);
#'   [dw_use()] (used to read it back).
#' @family api
#' @param verbose Logical or `NULL`. Show high-level progress and result
#'   messages. `NULL` (default) inherits `getOption("dw.verbose", TRUE)`;
#'   set `TRUE`/`FALSE` to override for this call. See [dw_verbosity()].
#' @param debug Logical or `NULL`. Show internal troubleshooting detail
#'   (resolved paths, dims, branch decisions). `NULL` (default) inherits
#'   `getOption("dw.debug", FALSE)`; implies `verbose`. See [dw_verbosity()].
#' @export
dw_api_fetch <- function(api,
                         cache_key,
                         refresh = FALSE,
                         ext = NULL,
                         metadata = NULL,
                         verbose = NULL,
                         debug = NULL,
                         ...) {

	# Resolve per-api default extension if caller didn't override.
	if (is.null(ext)) ext <- .dw_api_default_ext(api)

	cache_path           <- .dw_api_cache_path(api, cache_key, ext)
	canonical_cache_path <- .dw_api_canonical_cache_path(api, cache_key, ext)
	args <- list(...)
	vd <- .dw_vd(verbose, debug); v <- vd$v; d <- vd$d
	.dw_dbg("dw_api_fetch", "api=", api, " cache_key=", cache_key, " refresh=", refresh, " ext=", ext, d = d)

	# Try cache first (sandbox or canonical fallback) unless explicit refresh.
	if (!isTRUE(refresh)) {
		hit_path <- if (file.exists(cache_path)) cache_path
		            else if (file.exists(canonical_cache_path)) canonical_cache_path
		            else NA_character_
		if (!is.na(hit_path)) {
			.dw_msg("dw_api_fetch", api, "/", cache_key, " cache hit: ", hit_path, v = v)
			return(dw_use(hit_path, verbose = FALSE, debug = d))
		}
	}

	# No cache hit (or refresh). Producer mode required to fetch.
	if (!isTRUE(.try_get("dw_apis_allowed"))) {
		dw_require_no_api(
			api_name = sprintf("dw_api_fetch('%s', cache_key='%s')", api, cache_key),
			reason = sprintf("cache missing at %s", canonical_cache_path)
		)
		return(invisible(NULL))  # defensive; dw_require_no_api already stop()'d
	}

	# Producer mode: dispatch on api
	.dw_msg("dw_api_fetch", api, "/", cache_key, " fetching live...", v = v)
	t0 <- Sys.time()
	result <- switch(api,
		"uis"            = do.call(.api_fetch_uis,            args),
		"sdmx"           = do.call(.api_fetch_sdmx,           args),
		"sdmx_codelist"  = do.call(.api_fetch_sdmx_codelist,  args),
		"wb"             = do.call(.api_fetch_wb,             args),
		"wb_indicators"  = do.call(.api_fetch_wb_indicators,  args),
		"ilo"            = do.call(.api_fetch_ilo,            args),
		"unsd_sdg"       = do.call(.api_fetch_unsd_sdg,       args),
		"github_raw"     = do.call(.api_fetch_github_raw,     args),
		"http"           = do.call(.api_fetch_http,           args),
		"json_get"       = do.call(.api_fetch_json_get,       args),
		"csv"            = do.call(.api_fetch_csv,            args),
		stop(sprintf(
			"[cso_toolkit.dw_api_fetch] Unsupported api '%s'.\n  Supported: uis, sdmx, sdmx_codelist, wb, wb_indicators, ilo, unsd_sdg, github_raw, http, json_get, csv\n  Fix: pass one of the supported strings as `api =`, or add a new branch to the switch() in dw_api.R.",
			api
		), call. = FALSE)
	)
	elapsed <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
	.dw_dbg("dw_api_fetch", "fetched in ", round(elapsed, 2), "s; rows=", if (is.data.frame(result)) nrow(result) else NA, d = d)

	# Cache to deposit (writes via dw_save -> mode-aware path + Z: mirror +
	# provenance sidecar).
	api_metadata <- c(
		list(
			api           = api,
			cache_key     = cache_key,
			fetched_at    = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z", tz = "UTC"),
			elapsed_secs  = elapsed,
			refresh_flag  = isTRUE(refresh),
			fetch_args    = args
		),
		metadata
	)
	dw_save(result, path = cache_path, metadata = api_metadata, verbose = v, debug = d)

	.dw_msg("dw_api_fetch", "done: ", api, "/", cache_key, " (", if (is.data.frame(result)) paste0(nrow(result), " rows") else class(result)[1], ")", v = v)
	result
}

# ============================================================================
# dw_api_cached — explicit cache-only read
# ============================================================================

#' Read an API cache without fetching
#'
#' Cache-only counterpart to [dw_api_fetch()]. Always reads from the
#' canonical cache root and stops if no cache exists — useful in analysis
#' scripts that must remain reproducible without network access.
#'
#' @param api Character. API identifier.
#' @param cache_key Character. Cache filename basename.
#' @param ext Character. File extension. Default `"csv"`.
#'
#' @return The cached object.
#'
#' @seealso [dw_api_fetch()] (populates the cache); [dw_api_inventory()]
#'   (lists all caches).
#' @family api
#' @param verbose Logical or `NULL`. Show high-level progress and result
#'   messages. `NULL` (default) inherits `getOption("dw.verbose", TRUE)`;
#'   set `TRUE`/`FALSE` to override for this call. See [dw_verbosity()].
#' @param debug Logical or `NULL`. Show internal troubleshooting detail
#'   (resolved paths, dims, branch decisions). `NULL` (default) inherits
#'   `getOption("dw.debug", FALSE)`; implies `verbose`. See [dw_verbosity()].
#' @export
dw_api_cached <- function(api, cache_key, ext = "csv", verbose = NULL, debug = NULL) {
	cache_path <- .dw_api_canonical_cache_path(api, cache_key, ext)
	vd <- .dw_vd(verbose, debug); v <- vd$v; d <- vd$d
	.dw_msg("dw_api_cached", "reading cache ", api, "/", cache_key, v = v)
	.dw_dbg("dw_api_cached", "cache_path=", cache_path, d = d)
	if (!file.exists(cache_path)) {
		stop(sprintf(
			"[cso_toolkit.dw_api_cached] No cache at %s\n  Reason: the cached fetch has not been produced yet (or the wrong api / cache_key / ext was passed).\n  Fix:\n    1. Ask the Database Manager to run dw_api_fetch('%s', cache_key = '%s', ...) in producer mode, OR\n    2. Verify api/cache_key/ext spelling: an `ext` mismatch is a common cause.",
			cache_path, api, cache_key
		), call. = FALSE)
	}
	out <- dw_use(cache_path, verbose = FALSE, debug = d)
	.dw_msg("dw_api_cached", "loaded ", if (is.data.frame(out)) paste0(nrow(out), " rows") else class(out)[1], v = v)
	out
}

# ============================================================================
# dw_api_inventory — list cached fetches
# ============================================================================

#' List all cached API fetches under the canonical root
#'
#' Walks `teamsRawDataCanonical/_apis/<api>/` and returns a row per cache
#' file (excluding `.provenance.json` sidecars). When a sidecar is present,
#' its `metadata$fetched_at` is pulled into the result for auditability.
#'
#' @param api Character. Optional API filter; default `NULL` lists all.
#'
#' @return A data frame with columns `api`, `cache_key`, `ext`, `size_bytes`,
#'   `mtime`, `fetched_at`. Empty data frame when no caches exist.
#'
#' @seealso [dw_api_fetch()] (populates caches); [dw_api_cached()] (reads
#'   a single cache).
#' @family api
#' @param verbose Logical or `NULL`. Show high-level progress and result
#'   messages. `NULL` (default) inherits `getOption("dw.verbose", TRUE)`;
#'   set `TRUE`/`FALSE` to override for this call. See [dw_verbosity()].
#' @param debug Logical or `NULL`. Show internal troubleshooting detail
#'   (resolved paths, dims, branch decisions). `NULL` (default) inherits
#'   `getOption("dw.debug", FALSE)`; implies `verbose`. See [dw_verbosity()].
#' @export
dw_api_inventory <- function(api = NULL, verbose = NULL, debug = NULL) {
	root <- file.path(.try_get("teamsRawDataCanonical"), "_apis")
	vd <- .dw_vd(verbose, debug); v <- vd$v; d <- vd$d
	.dw_msg("dw_api_inventory", "scanning ", if (is.null(api)) "all APIs" else api, v = v)
	.dw_dbg("dw_api_inventory", "root=", root, d = d)
	if (!dir.exists(root)) return(data.frame())
	apis <- if (is.null(api)) list.dirs(root, recursive = FALSE, full.names = FALSE)
	        else api
	rows <- list()
	for (a in apis) {
		dir <- file.path(root, a)
		if (!dir.exists(dir)) next
		# Exclude .provenance.json sidecars from inventory
		files <- list.files(dir, full.names = TRUE)
		files <- files[!grepl("\\.provenance\\.json$", files)]
		for (f in files) {
			ext <- tools::file_ext(f)
			fi  <- file.info(f)
			prov_path <- paste0(f, ".provenance.json")
			fetched_at <- NA_character_
			if (file.exists(prov_path) && requireNamespace("jsonlite", quietly = TRUE)) {
				prov <- tryCatch(jsonlite::read_json(prov_path), error = function(e) NULL)
				fetched_at <- prov$metadata$fetched_at %||% prov$written_at %||% NA_character_
			}
			rows[[length(rows) + 1]] <- data.frame(
				api = a,
				cache_key = tools::file_path_sans_ext(basename(f)),
				ext = ext,
				size_bytes = fi$size,
				mtime = format(fi$mtime),
				fetched_at = fetched_at,
				stringsAsFactors = FALSE
			)
		}
	}
	if (length(rows) == 0) return(data.frame())
	out <- do.call(rbind, rows)
	.dw_msg("dw_api_inventory", "found ", nrow(out), " cache file(s)", v = v)
	out
}

# ============================================================================
# Per-API fetchers (internal)
# ============================================================================

#' UNESCO UIS API fetcher
#'
#' Internal. Builds the URL as `<base>/<endpoint>?key1=val1&...` and parses
#' the JSON response; unwraps `$records` when present.
#'
#' @param endpoint Character. UIS endpoint (e.g. `"indicators"`).
#' @param params Named list. Query parameters.
#' @param ... Reserved for forward compatibility.
#'
#' @return Data frame (`$records`) or parsed JSON list.
#'
#' @keywords internal
#' @noRd
.api_fetch_uis <- function(endpoint = "indicators", params = list(), ...) {
	.require("jsonlite")
	base <- "https://api.uis.unesco.org/api/public/data/"
	url <- paste0(base, endpoint)
	if (length(params) > 0) {
		# URL-encode both keys and values so a param value containing
		# `&` / `=` / space / non-ASCII doesn't corrupt the query.
		# Backported from DW-Production; see B4 in
		# docs/dw-production-alignment-2026-05-25.md.
		qs <- paste(
			utils::URLencode(names(params), reserved = TRUE),
			vapply(unlist(params), utils::URLencode, character(1), reserved = TRUE),
			sep = "=", collapse = "&"
		)
		url <- paste0(url, "?", qs)
	}
	raw <- jsonlite::fromJSON(url)
	if (!is.null(raw$records)) raw$records else raw
}

#' SDMX data fetcher (rsdmx)
#'
#' Internal. Generic SDMX data fetch via `rsdmx::readSDMX`. Returns a flat
#' data frame.
#'
#' @param providerId Character. SDMX provider id (e.g. `"UNICEF"`,
#'   `"OECD"`).
#' @param flowRef Character. Dataflow reference.
#' @param key Character. SDMX key (slash-separated dimension values).
#' @param version Character. SDMX version. Default `"1.0"`.
#' @param start,end Character. Optional time bounds.
#' @param ... Passed to `rsdmx::readSDMX`.
#'
#' @return Data frame.
#'
#' @keywords internal
#' @noRd
.api_fetch_sdmx <- function(providerId, flowRef, key,
                            version = "1.0", start = NULL, end = NULL, ...) {
	.require("rsdmx")
	as.data.frame(rsdmx::readSDMX(providerId = providerId, resource = "data",
	                              flowRef = flowRef, version = version,
	                              key = key, start = start, end = end,
	                              verbose = FALSE, ...))
}

#' SDMX codelist fetcher (httr GET + JSON parse)
#'
#' Internal. Fetches an SDMX codelist and reshapes it to a
#' `(code, name, description)` tibble. Replaces the 14 hand-coded GETs in
#' `nt/00_fetch_codebook.R`.
#'
#' @param agency Character. SDMX agency (e.g. `"UNICEF"`).
#' @param codelist Character. Codelist id (e.g. `"CL_RESIDENCE"`).
#' @param version Character. Codelist version. Default `"1.0"`.
#' @param ... Passed to `httr::GET`.
#'
#' @return Tibble with `code`, `name`, `description`.
#'
#' @keywords internal
#' @noRd
.api_fetch_sdmx_codelist <- function(agency, codelist, version = "1.0", ...) {
	.require("httr")
	.require("tibble")
	url <- sprintf(
		"https://sdmx.data.unicef.org/ws/public/sdmxapi/rest/codelist/%s/%s/%s?format=sdmx-json&detail=full&references=none",
		agency, codelist, version
	)
	resp <- httr::GET(url, ...)
	httr::stop_for_status(resp)
	body <- httr::content(resp, as = "parsed", type = "application/json")
	codes <- body$data$codelists[[1]]$codes
	tibble::tibble(
		code = vapply(codes, function(x) x$id, character(1)),
		name = vapply(codes, function(x) x$names$en, character(1)),
		description = vapply(codes, function(x) {
			d <- x$description
			if (is.null(d))                              NA_character_
			else if (is.list(d) && !is.null(d$en))       d$en
			else if (is.character(d))                    d[1]
			else                                          NA_character_
		}, character(1))
	)
}

#' World Bank data fetcher (wbstats::wb_data)
#'
#' Internal.
#'
#' @param indicator Character. WDI indicator code(s).
#' @param start_date Numeric. Start year. Default `2000`.
#' @param end_date Numeric. End year. Default current year.
#' @param ... Passed to `wbstats::wb_data`.
#'
#' @return Tibble of WB indicator data.
#'
#' @keywords internal
#' @noRd
.api_fetch_wb <- function(indicator, start_date = 2000,
                          end_date = as.numeric(format(Sys.Date(), "%Y")), ...) {
	.require("wbstats")
	wbstats::wb_data(indicator = indicator,
	                 start_date = start_date, end_date = end_date, ...)
}

#' World Bank indicator catalogue fetcher (wbstats::wb_indicators)
#'
#' Internal.
#'
#' @param ... Passed to `wbstats::wb_indicators`.
#'
#' @return Tibble of indicator metadata.
#'
#' @keywords internal
#' @noRd
.api_fetch_wb_indicators <- function(...) {
	.require("wbstats")
	wbstats::wb_indicators(...)
}

#' ILO SDMX fetcher
#'
#' Internal. Thin wrapper around `rsdmx::readSDMX(providerId = "ILO")`.
#'
#' @param flowRef Character. ILO dataflow reference.
#' @param key Character. SDMX key.
#' @param start,end Character. Optional time bounds.
#' @param ... Passed to `rsdmx::readSDMX`.
#'
#' @return Data frame.
#'
#' @keywords internal
#' @noRd
.api_fetch_ilo <- function(flowRef, key, start = NULL, end = NULL, ...) {
	.require("rsdmx")
	as.data.frame(rsdmx::readSDMX(providerId = "ILO", resource = "data",
	                              flowRef = flowRef, version = "1.0",
	                              key = key, start = start, end = end,
	                              verbose = FALSE, ...))
}

#' UNSD SDG API fetcher (httr POST with form-encoded seriesCodes)
#'
#' Internal. Posts an `application/x-www-form-urlencoded` body of
#' `seriesCodes=...` to the UNSD SDG API and parses the CSV response.
#'
#' @param series_codes Character vector. SDG series codes
#'   (e.g. `c("SL_DOM_TSPD", "SG_LGL_GENEQEMP")`).
#' @param endpoint Character. API endpoint. Default
#'   `"https://unstats.un.org/SDGAPI/v1/sdg/Series/DataCSV"`.
#' @param ... Passed to `httr::POST`.
#'
#' @return Tibble parsed from the CSV response.
#'
#' @keywords internal
#' @noRd
.api_fetch_unsd_sdg <- function(series_codes,
                                endpoint = "https://unstats.un.org/SDGAPI/v1/sdg/Series/DataCSV",
                                ...) {
	.require("httr")
	.require("readr")
	body_str <- paste0("seriesCodes=", series_codes, collapse = "&")
	resp <- httr::POST(
		url = endpoint,
		body = body_str,
		httr::add_headers(`Content-Type`   = "application/x-www-form-urlencoded",
		                  `Accept`         = "application/octet-stream"),
		...
	)
	httr::stop_for_status(resp)
	txt <- httr::content(resp, as = "text", encoding = "UTF-8")
	readr::read_csv(I(txt), show_col_types = FALSE)
}

#' Pinned-commit GitHub raw fetcher
#'
#' Internal. Fetches `https://raw.githubusercontent.com/<owner>/<repo>/<ref>/<path>`
#' and parses based on the file extension (`.csv` -> `read_csv`, `.tsv` ->
#' `read_tsv`, `.json` -> `fromJSON`, otherwise `read_lines`).
#'
#' @param owner_repo Character. `"owner/repo"` slug.
#' @param ref Character. Branch name, tag, or commit sha. Default `"main"`.
#' @param path Character. File path within the repo.
#' @param ... Passed to the underlying reader.
#'
#' @return Tibble / list / character vector depending on file extension.
#'
#' @keywords internal
#' @noRd
.api_fetch_github_raw <- function(owner_repo, ref = "main", path, ...) {
	.require("readr")
	url <- sprintf("https://raw.githubusercontent.com/%s/%s/%s",
	               owner_repo, ref, path)
	ext <- tolower(tools::file_ext(path))
	switch(ext,
		csv  = readr::read_csv(url, show_col_types = FALSE, ...),
		tsv  = readr::read_tsv(url, show_col_types = FALSE, ...),
		json = { .require("jsonlite"); jsonlite::fromJSON(url, ...) },
		# default: download as text
		readr::read_lines(url, ...)
	)
}

#' Generic HTTP GET returning text
#'
#' Internal.
#'
#' @param url Character. URL to GET.
#' @param headers Named list. HTTP headers.
#' @param ... Passed to `httr::GET`.
#'
#' @return Character. Response body decoded as UTF-8 text.
#'
#' @keywords internal
#' @noRd
.api_fetch_http <- function(url, headers = list(), ...) {
	.require("httr")
	resp <- httr::GET(url, do.call(httr::add_headers, headers), ...)
	httr::stop_for_status(resp)
	httr::content(resp, as = "text", encoding = "UTF-8")
}

#' Generic JSON GET returning a parsed object
#'
#' Internal.
#'
#' @param url Character. URL to GET.
#' @param ... Passed to `jsonlite::fromJSON`.
#'
#' @return Parsed JSON (list, data frame, ...).
#'
#' @keywords internal
#' @noRd
.api_fetch_json_get <- function(url, ...) {
	.require("jsonlite")
	jsonlite::fromJSON(url, ...)
}

#' Generic CSV-at-a-URL GET returning a parsed data frame
#'
#' Internal. For flat CSV endpoints that `github_raw` (GitHub-only) and
#' `http` (raw text, no round-trip) do not cover -- SDMX REST-CSV, World
#' Bank Data360 file URLs, ILOSTAT rplumber `format=.csv`. Caches as a
#' parsed frame (`.dw_api_default_ext("csv") == "csv"`).
#'
#' @param url Character. URL returning CSV.
#' @param ... Passed to `readr::read_csv`.
#'
#' @return data.frame.
#'
#' @keywords internal
#' @noRd
.api_fetch_csv <- function(url, ...) {
	.require("readr")
	as.data.frame(readr::read_csv(url, show_col_types = FALSE, ...))
}

# ============================================================================
# Example usage (in a sector script)
# ============================================================================
#
# # source() is unnecessary; profile auto-loads dw_io.R + dw_api.R.
#
# # UIS entrance ages (replaces fromJSON("...uis...indicator=299905"))
# entrance_age_primary <- dw_api_fetch(
#   api      = "uis",
#   endpoint = "indicators",
#   params   = list(indicator = "299905"),
#   cache_key = "uis_entrance_age_primary"
# )
#
# # SDMX codelist (replaces the 14 hand-coded GETs in nt/00_fetch_codebook.R)
# codebook_residence <- dw_api_fetch(
#   api       = "sdmx_codelist",
#   agency    = "UNICEF",
#   codelist  = "CL_RESIDENCE",
#   version   = "1.0",
#   cache_key = "sdmx_codelist_UNICEF_CL_RESIDENCE_1_0"
# )
#
# # World Bank Learning Poverty (replaces wb_data)
# lp_data <- dw_api_fetch(
#   api        = "wb",
#   indicator  = c("SE.LPV.PRIM","SE.LPV.PRIM.FE","SE.LPV.PRIM.MA"),
#   start_date = 2000,
#   end_date   = 2025,
#   cache_key  = "wb_learning_poverty_primary"
# )
#
# # UNSD SDG API
# sdg_series <- dw_api_fetch(
#   api          = "unsd_sdg",
#   series_codes = c("SG_XPD_PR", "SG_XPD_PR_EDUC"),
#   cache_key    = "unsd_sdg_xpd_pr"
# )
#
# # Pinned-commit GitHub regional metadata
# regions <- dw_api_fetch(
#   api        = "github_raw",
#   owner_repo = "unicef-drp/Country-and-Region-Metadata",
#   ref        = "main",
#   path       = "UNICEF_REP_REG_GLOBAL.csv",
#   cache_key  = "github_unicef_regions_global"
# )
#
# # Inventory all cached fetches:
# dw_api_inventory()
# # api  cache_key                                       ext  size   mtime               fetched_at
# # wb   wb_learning_poverty_primary                     csv  142136 2026-05-23 16:42    2026-05-23T16:42:31+0000
# # sdmx_codelist  sdmx_codelist_UNICEF_CL_RESIDENCE_1_0 csv  528    2026-05-23 16:43    2026-05-23T16:43:02+0000
# # ...
#
# # Producer-side refresh (DBM workflow):
# lp_data <- dw_api_fetch(api = "wb", indicator = c(...), refresh = TRUE,
#                        cache_key = "wb_learning_poverty_primary")
