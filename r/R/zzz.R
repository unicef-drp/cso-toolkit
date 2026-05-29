#-------------------------------------------------------------------
# zzz.R -- package-load housekeeping
#-------------------------------------------------------------------
# Holds the single canonical `.cso_require()` helper (previously
# duplicated and top-level-invoked in aggregate_data_v2.R and
# generate_markdown_report.R, where namespace collision could overwrite
# whichever was sourced last) and the globalVariables declarations
# for dplyr / tidyr NSE column-name references.
#-------------------------------------------------------------------

#' Ensure optional packages are installed (single shared helper)
#'
#' Internal. Used by helpers that depend on dplyr / tidyr / rlang etc.
#' Called from inside the public function bodies (NOT at file-top level)
#' so that vendoring the helper into a 00_functions/ folder does not
#' force the dependency at source-time.
#'
#' @param pkgs Character vector of package names.
#' @param where Character. Caller name for the error message envelope.
#'
#' @return Invisibly, `TRUE`. Stops with the standard envelope if any
#'   package is missing.
#'
#' @keywords internal
#' @noRd
#' @importFrom magrittr %>%
.cso_require <- function(pkgs, where = "<unknown>") {
	for (p in pkgs) {
		if (!requireNamespace(p, quietly = TRUE)) {
			stop(sprintf(
				"[cso_toolkit.%s] Requires the '%s' package but it is not installed.\n  Fix: install.packages('%s')",
				where, p, p
			), call. = FALSE)
		}
	}
	invisible(TRUE)
}

#-------------------------------------------------------------------
# globalVariables declarations
#-------------------------------------------------------------------
# Suppress R CMD check NOTEs of the form
#   "no visible binding for global variable 'XXX'"
# that arise from tidyverse non-standard evaluation (NSE).  These are
# column names referenced inside dplyr / tidyr verbs, not free
# variables.  Declaring them via utils::globalVariables() tells the
# checker so.
#
# Keep this list alphabetised; add a new entry whenever a helper
# introduces a new NSE-referenced column name.
#-------------------------------------------------------------------

# magrittr pipe used in aggregate_data.R and aggregate_data_v2.R
# (which also hosts `apply_time_window()` — there is no separate
# apply_time_window.R file). In the installed-package context the
# pipe is bound via NAMESPACE's `importFrom(magrittr, "%>%")`, which
# is declared on `.cso_require` above. In STANDALONE-SOURCE mode
# (consumers source the .R file directly without first attaching the
# package), each of those files defines a local `%>%` fallback at
# source time (v0.4.5+, #46), gated by `exists()` so the
# installed-package path stays a no-op.

utils::globalVariables(c(
	"%>%",

	# aggregate_data.R
	"Aggregate",
	"Country_Coverage",
	"Pop_Covered",
	"coverage_actual",
	"non_na_count",
	"total_weight",
	"weight_non_na",

	# aggregate_data_v2.R — dotted names mark mutate-created columns
	".coverage_actual",
	".eligible",
	".in_window",
	".is_exempt",
	".non_na_count",
	".num_affected",
	".total_count",
	".total_weight",
	".weight_non_na",
	".year_rank",

	# Used across helpers — referenced via dplyr / tidyr verbs
	"all_of",
	"across",
	"bind_rows",
	"drop_na",
	"dwFunct",            # session-level global; resolved via .try_get()
	"dw_require_no_api",  # set by profile_<repo>.R at source time
	"group_by",
	"mutate",
	"select",
	"setNames",           # stats::setNames is imported elsewhere
	"starts_with",
	"summarise",
	"ungroup"
))
