# Regression suite for dw_read_provenance() and dw_provenance_diff() --
# run-level comparison of two dw_save() outputs through their
# .provenance.json sidecars (input record + output SHA-256).

save_run <- function(dir, df, inputs = NULL, name = "out.csv") {
  path <- file.path(dir, name)
  meta <- list(title = "test output")
  if (!is.null(inputs)) meta$inputs <- inputs
  dw_save(df, path = path, metadata = meta, overwrite = TRUE, verbose = FALSE)
  path
}

INPUTS <- data.frame(file = c("2024/A_2024.csv", "2025/B_2025.csv"),
                     sha256 = c("aaa", "bbb"), origin = "local",
                     stringsAsFactors = FALSE)
DF <- data.frame(k = c("x", "y"), v = c(1, 2), stringsAsFactors = FALSE)

test_that("P1: dw_read_provenance reads the sidecar from the output or sidecar path", {
  local_state()
  tdir <- local_tempdir()
  out <- save_run(tdir, DF, INPUTS)
  p1 <- dw_read_provenance(out, verbose = FALSE)
  p2 <- dw_read_provenance(paste0(out, ".provenance.json"), verbose = FALSE)
  expect_identical(p1$sha256, p2$sha256)
  expect_s3_class(p1$metadata$inputs, "data.frame")
  expect_identical(p1$metadata$inputs$file, INPUTS$file)
})

test_that("P2: dw_read_provenance returns NULL when there is no sidecar", {
  tdir <- local_tempdir()
  expect_null(dw_read_provenance(file.path(tdir, "none.csv"), verbose = FALSE))
})

test_that("P3: an invalid sidecar stops with an envelope", {
  tdir <- local_tempdir()
  writeLines("{ not json", file.path(tdir, "bad.csv.provenance.json"))
  err <- expect_error(dw_read_provenance(file.path(tdir, "bad.csv"), verbose = FALSE))
  expect_envelope(err, "dw_read_provenance")
})

test_that("P4: same inputs and same data -> reproduced", {
  local_state()
  tdir <- local_tempdir()
  out <- save_run(tdir, DF, INPUTS)
  prev <- dw_read_provenance(out, verbose = FALSE)
  save_run(tdir, DF, INPUTS)
  run <- dw_provenance_diff(prev, out, verbose = FALSE)
  expect_identical(run$status, "reproduced")
  expect_true(run$same_inputs)
  expect_true(run$same_output)
})

test_that("P5: same inputs, different data -> output_changed with a warning envelope", {
  local_state()
  tdir <- local_tempdir()
  out <- save_run(tdir, DF, INPUTS)
  prev <- dw_read_provenance(out, verbose = FALSE)
  save_run(tdir, transform(DF, v = v * 10), INPUTS)
  w <- expect_warning(run <- dw_provenance_diff(prev, out, verbose = FALSE))
  expect_envelope(w, "dw_provenance_diff")
  expect_identical(run$status, "output_changed")
  expect_true(run$same_inputs)
  expect_false(run$same_output)
  expect_no_warning(dw_provenance_diff(prev, out, warn = FALSE, verbose = FALSE))
})

test_that("P6: inputs added, removed and changed are listed", {
  local_state()
  tdir <- local_tempdir()
  out <- save_run(tdir, DF, INPUTS)
  prev <- dw_read_provenance(out, verbose = FALSE)
  new_inputs <- data.frame(file = c("2024/A_2024.csv", "2023/C_2023.csv"),
                           sha256 = c("aaa-changed", "ccc"), origin = "local",
                           stringsAsFactors = FALSE)
  save_run(tdir, DF, new_inputs)
  run <- dw_provenance_diff(prev, out, verbose = FALSE)
  expect_identical(run$status, "inputs_changed")
  expect_false(run$same_inputs)
  expect_identical(run$inputs_added, "2023/C_2023.csv")
  expect_identical(run$inputs_removed, "2025/B_2025.csv")
  expect_identical(run$inputs_changed, "2024/A_2024.csv")
})

test_that("P7: no previous sidecar -> first_run", {
  local_state()
  tdir <- local_tempdir()
  out <- save_run(tdir, DF, INPUTS)
  run <- dw_provenance_diff(NULL, out, verbose = FALSE)
  expect_identical(run$status, "first_run")
  expect_true(is.na(run$same_output))
})

test_that("P8: a sidecar without an input record -> no_input_record, outputs still compared", {
  local_state()
  tdir <- local_tempdir()
  out <- save_run(tdir, DF)                    # no inputs record
  prev <- dw_read_provenance(out, verbose = FALSE)
  save_run(tdir, DF, INPUTS)
  run <- dw_provenance_diff(prev, out, verbose = FALSE)
  expect_identical(run$status, "no_input_record")
  expect_true(run$same_output)
})

test_that("P9: a current output without a sidecar stops with an envelope", {
  tdir <- local_tempdir()
  err <- expect_error(dw_provenance_diff(NULL, file.path(tdir, "none.csv"), verbose = FALSE))
  expect_envelope(err, "dw_provenance_diff")
})
