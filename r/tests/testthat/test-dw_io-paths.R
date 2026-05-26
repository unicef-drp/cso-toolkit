test_that("dw_resolve_path resolves structured name + sector + kind", {
  local_state(teamsWrkData = "/data/wrk")
  expect_equal(
    dw_resolve_path(name = "x.csv", sector = "ed", kind = "wrk"),
    "/data/wrk/ed/x.csv"
  )
})

test_that("dw_resolve_path resolves with vintage subfolder", {
  local_state(teamsWrkData = "/data/wrk")
  expect_equal(
    dw_resolve_path(name = "x.csv", sector = "ed", vintage = "2026-05", kind = "wrk"),
    "/data/wrk/ed/2026-05/x.csv"
  )
})

test_that("dw_resolve_path accepts a literal subpath via `path =`", {
  local_state(teamsWrkData = "/data/wrk")
  expect_equal(
    dw_resolve_path(path = "ed/x.csv", kind = "wrk"),
    "/data/wrk/ed/x.csv"
  )
})

test_that("dw_resolve_path collapses repeated slashes", {
  local_state(teamsWrkData = "/data/wrk")
  out <- dw_resolve_path(name = "x.csv", sector = "ed", kind = "wrk")
  expect_false(grepl("//", out, fixed = TRUE))
})

test_that("dw_resolve_path errors when teamsWrkData is unset", {
  # Explicitly do NOT set teamsWrkData
  local_state()
  err <- tryCatch(
    dw_resolve_path(name = "x.csv", sector = "ed", kind = "wrk"),
    error = identity
  )
  expect_s3_class(err, "error")
  expect_envelope(err, function_name = "dw_resolve_path")
  expect_match(conditionMessage(err), "teamsWrkData", fixed = TRUE)
})

test_that("dw_resolve_path errors when neither path nor name supplied", {
  local_state(teamsWrkData = "/data/wrk")
  err <- tryCatch(dw_resolve_path(kind = "wrk"), error = identity)
  expect_s3_class(err, "error")
  expect_envelope(err, function_name = "dw_resolve_path")
})

test_that("dw_resolve_path errors on unsupported kind", {
  local_state(teamsWrkData = "/data/wrk")
  # match.arg() handles this — message comes from base R, not our envelope,
  # so we only assert the error fires.  The kind="bogus" path is rejected
  # before our custom error has a chance to fire.
  expect_error(
    dw_resolve_path(name = "x.csv", kind = "bogus"),
    "should be one of"
  )
})
