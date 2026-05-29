# Tests for v0.4.4 standalone-source resilience of aggregate_data_v2.R
# Issue: https://github.com/unicef-drp/cso-toolkit/issues/36 (sub-fix 1)

test_that(".cso_require is defined after sourcing aggregate_data_v2.R standalone (no zzz.R)", {
  # Source aggregate_data_v2.R into a FRESH environment that has no
  # `.cso_require` defined and no `zzz.R` sourced. Pre-v0.4.4 this
  # left `.cso_require` undefined; calling `aggregate_data_v2(...)`
  # then errored with "could not find function .cso_require".
  env <- new.env(parent = baseenv())
  src <- normalizePath(file.path(testthat::test_path(),
                                 "..", "..", "R", "aggregate_data_v2.R"))
  expect_true(file.exists(src),
              info = paste0("expected source file at: ", src))

  source(src, local = env)

  expect_true(exists(".cso_require", envir = env, inherits = FALSE),
              info = "aggregate_data_v2.R should define .cso_require as a local fallback when sourced standalone")
  expect_type(env$.cso_require, "closure")
})

test_that("the local .cso_require fallback behaves like the zzz.R version (pass + fail)", {
  env <- new.env(parent = baseenv())
  src <- normalizePath(file.path(testthat::test_path(),
                                 "..", "..", "R", "aggregate_data_v2.R"))
  source(src, local = env)

  # Pass: a package that is installed (testthat itself) should not error
  expect_silent(env$.cso_require("testthat", where = "test"))

  # Fail: a clearly-non-existent package should error with the toolkit
  # envelope shape used by the shared zzz.R version
  expect_error(
    env$.cso_require("this_package_does_not_exist_xyz_12345",
                     where = "test"),
    regexp = "Requires the 'this_package_does_not_exist_xyz_12345' package"
  )
})

test_that("when zzz.R is sourced first, aggregate_data_v2.R does NOT overwrite the shared .cso_require", {
  # Source zzz.R then aggregate_data_v2.R into the SAME environment.
  # The local fallback must be a no-op (preserves the shared helper).
  env <- new.env(parent = baseenv())
  zzz <- normalizePath(file.path(testthat::test_path(),
                                 "..", "..", "R", "zzz.R"))
  src <- normalizePath(file.path(testthat::test_path(),
                                 "..", "..", "R", "aggregate_data_v2.R"))
  source(zzz, local = env)

  # Tag the shared helper so we can detect overwrite
  attr(env$.cso_require, ".__shared_zzz_marker__") <- TRUE
  marker_before <- attr(env$.cso_require, ".__shared_zzz_marker__")
  expect_true(isTRUE(marker_before))

  source(src, local = env)

  # The marker should survive the source() of aggregate_data_v2.R
  # (proving the local fallback was a no-op)
  marker_after <- attr(env$.cso_require, ".__shared_zzz_marker__")
  expect_true(isTRUE(marker_after),
              info = "aggregate_data_v2.R should not overwrite the shared .cso_require when it already exists")
})
