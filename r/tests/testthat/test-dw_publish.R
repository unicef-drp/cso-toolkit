# Regression tests for dw_publish() (#15 STUB).
#
# v0.4.0 ships dw_publish as a dry-run-only stub.  Tests exercise:
#   - Reviewer-mode lockout (raises BEFORE any I/O)
#   - Argument validation (empty/missing path | indicator | vintage |
#     sector)
#   - Path-must-exist check
#   - Endpoint allowlist
#   - Dry-run payload shape (sha256, bytes, toolkit version, mode flags)
#   - Live submission (dry_run = FALSE) hard-stop with the envelope
#     pointer to issue #15

test_that("dw_publish reviewer-mode lockout raises BEFORE any I/O", {
  local_state(dw_mode = "reviewer")
  err <- tryCatch(
    dw_publish(path = "/nonexistent/should_not_be_read.csv",
               indicator = "U5MR", vintage = "2025", sector = "hva"),
    error = identity
  )
  expect_s3_class(err, "error")
  expect_envelope(err, function_name = "dw_publish")
  expect_match(conditionMessage(err), "Reviewer mode")
})

test_that("dw_publish raises envelope when required arguments are empty", {
  local_state(dw_mode = "producer")
  d <- local_tempdir()
  p <- file.path(d, "x.csv")
  writeLines("a\n1\n", p)
  err <- tryCatch(
    dw_publish(path = p, indicator = "", vintage = "2025", sector = "hva"),
    error = identity
  )
  expect_s3_class(err, "error")
  expect_envelope(err, function_name = "dw_publish")
  expect_match(conditionMessage(err), "indicator")
})

test_that("dw_publish raises envelope when a required argument is OMITTED (Copilot #22.1)", {
  local_state(dw_mode = "producer")
  d <- local_tempdir()
  p <- file.path(d, "x.csv")
  writeLines("a\n1\n", p)
  # Omit `indicator` entirely.  Without the match.call() fix in #22.1
  # base R raises "argument 'indicator' is missing" before the
  # envelope, so this asserts we get the cso-toolkit envelope shape.
  err <- tryCatch(
    dw_publish(path = p, vintage = "2025", sector = "hva"),
    error = identity
  )
  expect_s3_class(err, "error")
  expect_envelope(err, function_name = "dw_publish")
  expect_match(conditionMessage(err), "indicator")
})

test_that("dw_publish raises envelope on length-pathological arguments (Copilot #22.1)", {
  local_state(dw_mode = "producer")
  d <- local_tempdir()
  p <- file.path(d, "x.csv")
  writeLines("a\n1\n", p)
  # Length-2 character vector
  err <- tryCatch(
    dw_publish(path = p,
               indicator = c("U5MR", "NMR"),
               vintage = "2025", sector = "hva"),
    error = identity
  )
  expect_s3_class(err, "error")
  expect_envelope(err, function_name = "dw_publish")
  expect_match(conditionMessage(err), "single strings|length 1")
})

test_that("dw_publish raises envelope when path is missing on disk", {
  local_state(dw_mode = "producer")
  err <- tryCatch(
    dw_publish(path = "/nonexistent/path/no_such_file.csv",
               indicator = "U5MR", vintage = "2025", sector = "hva"),
    error = identity
  )
  expect_s3_class(err, "error")
  expect_envelope(err, function_name = "dw_publish")
  expect_match(conditionMessage(err), "not found|EXISTING")
})

test_that("dw_publish raises envelope on unsupported endpoint", {
  local_state(dw_mode = "producer")
  d <- local_tempdir()
  p <- file.path(d, "x.csv")
  writeLines("a\n1\n", p)
  err <- tryCatch(
    dw_publish(path = p, indicator = "U5MR", vintage = "2025",
               sector = "hva", endpoint = "not_a_real_endpoint"),
    error = identity
  )
  expect_s3_class(err, "error")
  expect_envelope(err, function_name = "dw_publish")
  expect_match(conditionMessage(err), "endpoint")
})

test_that("dw_publish dry_run = TRUE returns a validated payload", {
  local_state(dw_mode = "producer")
  d <- local_tempdir()
  p <- file.path(d, "dw_hva_u5mr.csv")
  writeLines("REF_AREA,OBS_VALUE\nBFA,72\n", p)

  out <- dw_publish(path = p, indicator = "U5MR",
                    vintage = "2025", sector = "hva")
  expect_type(out, "list")
  expect_setequal(names(out),
                  c("submission_id", "status", "response_body", "idempotent"))
  expect_identical(out$status, "dry_run")
  expect_true(is.na(out$submission_id))
  expect_true(is.na(out$idempotent))
  # Payload echoes the call site
  body <- out$response_body
  expect_identical(body$indicator, "U5MR")
  expect_identical(body$vintage,   "2025")
  expect_identical(body$sector,    "hva")
  expect_identical(body$endpoint,  "helix")
  expect_identical(body$toolkit,   "0.4.1")
  # bytes is the size of the test file
  expect_true(body$bytes > 0)
})

test_that("dw_publish dry_run = FALSE raises the v0.5.0-not-yet envelope", {
  local_state(dw_mode = "producer")
  d <- local_tempdir()
  p <- file.path(d, "x.csv")
  writeLines("a\n1\n", p)

  err <- tryCatch(
    dw_publish(path = p, indicator = "U5MR", vintage = "2025",
               sector = "hva", dry_run = FALSE),
    error = identity
  )
  expect_s3_class(err, "error")
  expect_envelope(err, function_name = "dw_publish")
  expect_match(conditionMessage(err),
               "Live submission not yet implemented|issues/15")
})
