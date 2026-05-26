# B1 regressions: dw_use("https://...") routes through the remote-URL
# freeze pattern.  The download path is NOT exercised here (testthat
# should not hit the network); we verify the guards instead.

test_that("dw_use refuses HTTPS URLs when allowlist is empty (B1)", {
  local_state(dw_url_allowlist = character(0))
  err <- tryCatch(
    dw_use("https://example.com/data.csv"),
    error = identity
  )
  expect_s3_class(err, "error")
  expect_envelope(err, function_name = "dw_use")
  expect_match(conditionMessage(err), "dw_url_allowlist")
})

test_that("dw_use refuses HTTPS URLs not matching any allowlist pattern (B1)", {
  local_state(dw_url_allowlist = c("^https://allowed\\.example\\.com/"))
  err <- tryCatch(
    dw_use("https://other.example.com/data.csv"),
    error = identity
  )
  expect_s3_class(err, "error")
  expect_envelope(err, function_name = "dw_use")
})

test_that("dw_use refuses to fetch unfrozen URLs in reviewer mode (B1)", {
  tdir <- local_tempdir()
  local_state(
    dw_url_allowlist = c("^https://example\\.com/"),
    dw_mode = "reviewer",
    dw_frozen_root = tdir
  )
  err <- tryCatch(
    dw_use("https://example.com/never-frozen.csv"),
    error = identity
  )
  expect_s3_class(err, "error")
  expect_envelope(err, function_name = "dw_use:remote")
  expect_match(conditionMessage(err), "Reviewer mode forbids fetching")
})

test_that("dw_use reads from frozen cache when the URL is already on disk (B1)", {
  tdir <- local_tempdir()
  local_state(
    dw_url_allowlist = c("^https://example\\.com/"),
    dw_mode = "reviewer",
    dw_frozen_root = tdir
  )
  # Pre-create a frozen file at the path .url_to_frozen_path would
  # produce, plus its CSV content so dw_use can actually read it.
  url <- "https://example.com/frozen-content.csv"
  frozen <- file.path(tdir, "example.com", "frozen-content.csv")
  dir.create(dirname(frozen), recursive = TRUE)
  writeLines(c("a,b", "1,x", "2,y"), con = frozen)

  back <- dw_use(url)
  back <- as.data.frame(back)
  expect_equal(nrow(back), 2)
})
