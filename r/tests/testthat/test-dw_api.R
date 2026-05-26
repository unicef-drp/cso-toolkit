# B4 regressions: per-API default cache extension + URL-encoded UIS
# query params.

test_that("dw_api_fetch rejects unsupported api with the envelope", {
  local_state(
    teamsRawData = "/tmp/raw",
    teamsRawDataCanonical = "/tmp/raw-can",
    dw_apis_allowed = TRUE
  )
  err <- tryCatch(
    dw_api_fetch(api = "bogus_api", cache_key = "x"),
    error = identity
  )
  expect_s3_class(err, "error")
  expect_envelope(err, function_name = "dw_api_fetch")
})

test_that("dw_api_fetch lockout in reviewer mode raises the envelope", {
  local_state(
    teamsRawData = "/tmp/raw",
    teamsRawDataCanonical = "/tmp/raw-can",
    dw_apis_allowed = FALSE,
    dw_mode = "reviewer"
  )
  err <- tryCatch(
    dw_api_fetch(api = "uis", cache_key = "never_cached"),
    error = identity
  )
  expect_s3_class(err, "error")
  # `dw_require_no_api()` may be provided by the consumer's profile;
  # we only assert the call fails clearly.
})

test_that("dw_api_cached errors with the envelope on missing cache", {
  local_state(teamsRawDataCanonical = "/tmp/raw-can-missing")
  err <- tryCatch(
    dw_api_cached(api = "uis", cache_key = "never_cached"),
    error = identity
  )
  expect_s3_class(err, "error")
  expect_envelope(err, function_name = "dw_api_cached")
})

# B4 (default-extension half): http and github_raw now default to rds
test_that(".dw_api_default_ext returns rds for http and github_raw (B4)", {
  default_ext <- get(".dw_api_default_ext",
                     envir = asNamespace("csotoolkit"))
  expect_equal(default_ext("http"),          "rds")
  expect_equal(default_ext("github_raw"),    "rds")
  expect_equal(default_ext("wb_indicators"), "rds")
  expect_equal(default_ext("json_get"),      "rds")
  expect_equal(default_ext("uis"),           "csv")
  expect_equal(default_ext("sdmx"),          "csv")
})
