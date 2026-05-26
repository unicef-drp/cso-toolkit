test_that("dw_isid passes on unique keys", {
  df <- data.frame(REF_AREA = c("AGO", "BFA", "CIV"), value = c(1, 2, 3))
  expect_true(dw_isid(df, keys = "REF_AREA"))
})

test_that("dw_isid passes silently on empty data frame", {
  df <- data.frame(REF_AREA = character(0), value = numeric(0))
  expect_true(dw_isid(df, keys = "REF_AREA"))
})

test_that("dw_isid passes on composite keys", {
  df <- data.frame(
    REF_AREA = c("AGO", "AGO", "BFA"),
    SEX      = c("F",   "M",   "F"),
    value    = c(1, 2, 3)
  )
  expect_true(dw_isid(df, keys = c("REF_AREA", "SEX")))
})

test_that("dw_isid errors on duplicate rows with the standard envelope", {
  df <- data.frame(REF_AREA = c("AGO", "AGO", "BFA"), value = c(1, 1, 2))
  err <- tryCatch(dw_isid(df, keys = "REF_AREA", where = "test"),
                  error = identity)
  expect_s3_class(err, "error")
  expect_envelope(err, function_name = "dw_isid")
  expect_match(conditionMessage(err), "duplicate row")
})

test_that("dw_isid errors when keys are missing from data", {
  df <- data.frame(a = 1:3, b = 4:6)
  err <- tryCatch(dw_isid(df, keys = "missing_col", where = "test"),
                  error = identity)
  expect_s3_class(err, "error")
  expect_envelope(err, function_name = "dw_isid")
  expect_match(conditionMessage(err), "missing_col")
})
