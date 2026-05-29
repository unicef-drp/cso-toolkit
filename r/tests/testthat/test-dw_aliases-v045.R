# Tests for v0.4.5 dw_-prefixed canonical aliases (issue #42)
# These mirror the v0.4.4 pattern from test-dw_aliases.R, applied to
# the remaining 8 un-prefixed exports.

test_that("dw_aggregate_data is an alias of aggregate_data", {
  expect_true(exists("dw_aggregate_data", mode = "function"))
  expect_identical(dw_aggregate_data, aggregate_data)
})

test_that("dw_generate_agg_footnote is an alias of generate_agg_footnote", {
  expect_true(exists("dw_generate_agg_footnote", mode = "function"))
  expect_identical(dw_generate_agg_footnote, generate_agg_footnote)
})

test_that("dw_apply_time_window is an alias of apply_time_window", {
  expect_true(exists("dw_apply_time_window", mode = "function"))
  expect_identical(dw_apply_time_window, apply_time_window)
})

test_that("dw_generate_markdown_report is an alias of generate_markdown_report", {
  expect_true(exists("dw_generate_markdown_report", mode = "function"))
  expect_identical(dw_generate_markdown_report, generate_markdown_report)
})

test_that("dw_process_all_csv_files is an alias of process_all_csv_files", {
  expect_true(exists("dw_process_all_csv_files", mode = "function"))
  expect_identical(dw_process_all_csv_files, process_all_csv_files)
})

test_that("dw_create_profile is an alias of create_profile", {
  expect_true(exists("dw_create_profile", mode = "function"))
  expect_identical(dw_create_profile, create_profile)
})

test_that("dw_review_profile is an alias of review_profile", {
  expect_true(exists("dw_review_profile", mode = "function"))
  expect_identical(dw_review_profile, review_profile)
})

test_that("dw_test_scripts is an alias of test_scripts", {
  expect_true(exists("dw_test_scripts", mode = "function"))
  expect_identical(dw_test_scripts, test_scripts)
})
