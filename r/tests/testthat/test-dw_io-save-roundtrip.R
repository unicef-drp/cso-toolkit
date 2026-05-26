test_that("dw_save -> dw_use roundtrip preserves a small data frame as CSV", {
  tdir <- local_tempdir()
  local_state(teamsWrkData = tdir)

  df <- data.frame(REF_AREA = c("AGO", "BFA"), OBS_VALUE = c(0.5, 0.7),
                   stringsAsFactors = FALSE)
  out <- dw_save(
    df,
    name = "dw_ed_edu.csv", sector = "ed", kind = "wrk",
    isid = "REF_AREA",
    metadata = list(
      title    = "Education indicators",
      producer = "test-dw_io-save-roundtrip.R",
      sources  = c("UIS bulk SDG_092025"),
      vintage  = "2026-05"
    )
  )

  expect_true(file.exists(out))
  expect_true(file.exists(paste0(out, ".provenance.json")))

  back <- dw_use(out)
  back <- as.data.frame(back)
  expect_equal(nrow(back), 2)
  expect_equal(sort(back$REF_AREA), c("AGO", "BFA"))
})

test_that("dw_save aborts with the envelope when isid duplicates exist", {
  tdir <- local_tempdir()
  local_state(teamsWrkData = tdir)
  bad <- data.frame(REF_AREA = c("AGO", "AGO"), OBS_VALUE = c(0.5, 0.7))
  err <- tryCatch(
    dw_save(bad, name = "bad.csv", sector = "ed", kind = "wrk",
            isid = "REF_AREA"),
    error = identity
  )
  expect_s3_class(err, "error")
  expect_envelope(err, function_name = "dw_isid")
})

test_that("dw_save rejects reviewer-mode canonical writes by default", {
  tdir <- local_tempdir()
  canonical <- file.path(tdir, "canonical")
  dir.create(canonical, recursive = TRUE)
  local_state(
    teamsWrkData = tdir,
    teamsFolderCanonical = canonical,
    dw_mode = "reviewer"
  )
  df <- data.frame(a = 1)
  err <- tryCatch(
    dw_save(df, path = file.path(canonical, "x.csv")),
    error = identity
  )
  expect_s3_class(err, "error")
  expect_envelope(err, function_name = "dw_save")
  expect_match(conditionMessage(err), "Reviewer mode")
})

test_that("dw_save under canonical path succeeds with allow_canonical_write", {
  tdir <- local_tempdir()
  canonical <- file.path(tdir, "canonical")
  dir.create(canonical, recursive = TRUE)
  local_state(
    teamsWrkData = tdir,
    teamsFolderCanonical = canonical,
    dw_mode = "reviewer"
  )
  df <- data.frame(a = 1, b = 2)
  out <- dw_save(df, path = file.path(canonical, "x.csv"),
                 allow_canonical_write = TRUE)
  expect_true(file.exists(out))
})
