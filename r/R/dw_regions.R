# =============================================================================
# dw_regions -- UNICEF regional-aggregate convenience wrapper
# =============================================================================
#
# Fetch the UNICEF region taxonomy (default `UNICEF_REP_REG_GLOBAL` from
# the public `unicef-drp/Country-and-Region-Metadata` repo) and use it
# to compute regional aggregates of a country-level dataset via
# [aggregate_data_v2()].
#
# Default workflow:
#   1. Resolve the country -> region map by fetching
#      "<taxonomy>.csv" via `dw_api_fetch(api = "github_raw", ...)`.
#   2. When `weight = "population"` (the default), pull population
#      denominators via `dw_pop()` and merge them into `data`.
#   3. For each region, run `aggregate_data_v2()` with
#      `method = method` and the user-supplied `by` columns.
#   4. Concatenate the original country-level rows with the new
#      regional rows so downstream consumers see a single tibble.
#
# TODO: Python sibling at `python/src/dw_regions.py`, Stata sibling
# at `stata/src/dw_regions.ado`.  R-only in v0.4.0; cross-language
# parity tracked at GitHub issue #18.

#' UNICEF regional aggregates appended to a country-level tibble
#'
#' Convenience wrapper that fetches the UNICEF region taxonomy,
#' computes regional aggregates of `data` via [aggregate_data_v2()],
#' and returns the input tibble with the regional rows appended.
#'
#' The taxonomy is pulled (and cached) from the public
#' `unicef-drp/Country-and-Region-Metadata` GitHub repo as
#' `"<taxonomy>.csv"`.  Pass `refresh_metadata = TRUE` to force a
#' live re-fetch.
#'
#' When `weight = "population"` (the default), [dw_pop()] is called
#' to fetch World Bank total-population denominators and the result
#' is merged into `data` by `REF_AREA` + `TIME_PERIOD`.  Pass a
#' different string (matching a column already present in `data`) to
#' use a sector-specific weight instead.
#'
#' @param data A country-level tibble that includes at least
#'   `REF_AREA` (ISO3) and the column named in `value`.  May also
#'   include `TIME_PERIOD` and additional grouping columns referenced
#'   by `by`.
#' @param value Character.  Column to aggregate.
#' @param weight Character.  Weight column name.  Default
#'   `"population"` triggers a [dw_pop()] merge; any other string is
#'   treated as an existing column in `data`.
#' @param method Character.  Aggregation method forwarded to
#'   [aggregate_data_v2()].  Default `"weighted_mean"`.
#' @param taxonomy Character.  Region-taxonomy CSV basename
#'   (without extension) in `unicef-drp/Country-and-Region-Metadata`.
#'   Default `"UNICEF_REP_REG_GLOBAL"`.
#' @param by Character vector.  Grouping columns inside the region
#'   that survive the aggregate (typically `INDICATOR` and
#'   `TIME_PERIOD`).  Default `c("INDICATOR", "TIME_PERIOD")`.
#' @param refresh_metadata Logical.  When `TRUE` and the session is
#'   in producer mode, force a live re-fetch of the region taxonomy
#'   and overwrite the cache.  Default `FALSE` (cache-first).
#'
#' @return A tibble containing the original country-level rows of
#'   `data` plus one row per region per `by` tuple.  Regional rows
#'   carry the region code in `REF_AREA`; coverage metadata columns
#'   from `aggregate_data_v2()` (`Pop_Covered`, `Country_Coverage`,
#'   ...) propagate.
#'
#' @examples
#' \dontrun{
#' # Country-level tibble with INDICATOR + TIME_PERIOD + OBS_VALUE
#' national <- dw_use(name = "dw_ed_edu.csv", sector = "ed", kind = "wrk")
#'
#' # Add UNICEF region rows (population-weighted means)
#' enriched <- dw_regions(national, value = "OBS_VALUE")
#'
#' # Use a sector-specific weight column already in the data
#' alt <- dw_regions(national, value = "OBS_VALUE", weight = "births_under5")
#' }
#' @seealso [dw_pop()] (population denominators); [aggregate_data_v2()]
#'   (the underlying aggregator).
#' @family demographics
#' @export
dw_regions <- function(data,
                       value,
                       weight           = "population",
                       method           = "weighted_mean",
                       taxonomy         = "UNICEF_REP_REG_GLOBAL",
                       by               = c("INDICATOR", "TIME_PERIOD"),
                       refresh_metadata = FALSE) {

	.cso_require(c("dplyr"), where = "dw_regions")

	if (!is.data.frame(data)) {
		stop("[cso_toolkit.dw_regions] `data` must be a data frame.\n  Fix: pass the tibble returned by your sector pipeline (e.g. dw_use(...)).",
		     call. = FALSE)
	}
	required_cols <- c("REF_AREA", value)
	missing <- setdiff(required_cols, names(data))
	if (length(missing) > 0) {
		stop(sprintf(
			"[cso_toolkit.dw_regions] Missing required column(s): %s\n  Data columns: %s\n  Fix: ensure your tibble has REF_AREA (ISO3) and the column named in `value =`.",
			paste(missing, collapse = ", "),
			paste(utils::head(names(data), 10), collapse = ", ")
		), call. = FALSE)
	}

	# --- 1. Region taxonomy --------------------------------------------------
	taxonomy_path <- paste0(taxonomy, ".csv")
	region_map <- dw_api_fetch(
		api        = "github_raw",
		cache_key  = paste0("regions_", tolower(taxonomy)),
		refresh    = refresh_metadata,
		owner_repo = "unicef-drp/Country-and-Region-Metadata",
		path       = taxonomy_path
	)
	# Expect columns: REF_AREA, REGION (or similar).  Try common alternates.
	col_country <- intersect(c("REF_AREA", "ISO3", "iso3c", "country_code"),
	                         names(region_map))[1]
	col_region  <- intersect(c("REGION", "region", "REGION_CODE", "UNICEF_REGION"),
	                         names(region_map))[1]
	if (any(is.na(c(col_country, col_region)))) {
		stop(sprintf(
			"[cso_toolkit.dw_regions] Region taxonomy lacks recognised country / region columns.\n  Got: %s\n  Fix: confirm the taxonomy CSV in unicef-drp/Country-and-Region-Metadata uses one of: country = (REF_AREA | ISO3 | iso3c | country_code); region = (REGION | region | REGION_CODE | UNICEF_REGION).",
			paste(names(region_map), collapse = ", ")
		), call. = FALSE)
	}
	region_map <- dplyr::tibble(
		REF_AREA = region_map[[col_country]],
		REGION   = region_map[[col_region]]
	)
	region_map <- region_map[!is.na(region_map$REGION) & nzchar(region_map$REGION), ,
	                         drop = FALSE]

	# --- 2. Weight column ---------------------------------------------------
	working <- data
	if (identical(weight, "population")) {
		# Pull WB total population.  When `data` has TIME_PERIOD, merge by
		# REF_AREA + TIME_PERIOD; otherwise merge on REF_AREA (using the
		# latest year per country from dw_pop()).
		if ("TIME_PERIOD" %in% names(working)) {
			years_needed <- unique(working$TIME_PERIOD)
			pop <- dw_pop(year = years_needed)
			# If WB has nothing for a requested year (e.g. very recent), fall
			# back to the latest year per country so the merge still attaches
			# *some* denominator.  Country-years with no pop data drop out of
			# the weighted average naturally.
			fallback_pop <- dw_pop()
			pop <- dplyr::bind_rows(pop, fallback_pop)
			pop <- pop[!duplicated(pop[, c("REF_AREA", "TIME_PERIOD")]), ,
			           drop = FALSE]
			working <- merge(working, pop[, c("REF_AREA", "TIME_PERIOD", "OBS_VALUE")],
			                 by = c("REF_AREA", "TIME_PERIOD"),
			                 all.x = TRUE, suffixes = c("", ".pop"))
			weight_col <- "OBS_VALUE.pop"
			# When OBS_VALUE was the value column, the merge renamed pop to
			# OBS_VALUE.pop above.  Otherwise it's just OBS_VALUE.
			if (!weight_col %in% names(working)) weight_col <- "OBS_VALUE"
		}
		else {
			pop <- dw_pop()
			working <- merge(working, pop[, c("REF_AREA", "OBS_VALUE")],
			                 by = "REF_AREA",
			                 all.x = TRUE, suffixes = c("", ".pop"))
			weight_col <- "OBS_VALUE.pop"
			if (!weight_col %in% names(working)) weight_col <- "OBS_VALUE"
		}
	}
	else {
		if (!weight %in% names(working)) {
			stop(sprintf(
				"[cso_toolkit.dw_regions] Weight column '%s' not in data.\n  Available: %s\n  Fix: pass `weight = \"population\"` to fetch WB SP.POP.TOTL, or name an existing column.",
				weight, paste(utils::head(names(working), 10), collapse = ", ")
			), call. = FALSE)
		}
		weight_col <- weight
	}

	# --- 3. Join data to region map -----------------------------------------
	joined <- merge(working, region_map, by = "REF_AREA", all.x = TRUE)
	# Rows without a region map entry can't be aggregated; warn rather than
	# silently drop them.
	missing_region <- unique(joined$REF_AREA[is.na(joined$REGION)])
	if (length(missing_region) > 0) {
		warning(sprintf(
			"[cso_toolkit.dw_regions] %d country code(s) not in taxonomy '%s' -- excluded from regional aggregates: %s",
			length(missing_region), taxonomy,
			paste(utils::head(missing_region, 10), collapse = ", ")
		), call. = FALSE)
		joined <- joined[!is.na(joined$REGION), , drop = FALSE]
	}

	# --- 4. Aggregate per region --------------------------------------------
	# aggregate_data_v2 takes a single `by` and treats REGION as one of the
	# grouping vars.  We pass `c(by, "REGION")` so each region/by tuple
	# gets its own row.
	regional <- aggregate_data_v2(
		data               = joined,
		value              = value,
		weight             = weight_col,
		by                 = c("REGION", by),
		country_id         = "REF_AREA",
		global             = FALSE,            # caller can stack via dw_regions(taxonomy = "...WORLD...")
		method             = method,
		coverage_threshold = NULL,
		validate           = FALSE
	)
	# Rename REGION -> REF_AREA so the output is shape-compatible with
	# country-level rows (a downstream consumer can `bind_rows()` without
	# renaming).
	if ("REGION" %in% names(regional)) {
		names(regional)[names(regional) == "REGION"] <- "REF_AREA"
	}
	# Drop the merged .pop weight column from the regional rows so the
	# schema matches the input.
	if (weight_col == "OBS_VALUE.pop" && "OBS_VALUE.pop" %in% names(regional)) {
		regional[["OBS_VALUE.pop"]] <- NULL
	}

	# --- 5. Concatenate -----------------------------------------------------
	# bind_rows is forgiving about column mismatches (NA-fills); use it so
	# coverage metadata columns surface in the regional rows but not the
	# country-level rows.
	dplyr::bind_rows(data, regional)
}
