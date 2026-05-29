# =============================================================================
# Aggregate Data Function v2.0 - PROPOSED IMPROVEMENTS
# =============================================================================
#
# This file contains the proposed improved version of aggregate_data()
# designed to be relevant for ALL sectors in DW-Production.
#
# Author: D&A Team
# Date: December 2025
# Status: STABLE
# =============================================================================

# NOTE: `.cso_require()` lives in zzz.R as a single shared helper.
# Dependency checks happen INSIDE the public function bodies (see
# aggregate_data_v2() below), not at file source-time, so vendoring
# this file into a consumer's 00_functions/ without dplyr installed
# only fails on first call -- not at source().
#
# v0.4.4 (#36): we also define a local fallback for `.cso_require()`
# so this file is safe to source STANDALONE (without `zzz.R` having
# been sourced first). Without the fallback, calling
# `aggregate_data_v2(...)` after a bare `source("aggregate_data_v2.R")`
# errored with "could not find function .cso_require". The check is
# `exists(..., inherits = TRUE)`, so when `zzz.R` has already been
# sourced into `.GlobalEnv` the shared helper wins and nothing is
# redefined.
if (!exists(".cso_require", mode = "function", inherits = TRUE)) {
	.cso_require <- function(pkgs, where = "<unknown>") {
		for (p in pkgs) {
			if (!requireNamespace(p, quietly = TRUE)) {
				stop(sprintf(
					"[cso_toolkit.%s] Requires the '%s' package but it is not installed.\n  Fix: install.packages('%s')",
					where, p, p
				), call. = FALSE)
			}
		}
		invisible(TRUE)  # mirror the zzz.R return contract
	}
}

# v0.4.5 (#46): the file uses the magrittr pipe (`%>%`) on dplyr verbs
# below. In the installed-package context, `NAMESPACE` carries
# `importFrom(magrittr, "%>%")` so the pipe is bound inside the
# package. In STANDALONE-SOURCE mode (no NAMESPACE), `requireNamespace()`
# called by `.cso_require()` loads but does NOT attach exports — so
# `%>%` would still be unbound and `source("aggregate_data_v2.R")`
# would error at the first pipe call.
#
# Bind `%>%` locally when it isn't already in scope. The
# `exists(..., inherits = TRUE)` check makes this a no-op when the
# installed package already provides the pipe via its NAMESPACE
# importFrom.
if (!exists("%>%", mode = "function", inherits = TRUE)) {
	`%>%` <- magrittr::`%>%`
}

#' Aggregate Data v2.0 - Enhanced for Cross-Sector Use
#'
#' This function aggregates data by specified grouping variables with support for
#' multiple aggregation methods, coverage thresholds, and automatic metadata generation.
#'
#' @param data A data frame containing the data to be aggregated.
#' @param value Character. Column name containing values to aggregate.
#' @param weight Character. Column name containing population weights.
#' @param by Character vector. Column names to group by for aggregation.
#' @param country_id Character. Column name identifying countries (for country coverage). Default "REF_AREA".
#' @param global Logical. Include global aggregation? Default TRUE.
#' @param method Character. Aggregation method: "weighted_mean", "mean", "sum", "proportion". Default "weighted_mean".
#' @param coverage_threshold Numeric. Minimum population coverage (0-1) to report aggregate. Default NULL (no threshold).
#' @param pop.coverage Logical. Return population coverage? Default TRUE.
#' @param country.coverage Logical. Return country count? Default TRUE.
#' @param total.population Logical. Return total population in group? Default FALSE.
#' @param number.affected Logical. Return number affected (for proportion method)? Default FALSE.
#' @param global_label Character. Label for global aggregate row. Default "WORLD".
#' @param validate Logical. Perform input validation? Default TRUE.
#'
#' @return A data frame with aggregated data including requested metadata columns.
#' @seealso [aggregate_data()] for the v1 signature kept for back-compat;
#'   [generate_agg_footnote()] for the standard footnote string;
#'   [apply_time_window()] to filter to the latest observation in a window.
#' @family aggregate
#' @export
aggregate_data_v2 <- function(data,
                              value, 
                              weight, 
                              by, 
                              country_id = "REF_AREA",
                              global = TRUE, 
                              method = c("weighted_mean", "mean", "sum", "proportion"),
                              coverage_threshold = NULL,
                              pop.coverage = TRUE, 
                              country.coverage = TRUE,
                              total.population = FALSE,
                              number.affected = FALSE,
                              global_label = "WORLD",
                              validate = TRUE) {

  .cso_require(c("dplyr", "tidyr", "rlang"), where = "aggregate_data_v2")

  if (validate) {
    required_cols <- unique(c(value, weight, by))
    missing_cols <- setdiff(required_cols, names(data))
    if (length(missing_cols) > 0) {
      present <- paste(utils::head(names(data), 10), collapse = ", ")
      if (length(names(data)) > 10) present <- paste0(present, "...")
      stop(sprintf(
        "[cso_toolkit.aggregate_data_v2] Missing required column(s): %s\n  Data columns: %s\n  Fix: check column spelling / casing for `value =`, `weight =`, and each entry of `by =`.",
        paste(missing_cols, collapse = ", "), present
      ), call. = FALSE)
    }
    if (country.coverage && !country_id %in% names(data)) {
      warning(sprintf(
        "[cso_toolkit.aggregate_data_v2] `country_id` column '%s' not found. Country coverage will use row count instead, which may overcount when a country has multiple rows.",
        country_id
      ), call. = FALSE)
    }
    if (!is.null(coverage_threshold)) {
      if (coverage_threshold < 0 || coverage_threshold > 1) {
        stop(sprintf(
          "[cso_toolkit.aggregate_data_v2] `coverage_threshold` must be between 0 and 1; got %s.\n  Fix: pass a fraction in [0, 1]; common UNICEF default is 0.5 (50%% population coverage required).",
          format(coverage_threshold)
        ), call. = FALSE)
      }
    }
  }

  method <- match.arg(method)

  value_sym   <- rlang::sym(value)
  weight_sym  <- rlang::sym(weight)
  by_syms     <- rlang::syms(by)

  data_prep <- data %>%
    tidyr::drop_na(all_of(by)) %>%
    dplyr::group_by(dplyr::across(dplyr::all_of(by))) %>%
    dplyr::mutate(
      .total_weight = sum(!!weight_sym, na.rm = TRUE),
      .weight_non_na = dplyr::if_else(!is.na(!!value_sym), !!weight_sym, 0),
      .coverage_actual = dplyr::if_else(.total_weight > 0, sum(.weight_non_na, na.rm = TRUE) / .total_weight, 0),
      .non_na_count = dplyr::if_else(!is.na(!!value_sym), 1L, 0L),
      .total_count = dplyr::n(),
      .num_affected = dplyr::if_else(!is.na(!!value_sym), (as.numeric(!!value_sym) / 100) * !!weight_sym, NA_real_)
    ) %>%
    dplyr::ungroup()

  aggregated_data <- data_prep %>%
    dplyr::group_by(dplyr::across(dplyr::all_of(by))) %>%
    dplyr::summarise(
      Aggregate = dplyr::case_when(
        method == "mean" ~ mean(as.numeric(!!value_sym), na.rm = TRUE),
        method == "weighted_mean" ~ stats::weighted.mean(as.numeric(!!value_sym), as.numeric(!!weight_sym), na.rm = TRUE),
        method == "sum" ~ (sum(as.numeric(!!value_sym), na.rm = TRUE) / sum(as.numeric(!!weight_sym), na.rm = TRUE)) * 100,
        method == "proportion" ~ {
          datapop <- sum(.weight_non_na, na.rm = TRUE)
          popaffected <- sum(.num_affected, na.rm = TRUE)
          dplyr::if_else(datapop > 0, (popaffected / datapop) * 100, NA_real_)
        }
      ),
      Pop_Covered = dplyr::if_else(sum(as.numeric(!!weight_sym), na.rm = TRUE) > 0,
                                   sum(.weight_non_na, na.rm = TRUE) / sum(as.numeric(!!weight_sym), na.rm = TRUE), 0),
      Country_Coverage = if (country_id %in% names(dplyr::pick(dplyr::everything()))) dplyr::n_distinct(dplyr::if_else(!is.na(!!value_sym), as.character(!!rlang::sym(country_id)), NA_character_), na.rm = TRUE) else dplyr::n(),
      Total_Countries = if (country_id %in% names(dplyr::pick(dplyr::everything()))) dplyr::n_distinct(!!rlang::sym(country_id), na.rm = TRUE) else dplyr::n(),
      Total_Population = sum(as.numeric(!!weight_sym), na.rm = TRUE),
      Data_Population = sum(.weight_non_na, na.rm = TRUE),
      Number_Affected = sum(.num_affected, na.rm = TRUE),
      .groups = 'drop'
    )

  if (!is.null(coverage_threshold)) {
    aggregated_data <- aggregated_data %>%
      dplyr::mutate(
        Aggregate = dplyr::if_else(Pop_Covered >= coverage_threshold, Aggregate, NA_real_)
      )
  }

  if (global) {
    global_aggregate <- data_prep %>%
      dplyr::summarise(
        Aggregate = dplyr::case_when(
          method == "mean" ~ mean(as.numeric(!!value_sym), na.rm = TRUE),
          method == "weighted_mean" ~ stats::weighted.mean(as.numeric(!!value_sym), as.numeric(!!weight_sym), na.rm = TRUE),
          method == "sum" ~ (sum(as.numeric(!!value_sym), na.rm = TRUE) / sum(as.numeric(!!weight_sym), na.rm = TRUE)) * 100,
          method == "proportion" ~ {
            datapop <- sum(.weight_non_na, na.rm = TRUE)
            popaffected <- sum(.num_affected, na.rm = TRUE)
            dplyr::if_else(datapop > 0, (popaffected / datapop) * 100, NA_real_)
          }
        ),
        Pop_Covered = if (sum(as.numeric(!!weight_sym), na.rm = TRUE) > 0) sum(.weight_non_na, na.rm = TRUE) / sum(as.numeric(!!weight_sym), na.rm = TRUE) else 0,
        Country_Coverage = if (country_id %in% names(dplyr::pick(dplyr::everything()))) dplyr::n_distinct(dplyr::if_else(!is.na(!!value_sym), as.character(!!rlang::sym(country_id)), NA_character_), na.rm = TRUE) else dplyr::n(),
        Total_Countries = if (country_id %in% names(dplyr::pick(dplyr::everything()))) dplyr::n_distinct(!!rlang::sym(country_id), na.rm = TRUE) else dplyr::n(),
        Total_Population = sum(as.numeric(!!weight_sym), na.rm = TRUE),
        Data_Population = sum(.weight_non_na, na.rm = TRUE),
        Number_Affected = sum(.num_affected, na.rm = TRUE)
      )

    if (!is.null(coverage_threshold)) {
      global_aggregate <- global_aggregate %>%
        dplyr::mutate(
          Aggregate = dplyr::if_else(Pop_Covered >= coverage_threshold, Aggregate, NA_real_)
        )
    }

    for (by_var in by) {
      global_aggregate[[by_var]] <- global_label
      aggregated_data[[by_var]] <- as.character(aggregated_data[[by_var]])
    }

    aggregated_data <- dplyr::bind_rows(aggregated_data, global_aggregate)
  }

  output_cols <- c(by, "Aggregate")
  if (pop.coverage) output_cols <- c(output_cols, "Pop_Covered")
  if (country.coverage) output_cols <- c(output_cols, "Country_Coverage", "Total_Countries")
  if (total.population) output_cols <- c(output_cols, "Total_Population", "Data_Population")
  if (number.affected && method == "proportion") output_cols <- c(output_cols, "Number_Affected")

  aggregated_data %>% dplyr::select(dplyr::all_of(output_cols))
}

#' Generate standardized footnotes for aggregated estimates
#'
#' Builds the canonical footnote string used under aggregated tables
#' and charts: `"N/M countries (P % population coverage)"` with an
#' optional `"Based on latest estimates from YYYY to YYYY."` prefix and
#' optional exemption / exclusion suffixes.
#'
#' @param country_coverage Integer. Number of countries contributing
#'   non-missing observations.
#' @param total_countries Integer. Denominator for the country-coverage
#'   fraction.
#' @param pop_coverage Numeric in [0, 1]. Fraction of total population
#'   represented by the contributing countries; rendered as an integer
#'   percent.
#' @param start_year,end_year Optional integers. Inclusive bounds of the
#'   year window from which the latest estimate per country was drawn.
#' @param exemptions Optional character vector of country codes that
#'   were retained outside the window (e.g. fragile-state exceptions);
#'   appended as `"Exemptions: ..."`.
#' @param exclusions Optional character vector of country codes that
#'   were dropped before aggregation; appended as `"Exclusions: ..."`.
#'
#' @return Character. A single-line footnote.
#'
#' @seealso [aggregate_data_v2()] (typically the producer of the
#'   coverage numbers fed into this footnote).
#' @family aggregate
#' @export
generate_agg_footnote <- function(country_coverage,
                                  total_countries,
                                  pop_coverage,
                                  start_year = NULL,
                                  end_year = NULL,
                                  exemptions = NULL,
                                  exclusions = NULL) {
  footnote <- paste0(
    country_coverage, "/", total_countries, " countries (",
    round(pop_coverage * 100), " % population coverage)"
  )
  if (!is.null(start_year) && !is.null(end_year)) {
    footnote <- paste0(
      "Based on latest estimates from ", start_year, " to ", end_year, ". ",
      footnote
    )
  }
  if (!is.null(exemptions) && length(exemptions) > 0) {
    footnote <- paste0(footnote, ". Exemptions: ", paste(exemptions, collapse = ", "))
  }
  if (!is.null(exclusions) && length(exclusions) > 0) {
    footnote <- paste0(footnote, ". Exclusions: ", paste(exclusions, collapse = ", "))
  }
  footnote
}

#' Filter data to latest observation within a time window, with exemptions
#'
#' Within each country, keeps the row with the latest `time_col` value
#' provided that latest year falls within `[start_year, end_year]`.
#' Countries in `exemptions` keep their latest value regardless of the
#' window; countries in `exclusions` are dropped before ranking.
#'
#' @param data Data frame.
#' @param country_col Character. Column identifying country.
#'   Defaults to `"REF_AREA"`.
#' @param time_col Character. Column holding year values.  Defaults to
#'   `"TIME_PERIOD"`.
#' @param start_year,end_year Integer. Inclusive window bounds.
#' @param exemptions Optional character vector of country codes whose
#'   latest observation is kept even when outside the window.
#' @param exclusions Optional character vector of country codes to drop
#'   before ranking.
#'
#' @return A data frame with one row per country (or none for countries
#'   that failed both window and exemption tests).
#'
#' @seealso [aggregate_data_v2()] (typical downstream consumer of the
#'   windowed slice).
#' @family aggregate
#' @export
apply_time_window <- function(data,
                              country_col = "REF_AREA",
                              time_col = "TIME_PERIOD",
                              start_year,
                              end_year,
                              exemptions = NULL,
                              exclusions = NULL) {
  .cso_require(c("dplyr", "rlang"), where = "apply_time_window")
  country_sym <- rlang::sym(country_col)
  time_sym <- rlang::sym(time_col)
  data %>%
    dplyr::filter(!(!!country_sym %in% exclusions)) %>%
    dplyr::group_by(!!country_sym) %>%
    dplyr::mutate(
      .year_rank = rank(-as.numeric(!!time_sym), ties.method = "first"),
      .in_window = floor(as.numeric(!!time_sym)) >= start_year & floor(as.numeric(!!time_sym)) <= end_year,
      .is_exempt = !!country_sym %in% exemptions,
      .eligible = (.year_rank == 1 & .in_window) | (.year_rank == 1 & .is_exempt)
    ) %>%
    dplyr::filter(.eligible) %>%
    dplyr::select(-starts_with(".")) %>%
    dplyr::ungroup()
}

## Note on `aggregate_data()` (the v1 signature):
## A legacy `aggregate_data()` is provided by `aggregate_data.R` (separate
## file). Defining it here too would shadow the legacy definition based on
## source order, which is fragile. If you want the v2 behaviour through the
## v1 signature, call `aggregate_data_v2(..., global_label = "World",
## validate = FALSE)` explicitly.

# =============================================================================
# v0.4.4 — dw_-prefixed canonical alias (issue #36)
# =============================================================================
# Toolkit-export naming consolidates around the `dw_` prefix in v0.4.x;
# the non-prefixed names here predate that convention. Adding the alias
# lets consumers migrate at their own pace. The follow-up issue (filed
# alongside this PR) tracks the rest of the un-prefixed exports
# (aggregate_data, generate_markdown_report, apply_time_window,
# generate_agg_footnote, create_profile, review_profile, test_scripts,
# create_dw_sector_script).

#' @rdname aggregate_data_v2
#' @export
dw_aggregate_data_v2 <- aggregate_data_v2

# =============================================================================
# v0.4.5 — dw_-prefixed canonical aliases for the other two exports in this file (#42)
# =============================================================================

#' @rdname generate_agg_footnote
#' @export
dw_generate_agg_footnote <- generate_agg_footnote

#' @rdname apply_time_window
#' @export
dw_apply_time_window <- apply_time_window
