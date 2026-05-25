#---------------------------------------------------------------------
# cso-toolkit: dw_nestweight — redistribute survey weights from missing
# nested observations to produce consistent aggregate estimates when
# missing values do not occur completely at random.
#---------------------------------------------------------------------
# Ported from:
#   World Bank EduAnalyticsToolkit `edukit_nestweight` / `nestweight`
#   v1.0 (8SEP2020), Author: Diana Goldemberg.
#   https://github.com/worldbank/EduAnalyticsToolkit
# Algorithm preserved; signature adapted to R conventions (data-first
# pipe-friendly; returns a tibble; vectorised across by-levels).
#---------------------------------------------------------------------

#' Redistribute survey weights from missing nested observations
#'
#' Computes a per-stratum adjustment that scales original weights up so the
#' sum of weights on non-missing observations equals the sum of weights on
#' all observations in the stratum. This is the textbook treatment for
#' obtaining consistent stratified aggregate estimates when missingness on
#' the value of interest is not completely at random within the stratum
#' (i.e. MAR within strata, not MCAR).
#'
#' Within each level of `by`:
#'
#' \deqn{scale_l = \frac{\sum_{i \in l} w_i}{\sum_{i \in l, v_i \text{ observed}} w_i}}
#'
#' and the new weight is
#'
#' \deqn{w'_i = w_i \cdot scale_l \quad \text{if } v_i \text{ observed}, \quad 0 \text{ otherwise}.}
#'
#' This preserves the stratum total \eqn{\sum w'_i = \sum w_i} while
#' concentrating mass on the observations that actually contribute to the
#' aggregate estimate of \eqn{v}.
#'
#' @param data A data frame.
#' @param value Character. Column name whose non-missingness drives the
#'   redistribution.
#' @param by Character. Column name defining the stratification (the level
#'   within which redistribution happens — typically a sampling stratum,
#'   country, or domain).
#' @param weight Character or `NULL`. Column name of the original weight.
#'   If `NULL` (default), an implicit weight of 1 is used (so the helper
#'   degenerates to per-stratum non-missing counts).
#' @param new_weight Character. Name of the redistributed-weight column
#'   added to the returned data frame. Defaults to `"weight_adj"`.
#' @param only Logical predicate or `NULL`. If supplied, only observations
#'   where the predicate is `TRUE` are eligible for the denominator
#'   (i.e. they contribute to the redistributed weights). Useful for
#'   "only redistribute over respondents who were asked the question".
#' @param verbose Logical. If `TRUE` (default), reports per-stratum mean
#'   of `value` under original vs. redistributed weights, plus the
#'   pooled mean. Set `FALSE` to suppress.
#'
#' @return The input `data` with one new column (`new_weight`) appended.
#'
#' @examples
#' \dontrun{
#' # DHS-style: redistribute the household weight within country-region
#' # strata to compensate for missingness on the outcome `stunting`.
#' library(dplyr)
#' dhs <- mics |>
#'   dw_nestweight(value = "stunting",
#'              by = "stratum_id",
#'              weight = "hh_weight",
#'              new_weight = "hh_weight_adj")
#'
#' # Verify the stratum totals are preserved:
#' dhs |>
#'   group_by(stratum_id) |>
#'   summarise(sum_orig = sum(hh_weight),
#'             sum_adj  = sum(hh_weight_adj))
#' }
#' @seealso [aggregate_data_v2()] for the downstream weighted aggregation
#'   that typically consumes `new_weight`.
#' @family survey-weights
#' @export
dw_nestweight <- function(data,
                       value,
                       by,
                       weight = NULL,
                       new_weight = "weight_adj",
                       only = NULL,
                       verbose = TRUE) {
  if (!is.data.frame(data)) {
    stop(sprintf(
      "[cso_toolkit.dw_nestweight] `data` must be a data frame; got %s.\n  Fix: convert your input (e.g. as.data.frame(x)) before calling.",
      class(data)[1L]
    ), call. = FALSE)
  }
  if (!is.character(value) || length(value) != 1L) {
    stop("[cso_toolkit.dw_nestweight] `value` must be a single column name (character of length 1).\n  Fix: pass one column name as a string, e.g. value = 'stunting'.",
         call. = FALSE)
  }
  if (!is.character(by) || length(by) != 1L) {
    stop("[cso_toolkit.dw_nestweight] `by` must be a single column name (the stratum).\n  Fix: pass one column name as a string, e.g. by = 'stratum_id'.",
         call. = FALSE)
  }
  present <- paste(utils::head(names(data), 10), collapse = ", ")
  if (length(names(data)) > 10) present <- paste0(present, "...")
  if (!value %in% names(data)) {
    stop(sprintf(
      "[cso_toolkit.dw_nestweight] Column '%s' (passed as `value =`) not found in data.\n  Data columns: %s\n  Fix: check spelling / casing on the value column.",
      value, present
    ), call. = FALSE)
  }
  if (!by %in% names(data)) {
    stop(sprintf(
      "[cso_toolkit.dw_nestweight] Column '%s' (passed as `by =`) not found in data.\n  Data columns: %s\n  Fix: check spelling / casing on the stratum column.",
      by, present
    ), call. = FALSE)
  }
  if (!is.null(weight)) {
    if (!is.character(weight) || length(weight) != 1L) {
      stop("[cso_toolkit.dw_nestweight] `weight` must be a single column name or NULL.\n  Fix: pass weight = 'colname' or omit (defaults to unit weights).",
           call. = FALSE)
    }
    if (!weight %in% names(data)) {
      stop(sprintf(
        "[cso_toolkit.dw_nestweight] Column '%s' (passed as `weight =`) not found in data.\n  Data columns: %s\n  Fix: check spelling / casing, or pass weight = NULL to use implicit unit weights.",
        weight, present
      ), call. = FALSE)
    }
  }

  v_obs <- !is.na(data[[value]])
  w_orig <- if (is.null(weight)) {
    rep(1, nrow(data))
  } else {
    w <- data[[weight]]
    if (!is.numeric(w)) {
      stop(sprintf(
        "[cso_toolkit.dw_nestweight] Weight column '%s' is not numeric.\n  Fix: clean the weight column upstream (drop non-numeric rows or cast to numeric) before calling.",
        weight
      ), call. = FALSE)
    }
    w
  }
  stratum <- data[[by]]
  if (any(is.na(stratum))) {
    warning(sprintf(
      "[cso_toolkit.dw_nestweight] `%s` has %d NA stratum value(s); those rows get weight 0.",
      by, sum(is.na(stratum))
    ), call. = FALSE)
  }

  eligible <- v_obs & !is.na(w_orig) & !is.na(stratum)
  if (!is.null(only)) {
    if (!is.logical(only) || length(only) != nrow(data)) {
      stop(sprintf(
        "[cso_toolkit.dw_nestweight] `only` must be a logical vector of length nrow(data) (%d); got length %d with type %s.\n  Fix: build the mask from the same data frame, e.g. only = !is.na(data$answered_q).",
        nrow(data), length(only), class(only)[1L]
      ), call. = FALSE)
    }
    eligible <- eligible & only
  }

  total_w_by    <- tapply(w_orig,    stratum, sum, na.rm = TRUE)
  eligible_w_by <- tapply(w_orig * eligible, stratum, sum, na.rm = TRUE)

  scale_by <- ifelse(eligible_w_by > 0, total_w_by / eligible_w_by, 0)
  scale_per_row <- as.numeric(scale_by[as.character(stratum)])
  scale_per_row[is.na(scale_per_row)] <- 0

  w_new <- ifelse(eligible, w_orig * scale_per_row, 0)

  data[[new_weight]] <- w_new

  if (isTRUE(verbose)) {
    v           <- data[[value]]
    n_strata    <- length(total_w_by)
    n_eligible  <- sum(eligible)
    n_total     <- nrow(data)
    cat("dw_nestweight():", n_strata, "stratum levels;",
        n_eligible, "/", n_total, "observations eligible.\n")
    # Pooled-mean diagnostic only meaningful for numeric `value`; for
    # character / factor / logical, skip with a clear note rather than
    # erroring out of an otherwise-successful redistribution.
    if (is.numeric(v)) {
      orig_mean <- stats::weighted.mean(v, w_orig, na.rm = TRUE)
      adj_mean  <- stats::weighted.mean(v, w_new,  na.rm = TRUE)
      cat("  Pooled mean of `", value, "`:\n", sep = "")
      cat("    weighted by `", if (is.null(weight)) "(unit)" else weight,
          "`         : ", format(orig_mean, digits = 6), "\n", sep = "")
      cat("    weighted by `", new_weight,
          "` (nestweighted): ", format(adj_mean, digits = 6), "\n", sep = "")
    } else {
      cat("  (`", value, "` is non-numeric (",
          class(v)[1L], "); pooled mean diagnostic skipped.)\n", sep = "")
    }
  }

  data
}
