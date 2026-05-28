# Tests for v0.4.3 dw_use cols behaviour:
#   - Issue #30: parquet / dta `col_select = NULL` conditional dispatch
#   - Issue #31: new `cols_lenient = FALSE` flag (any_of()-style intersect)
# Surfaced empirically by the DW-Production NT reviewer-mode audit
# 2026-05-27.

test_that("dw_use(parquet) without cols returns ALL columns (issue #30)", {
  skip_if_not_installed("arrow")
  tdir <- local_tempdir()
  local_state(teamsWrkData = tdir)

  df <- data.frame(
    REF_AREA = c("AGO", "BFA"),
    INDICATOR = c("X", "Y"),
    OBS_VALUE = c(0.5, 0.7),
    stringsAsFactors = FALSE
  )
  path <- file.path(tdir, "test_all_cols.parquet")
  arrow::write_parquet(df, sink = path)

  back <- dw_use(path)
  expect_equal(ncol(back), 3L)
  expect_setequal(names(back), c("REF_AREA", "INDICATOR", "OBS_VALUE"))
  expect_equal(nrow(back), 2L)
})

test_that("dw_use(dta) without cols returns ALL columns (issue #30)", {
  skip_if_not_installed("haven")
  tdir <- local_tempdir()
  local_state(teamsWrkData = tdir)

  df <- data.frame(
    REF_AREA = c("AGO", "BFA"),
    INDICATOR = c("X", "Y"),
    OBS_VALUE = c(0.5, 0.7),
    stringsAsFactors = FALSE
  )
  path <- file.path(tdir, "test_all_cols.dta")
  haven::write_dta(df, path = path)

  back <- dw_use(path)
  expect_equal(ncol(back), 3L)
  expect_setequal(names(back), c("REF_AREA", "INDICATOR", "OBS_VALUE"))
})

test_that("dw_use(parquet, cols = c(...)) still respects explicit selection", {
  skip_if_not_installed("arrow")
  tdir <- local_tempdir()
  local_state(teamsWrkData = tdir)

  df <- data.frame(a = 1:3, b = 4:6, c = 7:9)
  path <- file.path(tdir, "explicit_cols.parquet")
  arrow::write_parquet(df, sink = path)

  back <- dw_use(path, cols = c("a", "c"))
  expect_setequal(names(back), c("a", "c"))
})

test_that("dw_use(cols_lenient = TRUE) intersects with parquet schema (issue #31)", {
  skip_if_not_installed("arrow")
  tdir <- local_tempdir()
  local_state(teamsWrkData = tdir)

  df <- data.frame(a = 1:3, b = 4:6, c = 7:9)
  path <- file.path(tdir, "lenient_parquet.parquet")
  arrow::write_parquet(df, sink = path)

  back <- dw_use(
    path,
    cols = c("a", "MISSING_FROM_SCHEMA", "c", "ALSO_MISSING"),
    cols_lenient = TRUE
  )
  expect_setequal(names(back), c("a", "c"))
})

test_that("dw_use(cols_lenient = TRUE) intersects with csv schema (issue #31)", {
  tdir <- local_tempdir()
  local_state(teamsWrkData = tdir)

  df <- data.frame(a = 1:3, b = 4:6, c = 7:9)
  path <- file.path(tdir, "lenient.csv")
  data.table::fwrite(df, file = path)

  back <- dw_use(
    path,
    cols = c("a", "MISSING_FROM_SCHEMA", "c", "ALSO_MISSING"),
    cols_lenient = TRUE
  )
  expect_setequal(names(back), c("a", "c"))
})

test_that("dw_use(cols_lenient = TRUE) with empty intersection warns and reads all", {
  skip_if_not_installed("arrow")
  tdir <- local_tempdir()
  local_state(teamsWrkData = tdir)

  df <- data.frame(a = 1:3, b = 4:6)
  path <- file.path(tdir, "no_match.parquet")
  arrow::write_parquet(df, sink = path)

  expect_warning(
    back <- dw_use(
      path,
      cols = c("ZZZ", "QQQ"),
      cols_lenient = TRUE
    ),
    "cols_lenient = TRUE: none of the requested cols matched"
  )
  expect_setequal(names(back), c("a", "b"))
})

test_that("dw_use(cols_lenient = FALSE, default) preserves strict semantics", {
  skip_if_not_installed("arrow")
  tdir <- local_tempdir()
  local_state(teamsWrkData = tdir)

  df <- data.frame(a = 1:3, b = 4:6)
  path <- file.path(tdir, "strict.parquet")
  arrow::write_parquet(df, sink = path)

  # Strict mode: requesting a missing col should error (arrow's job)
  expect_error(
    dw_use(path, cols = c("a", "MISSING")),
    NULL  # arrow error message varies; just confirm it errors
  )
})
