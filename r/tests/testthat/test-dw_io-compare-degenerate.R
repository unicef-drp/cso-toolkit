# dw_compare degenerate-case handling: warn (don't crash / don't silently
# report a mass delta) when a side is empty or the reference is absent.

test_that("dw_compare warns and reports all-added when reference is empty", {
  local_state()
  cur <- data.frame(REF_AREA = c("AGO", "BFA"), OBS_VALUE = c(1, 2),
                    stringsAsFactors = FALSE)
  ref <- cur[0, , drop = FALSE]
  expect_warning(
    res <- dw_compare(cur, ref, by = "REF_AREA"),
    "reference.*empty"
  )
  expect_equal(res$summary$added, 2)
  expect_equal(res$summary$removed, 0)
})

test_that("dw_compare warns and reports all-removed when current is empty", {
  local_state()
  ref <- data.frame(REF_AREA = c("AGO", "BFA"), OBS_VALUE = c(1, 2),
                    stringsAsFactors = FALSE)
  cur <- ref[0, , drop = FALSE]
  expect_warning(
    res <- dw_compare(cur, ref, by = "REF_AREA"),
    "current.*empty"
  )
  expect_equal(res$summary$added, 0)
  expect_equal(res$summary$removed, 2)
})

test_that("dw_compare treats a missing reference path as a first deposit", {
  local_state()
  cur <- data.frame(REF_AREA = c("AGO", "BFA"), OBS_VALUE = c(1, 2),
                    stringsAsFactors = FALSE)
  missing_ref <- file.path(local_tempdir(), "no_such_reference.csv")
  expect_warning(
    res <- dw_compare(cur, missing_ref, by = "REF_AREA"),
    "first deposit|not found|empty"
  )
  expect_equal(res$summary$added, 2)
  expect_equal(res$summary$removed, 0)
})

test_that("dw_compare does not warn on a normal non-empty comparison", {
  local_state()
  cur <- data.frame(REF_AREA = c("AGO", "BFA"), OBS_VALUE = c(1, 2),
                    stringsAsFactors = FALSE)
  ref <- data.frame(REF_AREA = c("AGO", "BFA"), OBS_VALUE = c(1, 9),
                    stringsAsFactors = FALSE)
  expect_no_warning(
    res <- dw_compare(cur, ref, by = "REF_AREA",
                      numeric_value_cols = "OBS_VALUE")
  )
  expect_equal(res$summary$changed, 1)
})

test_that("dw_compare stops when both sides are empty/NULL", {
  local_state()
  err <- tryCatch(dw_compare(NULL, NULL, by = "REF_AREA"), error = identity)
  expect_s3_class(err, "error")
})
