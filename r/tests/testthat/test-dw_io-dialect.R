# Regression tests for the v0.4.1 `dialect` parameter on dw_save()
# and the v0.4.2 separator fix that addresses a Copilot finding from
# DW-Production PR #128.
#
# v0.4.1 restored `dialect = c("fwrite", "base")` on dw_save(), so
# callers can choose:
#   - fwrite (default): data.table::fwrite, row.names = FALSE, fast
#   - base:             utils::write.csv-equivalent, row.names = TRUE,
#                       byte-parity with legacy write.csv() output
#
# v0.4.2 switches the dialect="base" implementation from
# `utils::write.csv(x, file = path)` (which hardcodes a comma
# separator) to `utils::write.table(x, file = path, sep = sep,
# col.names = NA, qmethod = "double")` so the .tsv / .txt dispatch
# actually produces tab-separated output instead of silent
# CSV-formatted content with a TSV extension.

test_that("dialect='base' on .csv is byte-identical to utils::write.csv()", {
  d <- local_tempdir()
  local_state(dw_mode = "reviewer")
  x <- data.frame(a = 1:3,
                  b = c("foo", "bar", "baz"),
                  stringsAsFactors = FALSE)

  csv_via_dw_save <- file.path(d, "via_dw_save.csv")
  csv_via_write_csv <- file.path(d, "via_write_csv.csv")

  dw_save(x, path = csv_via_dw_save, dialect = "base", provenance = FALSE)
  utils::write.csv(x, file = csv_via_write_csv)

  # True byte-parity check: compare raw bytes (readLines normalises
  # line endings and could mask encoding/EOF differences across OSes).
  bytes_dw_save  <- readBin(csv_via_dw_save,   what = "raw",
                            n = file.info(csv_via_dw_save)$size)
  bytes_write_csv <- readBin(csv_via_write_csv, what = "raw",
                             n = file.info(csv_via_write_csv)$size)
  expect_identical(bytes_dw_save, bytes_write_csv)
})

test_that("dialect='base' on .tsv produces tab-separated output (v0.4.2 fix)", {
  d <- local_tempdir()
  local_state(dw_mode = "reviewer")
  x <- data.frame(a = 1:3,
                  b = c("foo", "bar", "baz"),
                  stringsAsFactors = FALSE)

  tsv_path <- file.path(d, "out.tsv")
  dw_save(x, path = tsv_path, dialect = "base", provenance = FALSE)

  body <- readLines(tsv_path)
  # The .tsv must contain actual tab characters between fields. The
  # v0.4.1 implementation called utils::write.csv() directly and so
  # produced comma-separated content with a .tsv extension; v0.4.2
  # uses utils::write.table(sep = "\t") under the hood.
  expect_true(any(grepl("\t", body, fixed = TRUE)))
  # And must NOT contain commas in the data rows (header row also
  # gets the tab separator after v0.4.2).
  data_rows <- body[-1]
  expect_false(any(grepl(",", data_rows, fixed = TRUE)))
})

test_that("dialect='base' rejects compress = TRUE with an explanatory error", {
  d <- local_tempdir()
  local_state(dw_mode = "reviewer")
  x <- data.frame(a = 1:3)

  err <- tryCatch(
    dw_save(x, path = file.path(d, "out.csv"),
            dialect = "base", compress = TRUE, provenance = FALSE),
    error = function(e) e
  )
  expect_s3_class(err, "error")
  expect_envelope(err, function_name = "dw_save")
  expect_match(conditionMessage(err), "dialect = 'base'.*compress")
})

test_that("dialect='unknown' raises an error (match.arg gate before envelope)", {
  # NOTE: dw_save() declares `dialect = c("fwrite", "base")` and calls
  # match.arg() near the top of the body. match.arg() raises a base R
  # error ("'arg' should be one of ...") BEFORE the toolkit envelope
  # wrapping kicks in. So the error message is intentionally base R
  # style, not the [cso_toolkit.dw_save] / Fix: envelope. This is the
  # correct behaviour -- match.arg gives the cheap validation -- but
  # the test must reflect that, not assert envelope shape.
  d <- local_tempdir()
  local_state(dw_mode = "reviewer")
  x <- data.frame(a = 1:3)

  err <- tryCatch(
    dw_save(x, path = file.path(d, "out.csv"),
            dialect = "unknown", provenance = FALSE),
    error = function(e) e
  )
  expect_s3_class(err, "error")
  expect_match(conditionMessage(err),
               "should be one of|fwrite|base|unknown")
})
