# Example tests for R/example_functions.R. The pattern to copy is the
# second test: every bug fix ships the test that would have caught it.

testthat::local_edition(3)

countries <- data.frame(
  iso3    = c("KEN", "UGA", "BFA"),
  country = c("Kenya", "Uganda", "Burkina Faso")
)

test_that("every indicator row comes back with a country name", {
  ind <- read_fixture("indicators_synthetic.csv")
  out <- merge_country_names(ind, countries)

  expect_equal(nrow(out), nrow(ind))
  expect_false(anyNA(out$country))
})

# Regression test for issue #12 (replace with your issue link).
# The bug: codes with stray whitespace or lower case (" ken", "UGA ") matched
# nothing in the join and the rows were dropped without a warning, so the
# Kenya 2021 value vanished from the output. The fixture carries exactly those
# codes; on the pre-fix code this test fails, after the fix it passes.
# Name the issue in the test title so a future failure points to the history.
test_that("regression #12: codes with stray whitespace or lower case are kept", {
  ind <- read_fixture("indicators_synthetic.csv")
  expect_true(any(ind$REF_AREA != trimws(toupper(ind$REF_AREA))))  # the fixture still has the bad codes

  out <- merge_country_names(ind, countries)

  expect_setequal(out$TIME_PERIOD[out$country == "Kenya"], c(2021, 2022))
  expect_true(all(out$REF_AREA %in% countries$iso3))
})

test_that("an unknown code fails loudly with a WHAT / Why / Fix error", {
  ind <- data.frame(REF_AREA = "XXX", INDICATOR = "ED_CR_L1",
                    TIME_PERIOD = 2022, OBS_VALUE = 0.5)

  err <- expect_error(merge_country_names(ind, countries))
  expect_envelope(err, "merge_country_names")
})

test_that("the suite runs in reviewer mode (no network, no canonical writes)", {
  expect_identical(get("dw_mode", envir = globalenv()), "reviewer")
  expect_false(isTRUE(get("dw_apis_allowed", envir = globalenv())))
})
