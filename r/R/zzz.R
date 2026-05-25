#-------------------------------------------------------------------
# zzz.R — globalVariables declarations
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

utils::globalVariables(c(
	# magrittr pipe used in aggregate_data.R / aggregate_data_v2.R /
	# apply_time_window.R (these files attach magrittr via .cso_require()
	# at source-time; CRAN's static analyser cannot see that).
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
