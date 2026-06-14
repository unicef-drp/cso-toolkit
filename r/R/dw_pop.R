# =============================================================================
# dw_pop -- convenience wrapper for World Bank population indicators
# =============================================================================
#
# Thin wrapper around `dw_api_fetch(api = "wb")` for the World Bank
# total-population indicator (`SP.POP.TOTL`).  Every UNICEF sector needs
# a population denominator for weighted regional aggregates; pulling it
# directly via `dw_api_fetch` requires the caller to remember the
# indicator code, the cache key, and the column names.  `dw_pop()`
# wraps all three and returns a tidy `(REF_AREA, TIME_PERIOD,
# OBS_VALUE)` tibble.
#
# Mode contract: inherits whatever `dw_api_fetch()` enforces -- producer
# sessions can hit the network (and cache the result via `dw_save`),
# reviewer sessions read the cached deposit only (no live fetch).
#
# TODO: Python sibling at `python/src/dw_pop.py`, Stata sibling at
# `stata/src/dw_pop.ado`.  R-only in v0.4.0; cross-language parity
# tracked at GitHub issue #17.

#' Latest country-level population numbers
#'
#' Convenience wrapper around [dw_api_fetch()] for the World Bank
#' total-population indicator (`SP.POP.TOTL`).  Returns a tidy tibble
#' suitable for use as a weight column in [aggregate_data_v2()] or for
#' merging directly into a country-level dataset.
#'
#' When `year` is `NULL` (the default), only the latest available year
#' per country is returned.  When a specific year (or vector of years)
#' is supplied, the tibble is filtered to that subset.
#'
#' @param year Numeric or `NULL`.  Year (or years) to keep.  Default
#'   `NULL` returns the latest year per country.
#' @param indicator Character.  World Bank indicator code.  Default
#'   `"SP.POP.TOTL"` (total population).
#' @param countries Character or `NULL`.  ISO3 / M49 country codes to
#'   keep.  Default `NULL` returns every country in the World Bank
#'   response.
#' @param refresh Logical.  When `TRUE` and the session is in producer
#'   mode, force a live fetch and overwrite the cache.  Default
#'   `FALSE` (cache-first).
#' @param cache_key Character.  Cache filename basename forwarded to
#'   [dw_api_fetch()].  Default `"wb_population_sp_pop_totl"`.
#' @param verbose Logical or `NULL`.  When `TRUE`, emit progress
#'   messages to stderr.  `NULL` (default) inherits the session
#'   setting from [dw_verbosity()].
#' @param debug Logical or `NULL`.  When `TRUE`, emit detailed debug
#'   messages (implies `verbose`).  `NULL` (default) inherits the
#'   session setting from [dw_verbosity()].
#'
#' @return A tibble with columns `REF_AREA`, `TIME_PERIOD`,
#'   `OBS_VALUE`.  Sorted by `REF_AREA`, `TIME_PERIOD` (ascending).
#'
#' @examples
#' \dontrun{
#' # All countries, latest year
#' pop <- dw_pop()
#'
#' # All countries, 2023 only
#' pop_2023 <- dw_pop(year = 2023)
#'
#' # Specific country list
#' pop_sahel <- dw_pop(countries = c("BFA", "MLI", "NER", "TCD"))
#' }
#' @seealso [dw_regions()] for the standard regional-aggregate
#'   workflow that consumes `dw_pop()` output;
#'   [dw_api_fetch()] for the underlying cache mechanics.
#' @family demographics
#' @param verbose Logical or `NULL`. Show high-level progress and result
#'   messages. `NULL` (default) inherits `getOption("dw.verbose", TRUE)`;
#'   set `TRUE`/`FALSE` to override for this call. See [dw_verbosity()].
#' @param debug Logical or `NULL`. Show internal troubleshooting detail
#'   (resolved paths, dims, branch decisions). `NULL` (default) inherits
#'   `getOption("dw.debug", FALSE)`; implies `verbose`. See [dw_verbosity()].
#' @export
dw_pop <- function(year      = NULL,
                   indicator = "SP.POP.TOTL",
                   countries = NULL,
                   refresh   = FALSE,
                   cache_key = "wb_population_sp_pop_totl",
                   verbose   = NULL,
                   debug     = NULL) {

	.cso_require("dplyr", where = "dw_pop")
	vd <- .dw_vd(verbose, debug); v <- vd$v; d <- vd$d
	.dw_msg("dw_pop", "population: indicator=", indicator, if (is.null(year)) " (latest/country)" else paste0(" year=", paste(year, collapse = ",")), v = v)

	# Resolve via the standard API cache layer.
	raw <- dw_api_fetch(
		api       = "wb",
		cache_key = cache_key,
		refresh   = refresh,
		indicator = indicator,
		verbose   = v,
		debug     = d
	)

	# The wbstats response shape (post-2021):
	#   columns include `iso3c`, `country`, `date`, `value`,
	#   `unit`, `obs_status`, `indicator_id`.
	# Some older `wbstats` returns `iso2c` only; guard for both.
	col_iso  <- intersect(c("iso3c", "iso2c"), names(raw))[1]
	col_date <- intersect(c("date", "TIME_PERIOD"), names(raw))[1]
	col_val  <- intersect(c("value", "OBS_VALUE", indicator), names(raw))[1]
	if (any(is.na(c(col_iso, col_date, col_val)))) {
		stop(sprintf(
			"[cso_toolkit.dw_pop] Unexpected wbstats response shape: missing one of (iso, date, value) columns.\n  Got columns: %s\n  Fix: re-run with `refresh = TRUE` to repopulate the cache, or inspect the cache file directly.",
			paste(names(raw), collapse = ", ")
		), call. = FALSE)
	}

	tidy <- dplyr::tibble(
		REF_AREA    = raw[[col_iso]],
		TIME_PERIOD = as.integer(raw[[col_date]]),
		OBS_VALUE   = as.numeric(raw[[col_val]])
	)
	# Drop rows missing the key triplet; WB sometimes returns sparse
	# obs (e.g. regional aggregates with NA for some years).
	tidy <- tidy[stats::complete.cases(tidy), , drop = FALSE]

	# Country filter
	if (!is.null(countries)) {
		tidy <- tidy[tidy$REF_AREA %in% countries, , drop = FALSE]
	}

	# Year filter (or latest-per-country fallback)
	if (!is.null(year)) {
		tidy <- tidy[tidy$TIME_PERIOD %in% as.integer(year), , drop = FALSE]
	} else {
		# Latest year per country
		tidy <- tidy[order(tidy$REF_AREA, -tidy$TIME_PERIOD), , drop = FALSE]
		tidy <- tidy[!duplicated(tidy$REF_AREA), , drop = FALSE]
	}

	# Stable sort: country, year ascending
	tidy <- tidy[order(tidy$REF_AREA, tidy$TIME_PERIOD), , drop = FALSE]
	rownames(tidy) <- NULL
	.dw_msg("dw_pop", "returned ", nrow(tidy), " rows", v = v)
	tidy
}
