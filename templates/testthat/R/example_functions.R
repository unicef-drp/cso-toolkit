# Example project function for the testthat template. Delete this file and
# tests/testthat/test-example-regression.R once your own tests are in place.

#' Attach country names to an indicator table by ISO3 code
#'
#' Every input row comes back, in order, with a `country` column. Codes are
#' normalised (trimmed, upper-cased) before matching; a code that is not in
#' the country list is an error, never a silently dropped row.
#'
#' History: up to the fix for issue #12 this was
#'   merge(indicators, countries, by.x = "REF_AREA", by.y = "iso3")
#' an inner join on the raw codes, so rows coded " ken" or "UGA " matched
#' nothing and disappeared without a warning. The regression test in
#' tests/testthat/test-example-regression.R fails on that version.
merge_country_names <- function(indicators, countries) {
  norm <- function(x) toupper(trimws(x))
  indicators$REF_AREA <- norm(indicators$REF_AREA)
  lookup <- stats::setNames(countries$country, norm(countries$iso3))
  indicators$country <- unname(lookup[indicators$REF_AREA])

  unknown <- unique(indicators$REF_AREA[is.na(indicators$country)])
  if (length(unknown) > 0) {
    stop(sprintf(paste0(
      "[project.merge_country_names] %d REF_AREA code(s) not in the country list: %s\n",
      "  Why: an unmatched row would be published without a country.\n",
      "  Fix: add the code(s) to the country list, or correct REF_AREA upstream."),
      length(unknown), paste(unknown, collapse = ", ")), call. = FALSE)
  }
  indicators
}
