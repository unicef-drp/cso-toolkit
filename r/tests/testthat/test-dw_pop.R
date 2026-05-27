# Regression tests for dw_pop() (#17).
#
# Strategy: drop a fixture CSV at the cache path the helper looks up,
# then exercise the latest-year, year-filter, and country-filter branches
# without hitting the network.

.dw_pop_fixture <- function() {
  # Three countries x three years, with one missing-row case so the
  # complete-case filter is exercised.
  data.frame(
    iso3c        = c("BFA", "BFA", "BFA",
                     "MLI", "MLI", "MLI",
                     "NER", "NER", "NER",
                     "XXX"),
    country      = c("Burkina Faso", "Burkina Faso", "Burkina Faso",
                     "Mali", "Mali", "Mali",
                     "Niger", "Niger", "Niger",
                     "Bogus"),
    date         = c(2021, 2022, 2023,
                     2021, 2022, 2023,
                     2021, 2022, 2023,
                     2023),
    value        = c(22.1e6, 22.6e6, 23.2e6,
                     21.9e6, 22.6e6, 23.3e6,
                     25.1e6, 26.2e6, 27.2e6,
                     NA),
    stringsAsFactors = FALSE
  )
}

test_that("dw_pop returns latest year per country by default", {
  d <- local_tempdir()
  cache_dir <- file.path(d, "_apis", "wb")
  dir.create(cache_dir, recursive = TRUE)
  write.csv(.dw_pop_fixture(),
            file = file.path(cache_dir, "wb_population_sp_pop_totl.csv"),
            row.names = FALSE)
  local_state(teamsRawData = d, teamsRawDataCanonical = d,
              dw_apis_allowed = FALSE)

  out <- dw_pop()
  expect_s3_class(out, "data.frame")
  expect_equal(names(out), c("REF_AREA", "TIME_PERIOD", "OBS_VALUE"))
  # Three countries with valid rows; bogus XXX has NA OBS_VALUE -> dropped
  expect_equal(nrow(out), 3L)
  # Every row should be from 2023 (latest)
  expect_true(all(out$TIME_PERIOD == 2023L))
  expect_setequal(out$REF_AREA, c("BFA", "MLI", "NER"))
})

test_that("dw_pop with year=2022 returns one year per country", {
  d <- local_tempdir()
  cache_dir <- file.path(d, "_apis", "wb")
  dir.create(cache_dir, recursive = TRUE)
  write.csv(.dw_pop_fixture(),
            file = file.path(cache_dir, "wb_population_sp_pop_totl.csv"),
            row.names = FALSE)
  local_state(teamsRawData = d, teamsRawDataCanonical = d,
              dw_apis_allowed = FALSE)

  out <- dw_pop(year = 2022)
  expect_equal(nrow(out), 3L)
  expect_true(all(out$TIME_PERIOD == 2022L))
})

test_that("dw_pop with countries filter returns only the named ISO3 codes", {
  d <- local_tempdir()
  cache_dir <- file.path(d, "_apis", "wb")
  dir.create(cache_dir, recursive = TRUE)
  write.csv(.dw_pop_fixture(),
            file = file.path(cache_dir, "wb_population_sp_pop_totl.csv"),
            row.names = FALSE)
  local_state(teamsRawData = d, teamsRawDataCanonical = d,
              dw_apis_allowed = FALSE)

  out <- dw_pop(countries = c("BFA", "MLI"))
  expect_setequal(out$REF_AREA, c("BFA", "MLI"))
})

test_that("dw_pop reviewer-mode with empty cache raises the envelope", {
  d <- local_tempdir()
  local_state(teamsRawData = d, teamsRawDataCanonical = d,
              dw_apis_allowed = FALSE,
              dw_mode = "reviewer")

  err <- tryCatch(
    dw_pop(cache_key = "never_cached_pop_key"),
    error = identity
  )
  expect_s3_class(err, "error")
  # `dw_require_no_api()` raises the envelope; we only assert that the
  # call fails clearly.  The exact prefix depends on the consumer's
  # profile setup.
})

test_that("dw_pop sorts output by REF_AREA + TIME_PERIOD ascending", {
  d <- local_tempdir()
  cache_dir <- file.path(d, "_apis", "wb")
  dir.create(cache_dir, recursive = TRUE)
  write.csv(.dw_pop_fixture(),
            file = file.path(cache_dir, "wb_population_sp_pop_totl.csv"),
            row.names = FALSE)
  local_state(teamsRawData = d, teamsRawDataCanonical = d,
              dw_apis_allowed = FALSE)

  out <- dw_pop(year = c(2021, 2022, 2023))
  # 3 countries x 3 years = 9 rows
  expect_equal(nrow(out), 9L)
  expect_equal(out$REF_AREA, sort(out$REF_AREA))
})
