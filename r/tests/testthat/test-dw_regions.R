# Regression tests for dw_regions() (#18).
#
# Strategy: drop fixture CSVs at the cache paths for both the WB
# population fetch and the GitHub-raw region taxonomy, then exercise
# the merge / aggregate / concatenate pipeline without hitting the
# network.

.dw_regions_pop_fixture <- function() {
  data.frame(
    iso3c    = c("BFA", "MLI", "NER", "TCD", "SEN"),
    country  = c("Burkina Faso", "Mali", "Niger", "Chad", "Senegal"),
    date     = rep(2023, 5),
    value    = c(23e6, 23e6, 27e6, 18e6, 17e6),
    stringsAsFactors = FALSE
  )
}

.dw_regions_taxonomy_fixture <- function() {
  data.frame(
    REF_AREA = c("BFA", "MLI", "NER", "TCD", "SEN", "AGO", "MOZ"),
    REGION   = c("WCA", "WCA", "WCA", "ESA", "WCA", "ESA", "ESA"),
    stringsAsFactors = FALSE
  )
}

.dw_regions_seed_caches <- function(root) {
  # WB population cache
  wb_dir <- file.path(root, "_apis", "wb")
  dir.create(wb_dir, recursive = TRUE)
  write.csv(.dw_regions_pop_fixture(),
            file = file.path(wb_dir, "wb_population_sp_pop_totl.csv"),
            row.names = FALSE)

  # github_raw default extension is rds, so saveRDS at the rds cache path
  gh_dir <- file.path(root, "_apis", "github_raw")
  dir.create(gh_dir, recursive = TRUE)
  saveRDS(.dw_regions_taxonomy_fixture(),
          file = file.path(gh_dir, "regions_unicef_rep_reg_global.rds"))
}

test_that("dw_regions appends regional aggregate rows to country-level input", {
  d <- local_tempdir()
  .dw_regions_seed_caches(d)
  local_state(teamsRawData = d, teamsRawDataCanonical = d,
              dw_apis_allowed = FALSE)

  national <- data.frame(
    REF_AREA    = c("BFA", "MLI", "NER", "TCD", "SEN"),
    INDICATOR   = rep("MyInd", 5),
    TIME_PERIOD = rep(2023, 5),
    OBS_VALUE   = c(0.50, 0.45, 0.60, 0.30, 0.55),
    stringsAsFactors = FALSE
  )
  out <- dw_regions(national, value = "OBS_VALUE")

  expect_s3_class(out, "data.frame")
  expect_true(nrow(out) > nrow(national))
  # Two regions in the fixture: WCA + ESA
  region_rows <- out[out$REF_AREA %in% c("WCA", "ESA"), , drop = FALSE]
  expect_equal(nrow(region_rows), 2L)
  # Aggregates should be in [0, 1] (we passed proportions)
  expect_true(all(!is.na(region_rows$Aggregate)))
  expect_true(all(region_rows$Aggregate >= 0 & region_rows$Aggregate <= 1))
})

test_that("dw_regions errors when value column is missing", {
  d <- local_tempdir()
  .dw_regions_seed_caches(d)
  local_state(teamsRawData = d, teamsRawDataCanonical = d,
              dw_apis_allowed = FALSE)

  bad <- data.frame(
    REF_AREA  = c("BFA", "MLI"),
    INDICATOR = c("A", "B"),
    stringsAsFactors = FALSE
  )
  err <- tryCatch(
    dw_regions(bad, value = "OBS_VALUE"),
    error = identity
  )
  expect_s3_class(err, "error")
  expect_envelope(err, function_name = "dw_regions")
  expect_match(conditionMessage(err), "OBS_VALUE")
})

test_that("dw_regions warns when a country code is missing from the taxonomy", {
  d <- local_tempdir()
  .dw_regions_seed_caches(d)
  local_state(teamsRawData = d, teamsRawDataCanonical = d,
              dw_apis_allowed = FALSE)

  national <- data.frame(
    REF_AREA    = c("BFA", "XXX"),   # XXX not in taxonomy
    INDICATOR   = rep("MyInd", 2),
    TIME_PERIOD = rep(2023, 2),
    OBS_VALUE   = c(0.50, 0.10),
    stringsAsFactors = FALSE
  )
  expect_warning(
    out <- dw_regions(national, value = "OBS_VALUE"),
    regexp = "taxonomy"
  )
  # XXX still appears as a country row in the input echo
  expect_true("XXX" %in% out$REF_AREA)
})

test_that("dw_regions accepts a sector-specific weight column", {
  d <- local_tempdir()
  .dw_regions_seed_caches(d)
  local_state(teamsRawData = d, teamsRawDataCanonical = d,
              dw_apis_allowed = FALSE)

  national <- data.frame(
    REF_AREA       = c("BFA", "MLI", "NER", "TCD", "SEN"),
    INDICATOR      = rep("MyInd", 5),
    TIME_PERIOD    = rep(2023, 5),
    OBS_VALUE      = c(0.50, 0.45, 0.60, 0.30, 0.55),
    births_under5  = c(1.0e6, 0.9e6, 1.1e6, 0.6e6, 0.5e6),
    stringsAsFactors = FALSE
  )
  out <- dw_regions(national, value = "OBS_VALUE",
                    weight = "births_under5")
  region_rows <- out[out$REF_AREA %in% c("WCA", "ESA"), , drop = FALSE]
  expect_equal(nrow(region_rows), 2L)
})

test_that("dw_regions errors on an unknown weight column name", {
  d <- local_tempdir()
  .dw_regions_seed_caches(d)
  local_state(teamsRawData = d, teamsRawDataCanonical = d,
              dw_apis_allowed = FALSE)

  national <- data.frame(
    REF_AREA    = c("BFA", "MLI"),
    INDICATOR   = c("A", "A"),
    TIME_PERIOD = c(2023, 2023),
    OBS_VALUE   = c(0.5, 0.5),
    stringsAsFactors = FALSE
  )
  err <- tryCatch(
    dw_regions(national, value = "OBS_VALUE", weight = "no_such_column"),
    error = identity
  )
  expect_s3_class(err, "error")
  expect_envelope(err, function_name = "dw_regions")
  expect_match(conditionMessage(err), "no_such_column")
})

test_that("dw_regions reviewer-mode with empty caches raises the envelope", {
  d <- local_tempdir()
  # NO seeding -- caches are missing on purpose.
  local_state(teamsRawData = d, teamsRawDataCanonical = d,
              dw_apis_allowed = FALSE,
              dw_mode = "reviewer")

  national <- data.frame(
    REF_AREA    = c("BFA"),
    INDICATOR   = c("A"),
    TIME_PERIOD = c(2023),
    OBS_VALUE   = c(0.5),
    stringsAsFactors = FALSE
  )
  err <- tryCatch(
    dw_regions(national, value = "OBS_VALUE"),
    error = identity
  )
  expect_s3_class(err, "error")
})
