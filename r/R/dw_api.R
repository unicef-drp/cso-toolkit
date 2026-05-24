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

.dw_api_cache_path <- function(api, cache_key, ext = "csv") {
	root <- .try_get("teamsRawData")
	if (is.na(root)) stop("dw_api: teamsRawData global not defined (profile not loaded?)")
	file.path(root, "_apis", api, paste0(cache_key, ".", ext))
}

#' Per-api default cache extension. Some APIs return data shapes that don't
#' serialize cleanly to CSV (wbstats::wb_indicators has list columns); they
#' default to RDS. Callers can still override by passing `ext =` explicitly.
.dw_api_default_ext <- function(api) {
	switch(api,
		"wb_indicators" = "rds",
		"json_get"      = "rds",   # returns nested lists
		# everything else flat-tabular -> csv
		"csv"
	)
}

.dw_api_canonical_cache_path <- function(api, cache_key, ext = "csv") {
	root <- .try_get("teamsRawDataCanonical")
	if (is.na(root)) stop("dw_api: teamsRawDataCanonical not defined (profile not loaded?)")
	file.path(root, "_apis", api, paste0(cache_key, ".", ext))
}

# ============================================================================
# dw_api_fetch — main entry point
# ============================================================================

#' Fetch from an external API, mode-aware, with deposit cache.
#'
#' Producer session, cache present, refresh = FALSE -> reads cache.
#' Producer session, refresh = TRUE OR cache missing -> hits live API,
#'   writes cache via dw_save (mirrors to Z: when mapped), returns result.
#' Reviewer session                                  -> reads cache from
#'   canonical deposit; if missing, stops via dw_require_no_api().
#'
#' Arguments:
#'   api         API id; see header for supported values.
#'   cache_key   short identifier; becomes the cache filename. snake_case.
#'   refresh     if TRUE, hit the API even if cache exists (producer only).
#'   ext         cache file extension (default "csv"; "rds" for nested,
#'                "json" for raw, "parquet" for big tables).
#'   metadata    optional named list merged into the provenance sidecar.
#'   ...         API-specific arguments (see per-api helpers below).
dw_api_fetch <- function(api,
                         cache_key,
                         refresh = FALSE,
                         ext = NULL,
                         metadata = NULL,
                         ...) {

	# Resolve per-api default extension if caller didn't override.
	if (is.null(ext)) ext <- .dw_api_default_ext(api)

	cache_path           <- .dw_api_cache_path(api, cache_key, ext)
	canonical_cache_path <- .dw_api_canonical_cache_path(api, cache_key, ext)
	args <- list(...)

	# Try cache first (sandbox or canonical fallback) unless explicit refresh.
	if (!isTRUE(refresh)) {
		hit_path <- if (file.exists(cache_path)) cache_path
		            else if (file.exists(canonical_cache_path)) canonical_cache_path
		            else NA_character_
		if (!is.na(hit_path)) {
			message("[dw_api/", api, "/", cache_key, "] cache hit: ", hit_path)
			return(dw_use(hit_path))
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
	message("[dw_api/", api, "/", cache_key, "] fetching live...")
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
		stop("dw_api_fetch: unsupported api '", api, "'. Supported: ",
		     "uis, sdmx, sdmx_codelist, wb, ilo, unsd_sdg, github_raw, http, json_get")
	)
	elapsed <- as.numeric(difftime(Sys.time(), t0, units = "secs"))

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
	dw_save(result, path = cache_path, metadata = api_metadata, mirror_to_z = TRUE)

	result
}

# ============================================================================
# dw_api_cached — explicit cache-only read
# ============================================================================

dw_api_cached <- function(api, cache_key, ext = "csv") {
	cache_path <- .dw_api_canonical_cache_path(api, cache_key, ext)
	if (!file.exists(cache_path)) {
		stop("dw_api_cached: no cache at ", cache_path,
		     "\n  Use dw_api_fetch() (producer mode) to populate.")
	}
	dw_use(cache_path)
}

# ============================================================================
# dw_api_inventory — list cached fetches
# ============================================================================

dw_api_inventory <- function(api = NULL) {
	root <- file.path(.try_get("teamsRawDataCanonical"), "_apis")
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
	do.call(rbind, rows)
}

# ============================================================================
# Per-API fetchers (internal)
# ============================================================================

#' UNESCO UIS API
#' Args: endpoint = "indicators", params = list(indicator = "299905")
.api_fetch_uis <- function(endpoint = "indicators", params = list(), ...) {
	.require("jsonlite")
	base <- "https://api.uis.unesco.org/api/public/data/"
	url <- paste0(base, endpoint)
	if (length(params) > 0) {
		qs <- paste(names(params), unlist(params), sep = "=", collapse = "&")
		url <- paste0(url, "?", qs)
	}
	raw <- jsonlite::fromJSON(url)
	if (!is.null(raw$records)) raw$records else raw
}

#' SDMX data fetch via rsdmx (any provider)
#' Args: providerId, flowRef, key, version, start, end
.api_fetch_sdmx <- function(providerId, flowRef, key,
                            version = "1.0", start = NULL, end = NULL, ...) {
	.require("rsdmx")
	as.data.frame(rsdmx::readSDMX(providerId = providerId, resource = "data",
	                              flowRef = flowRef, version = version,
	                              key = key, start = start, end = end,
	                              verbose = FALSE, ...))
}

#' SDMX codelist GET + JSON parse to (code, name, description) tibble.
#' Args: agency = "UNICEF", codelist = "CL_RESIDENCE", version = "1.0"
#' Replaces the 14 hand-coded GETs in nt/00_fetch_codebook.R.
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

#' World Bank data via wbstats::wb_data
.api_fetch_wb <- function(indicator, start_date = 2000,
                          end_date = as.numeric(format(Sys.Date(), "%Y")), ...) {
	.require("wbstats")
	wbstats::wb_data(indicator = indicator,
	                 start_date = start_date, end_date = end_date, ...)
}

#' World Bank indicator catalogue via wbstats::wb_indicators
.api_fetch_wb_indicators <- function(...) {
	.require("wbstats")
	wbstats::wb_indicators(...)
}

#' ILO SDMX
.api_fetch_ilo <- function(flowRef, key, start = NULL, end = NULL, ...) {
	.require("rsdmx")
	as.data.frame(rsdmx::readSDMX(providerId = "ILO", resource = "data",
	                              flowRef = flowRef, version = "1.0",
	                              key = key, start = start, end = end,
	                              verbose = FALSE, ...))
}

#' UNSD SDG API: httr::POST with form-encoded seriesCodes
#' Args: series_codes = c("SL_DOM_TSPD", "SG_LGL_GENEQEMP")
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

#' Pinned-commit raw.githubusercontent.com fetch.
#' Args: owner_repo = "unicef-drp/Country-and-Region-Metadata",
#'       ref = "main" or "abc1234" (sha or tag),
#'       path = "AU.csv"
#' Default behaviour is to record the resolved commit sha in metadata so
#' even `ref = "main"` runs are reproducible after the fact.
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
.api_fetch_http <- function(url, headers = list(), ...) {
	.require("httr")
	resp <- httr::GET(url, do.call(httr::add_headers, headers), ...)
	httr::stop_for_status(resp)
	httr::content(resp, as = "text", encoding = "UTF-8")
}

#' Generic JSON GET -> parsed object
.api_fetch_json_get <- function(url, ...) {
	.require("jsonlite")
	jsonlite::fromJSON(url, ...)
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
