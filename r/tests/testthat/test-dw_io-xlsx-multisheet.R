# Read-all-sheets: dw_use(sheet = NULL) returns a named list of frames, one
# per sheet, while the default sheet = 1 keeps the single-sheet behaviour.

test_that("dw_use(sheet = NULL) reads every sheet into a named list", {
  skip_if_not_installed("writexl")
  skip_if_not_installed("readxl")
  local_state()
  tdir <- local_tempdir()
  path <- file.path(tdir, "multi.xlsx")
  writexl::write_xlsx(
    list(
      alpha = data.frame(k = c("a", "b"), v = c(1, 2), stringsAsFactors = FALSE),
      beta  = data.frame(k = "c",          v = 3,        stringsAsFactors = FALSE)
    ),
    path = path
  )

  all_sheets <- dw_use(path = path, sheet = NULL, as = "data.frame")

  expect_type(all_sheets, "list")
  expect_false(is.data.frame(all_sheets))
  expect_named(all_sheets, c("alpha", "beta"))
  expect_s3_class(all_sheets$alpha, "data.frame")
  expect_equal(nrow(all_sheets$alpha), 2)
  expect_equal(nrow(all_sheets$beta), 1)
})

test_that("dw_use default (sheet = 1) still reads only the first sheet", {
  skip_if_not_installed("writexl")
  skip_if_not_installed("readxl")
  local_state()
  tdir <- local_tempdir()
  path <- file.path(tdir, "multi.xlsx")
  writexl::write_xlsx(
    list(
      alpha = data.frame(k = c("a", "b"), v = c(1, 2), stringsAsFactors = FALSE),
      beta  = data.frame(k = "c",          v = 3,        stringsAsFactors = FALSE)
    ),
    path = path
  )

  one <- dw_use(path = path, as = "data.frame")

  expect_s3_class(one, "data.frame")
  expect_equal(nrow(one), 2)  # first sheet (alpha) only
})
