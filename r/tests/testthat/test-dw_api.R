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
  # The toolkit's own lockout envelope, with or without a profile (#190):
  # it used to call a profile-only dw_require_no_api() with arguments the
  # profile's version does not take.
  expect_envelope(err, function_name = "dw_api")
  expect_match(conditionMessage(err), "Reviewer mode forbids live API calls")
  # A profile's dw_require_no_api(context = NULL) is not called any more.
  assign("dw_require_no_api", function(context = NULL) stop("profile version"),
         envir = .GlobalEnv)
  withr::defer(rm("dw_require_no_api", envir = .GlobalEnv))
  err <- tryCatch(dw_api_fetch(api = "uis", cache_key = "never_cached"), error = identity)
  expect_match(conditionMessage(err), "Reviewer mode forbids live API calls")
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
  expect_equal(default_ext("csv"),           "csv")
})

# csv api (DW cross-sector need: SDMX REST-CSV / Data360 / ILOSTAT rplumber)
test_that("dw_api_fetch dispatches api='csv' rather than rejecting it", {
  local_state(
    teamsRawData          = "/tmp/raw",
    teamsRawDataCanonical = "/tmp/raw-can",
    dw_apis_allowed       = TRUE
  )
  err <- tryCatch(
    dw_api_fetch(api = "csv", cache_key = "csv_dispatch_probe",
                 url = "/tmp/no-such-cso-toolkit-test-file.csv"),
    error = identity
  )
  expect_s3_class(err, "error")
  # 'csv' is now a recognized api: it reaches .api_fetch_csv and fails at the
  # read, NOT at the unsupported-api guard.
  expect_false(grepl("Unsupported api", conditionMessage(err)))
})

test_that(".api_fetch_csv parses a CSV source into a data frame", {
  # Positive contract test (PR #128 review): the dispatch probe above only proves
  # 'csv' is wired into the switch; this proves the fetcher actually parses a CSV
  # source, so a broken .api_fetch_csv cannot pass silently.
  fetch_csv <- get(".api_fetch_csv", envir = asNamespace("csotoolkit"))
  tmp <- tempfile(fileext = ".csv")
  on.exit(unlink(tmp), add = TRUE)
  writeLines(c("a,b", "1,x", "2,y"), tmp)
  out <- fetch_csv(tmp)
  expect_s3_class(out, "data.frame")
  expect_equal(nrow(out), 2L)
  expect_equal(names(out), c("a", "b"))
  expect_equal(out$a, c(1, 2))
})

test_that("dw_api_fetch(refresh = TRUE) replaces an existing cache in producer mode", {
  # Before the fix, the refresh reached dw_save() with overwrite = NULL
  # (FALSE in producer mode) and stopped at the overwrite gate, so the
  # documented refresh never replaced an existing cache.
  raw <- local_tempdir()
  local_state(teamsRawData = raw, teamsRawDataCanonical = raw,
              teamsWrkDataCanonical = raw, dw_mode = "producer",
              dw_apis_allowed = TRUE)
  src <- file.path(local_tempdir(), "src.csv")
  writeLines(c("a,b", "1,x"), src)
  suppressMessages(dw_api_fetch("csv", cache_key = "k", url = src))
  writeLines(c("a,b", "2,y"), src)
  # Without refresh the existing cache is a hit: never replaced.
  hit <- suppressMessages(dw_api_fetch("csv", cache_key = "k", url = src))
  expect_equal(hit$a, 1)
  out <- suppressMessages(dw_api_fetch("csv", cache_key = "k", url = src, refresh = TRUE))
  expect_equal(out$a, 2)
  prov <- dw_read_provenance(file.path(raw, "_apis", "csv", "k.csv"), verbose = FALSE)
  expect_true(isTRUE(prov$metadata$refresh_flag))
})
