# B3 regression: the `.provenance.json` sidecar write is wrapped in
# tryCatch so non-JSON-serialisable metadata emits a warning rather
# than rolling back the primary write.

test_that("dw_save preserves the primary file when sidecar write fails (B3)", {
  tdir <- local_tempdir()
  local_state(teamsWrkData = tdir)

  # Construct metadata containing a value that jsonlite cannot
  # serialise.  An R environment is the cleanest example.
  bad_meta <- list(weird = new.env())

  df <- data.frame(a = 1, b = 2)
  out_path <- file.path(tdir, "survives.csv")

  # Capture both return value and warning via withCallingHandlers.
  captured_warning <- NULL
  out <- withCallingHandlers(
    dw_save(df, path = out_path, metadata = bad_meta),
    warning = function(cnd) {
      captured_warning <<- cnd
      invokeRestart("muffleWarning")
    }
  )

  # 1. The primary file exists despite the sidecar failure.
  expect_true(file.exists(out))
  expect_equal(out, out_path)

  # 2. A warning fired, matching the documented pattern.
  expect_false(is.null(captured_warning))
  expect_match(conditionMessage(captured_warning),
               "Provenance sidecar write failed")

  # 3. The warning carries the standard envelope.
  expect_envelope(captured_warning, function_name = "dw_save")
})
