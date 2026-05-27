# B2 regression: dw_save's compression block now auto-detects gzip
# when the path already ends in `.gz`.  Previously
# `dw_save(df, path = "...csv.gz", compress = FALSE)` silently wrote
# the file UNCOMPRESSED under the misleading name.

test_that("dw_save auto-enables compression when path ends in .gz (B2)", {
  tdir <- local_tempdir()
  local_state(teamsWrkData = tdir)
  df <- data.frame(a = 1:5, b = letters[1:5], stringsAsFactors = FALSE)
  out <- dw_save(df, path = file.path(tdir, "auto.csv.gz"))
  expect_true(file.exists(out))

  # Open the first two bytes and check the gzip magic number (0x1F 0x8B).
  con <- file(out, "rb")
  on.exit(close(con), add = TRUE)
  magic <- readBin(con, what = "raw", n = 2L)
  expect_equal(magic[1], as.raw(0x1F))
  expect_equal(magic[2], as.raw(0x8B))
})

test_that("dw_save with compress = TRUE appends .gz when missing", {
  tdir <- local_tempdir()
  local_state(teamsWrkData = tdir)
  df <- data.frame(a = 1:3)
  out <- dw_save(df, path = file.path(tdir, "appended.csv"), compress = TRUE)
  expect_true(endsWith(out, ".csv.gz"))
  expect_true(file.exists(out))
})

test_that("dw_save without compress + plain .csv stays uncompressed", {
  tdir <- local_tempdir()
  local_state(teamsWrkData = tdir)
  df <- data.frame(a = 1:3)
  out <- dw_save(df, path = file.path(tdir, "plain.csv"))
  expect_true(file.exists(out))
  # First three chars should be ASCII (column header `"a"`)
  txt <- readLines(out, n = 1L, warn = FALSE)
  expect_match(txt, "^[A-Za-z\"]")
})
