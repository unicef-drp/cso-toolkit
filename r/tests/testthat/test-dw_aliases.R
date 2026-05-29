# Tests for v0.4.4 dw_-prefixed canonical aliases (issue #36 follow-up)

test_that("dw_aggregate_data_v2 is an alias of aggregate_data_v2", {
  expect_true(exists("dw_aggregate_data_v2", mode = "function"))
  expect_identical(dw_aggregate_data_v2, aggregate_data_v2)
})

test_that("dw_create_sector_script is an alias of create_sector_script", {
  expect_true(exists("dw_create_sector_script", mode = "function"))
  expect_identical(dw_create_sector_script, create_sector_script)
})
