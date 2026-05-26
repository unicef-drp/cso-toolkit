test_that("cso_toolkit_check returns NULL with missing manifest", {
  local_state(dw_apis_allowed = TRUE, dwFunct = "/nonexistent/path")
  res <- cso_toolkit_check(quiet = TRUE)
  expect_null(res)
})

test_that("cso_toolkit_check returns NULL in reviewer mode (no-API rule)", {
  local_state(dw_apis_allowed = FALSE)
  res <- cso_toolkit_check(quiet = TRUE)
  expect_null(res)
})

test_that("cso_toolkit_diff returns NULL silently with no manifest", {
  local_state(dwFunct = "/nonexistent")
  expect_null(cso_toolkit_diff())
})

test_that("cso_toolkit_pull errors with envelope in reviewer mode", {
  local_state(dw_apis_allowed = FALSE)
  err <- tryCatch(cso_toolkit_pull("v0.4.0"), error = identity)
  expect_s3_class(err, "error")
  expect_envelope(err, function_name = "cso_toolkit_pull")
})

test_that("cso_toolkit_pull errors with envelope on missing manifest", {
  local_state(dw_apis_allowed = TRUE, dwFunct = "/nonexistent/path")
  err <- tryCatch(cso_toolkit_pull("v0.4.0"), error = identity)
  expect_s3_class(err, "error")
  expect_envelope(err, function_name = "cso_toolkit_pull")
})
