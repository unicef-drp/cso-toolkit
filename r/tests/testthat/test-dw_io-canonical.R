test_that("dw_is_canonical returns FALSE when no canonical roots are set", {
  local_state()
  expect_false(dw_is_canonical("/data/wrk/ed/x.csv"))
})

test_that("dw_is_canonical returns TRUE for path equal to canonical root", {
  local_state(teamsWrkDataCanonical = "/data/wrk-can")
  expect_true(dw_is_canonical("/data/wrk-can"))
})

test_that("dw_is_canonical returns TRUE for descendants of canonical roots", {
  local_state(
    teamsWrkDataCanonical = "/data/wrk-can",
    teamsRawDataCanonical = "/data/raw-can"
  )
  expect_true(dw_is_canonical("/data/wrk-can/ed/x.csv"))
  expect_true(dw_is_canonical("/data/raw-can/ed/x.csv"))
})

# REGRESSION: a previous version used a plain `startsWith` check, which
# made siblings of a canonical root spoof a match (e.g. `/data/wrk-canary`
# would match against root `/data/wrk-can`).  This test pins the fix.
test_that("dw_is_canonical rejects sibling-prefix paths (regression)", {
  local_state(teamsWrkDataCanonical = "/data/wrk-can")
  expect_false(dw_is_canonical("/data/wrk-canary/ed/x.csv"))
  expect_false(dw_is_canonical("/data/wrk-canopen"))
  expect_false(dw_is_canonical("/data/wrk-canary"))
})

test_that("dw_is_canonical handles trailing slashes on canonical roots", {
  local_state(teamsWrkDataCanonical = "/data/wrk-can/")
  expect_true(dw_is_canonical("/data/wrk-can/ed/x.csv"))
  expect_false(dw_is_canonical("/data/wrk-canary/ed/x.csv"))
})

# The Z: drive is an exact carbon-copy mirror of the Teams canonical deposit,
# so a path under `dwZDrive` is treated as canonical too (reviewer reads of an
# explicit Z: path short-circuit + run the Z: integrity check).
test_that("dw_is_canonical recognises the dwZDrive (Z:) mirror root", {
  local_state(dwZDrive = "/data/zmirror/060.DW-MASTER")
  expect_true(dw_is_canonical("/data/zmirror/060.DW-MASTER"))
  expect_true(dw_is_canonical("/data/zmirror/060.DW-MASTER/ed/x.csv"))
  expect_false(dw_is_canonical("/data/zmirror/060.DW-MASTER-other/x.csv"))
})
