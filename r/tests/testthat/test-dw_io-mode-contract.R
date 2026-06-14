# Regression tests for the v0.4.0 producer / reviewer mode contract
# (issue #14).  Each test_that() block targets one behaviour change
# from the implementation plan's verification matrix:
#
#   1. dw_toolkit_version() returns the v0.4.0 stamp
#   2. Reviewer mode forbids canonical writes (v0.3.0 preserved)
#   3. Reviewer mode forbids Z: drive writes (v0.4.0 broadened)
#   4. Producer mode hard-stops with no mirrors
#   5. Producer mode happy path -- both mirrors written
#   6. Producer mode degraded -- Teams-only single-mirror write succeeds
#   7. Overwrite gate refuses when ANY destination already exists
#   8. Reviewer-mode network-first read prefers Teams over local
#   9. Reviewer-mode local fallback emits provenance warning
#  10. Reviewer-mode missing-everywhere hard-stop
#
# Dependencies: tests exercise the CSV write path only, so the suite
# requires only data.table (already in DESCRIPTION Imports) -- no
# skip_if_not_installed() guard is needed.

test_that("dw_toolkit_version() returns the current v0.4.10 stamp", {
  expect_identical(dw_toolkit_version(), "0.4.10")
})

test_that("reviewer mode forbids canonical writes (v0.3.0 preserved)", {
  d <- local_tempdir()
  canon_root <- file.path(d, "canon")
  dir.create(canon_root, recursive = TRUE)
  local_state(
    dw_mode = "reviewer",
    teamsWrkDataCanonical = canon_root,
    teamsRawDataCanonical = canon_root,
    teamsFolderCanonical = canon_root
  )
  df <- data.frame(a = 1:3)
  err <- tryCatch(
    dw_save(df, path = file.path(canon_root, "x.csv")),
    error = function(e) e
  )
  expect_s3_class(err, "error")
  expect_envelope(err, function_name = "dw_save")
  expect_match(conditionMessage(err), "canonical")
})

test_that("reviewer mode forbids Z: drive writes (v0.4.0 broadened)", {
  d <- local_tempdir()
  z_root <- file.path(d, "z_root")
  dir.create(z_root, recursive = TRUE)
  local_state(
    dw_mode = "reviewer",
    dwZDrive = z_root,
    dw_z_available = TRUE
  )
  df <- data.frame(a = 1:3)
  err <- tryCatch(
    dw_save(df, path = file.path(z_root, "x.csv")),
    error = function(e) e
  )
  expect_s3_class(err, "error")
  expect_envelope(err, function_name = "dw_save")
  expect_match(conditionMessage(err), "Z:")
})

test_that("producer mode hard-stops when neither Teams nor Z: is configured", {
  d <- local_tempdir()
  # No canonical roots, no Z: drive — primary path lives entirely
  # outside any configured Teams root, so .dw_remote_mirrors() returns
  # NA for both Teams and Z:.
  local_state(
    dw_mode = "producer",
    dw_z_available = FALSE
  )
  df <- data.frame(a = 1:3)
  err <- tryCatch(
    dw_save(df, path = file.path(d, "isolated.csv")),
    error = function(e) e
  )
  expect_s3_class(err, "error")
  expect_envelope(err, function_name = "dw_save")
  expect_match(conditionMessage(err), "Teams|Z:")
})

test_that("producer mode writes redundantly to both Teams and Z:", {
  d <- local_tempdir()
  primary_root <- file.path(d, "wrk-local")
  canon_root   <- file.path(d, "wrk-canon")
  z_root       <- file.path(d, "z_drive")
  dir.create(primary_root, recursive = TRUE)
  dir.create(canon_root, recursive = TRUE)
  dir.create(z_root, recursive = TRUE)
  local_state(
    dw_mode = "producer",
    teamsWrkData = primary_root,
    teamsWrkDataCanonical = canon_root,
    teamsFolderCanonical = canon_root,
    dwZDrive = z_root,
    dw_z_available = TRUE
  )
  df <- data.frame(REF_AREA = c("AGO", "BFA"), value = c(1, 2))
  out <- dw_save(df, path = file.path(primary_root, "sec/x.csv"),
                 isid = "REF_AREA", provenance = TRUE)
  # Primary
  expect_true(file.exists(out))
  # Teams canonical mirror
  teams_mirror <- file.path(canon_root, "sec", "x.csv")
  expect_true(file.exists(teams_mirror))
  # Z: drive mirror (derived from Teams structure)
  z_mirror <- file.path(z_root, "sec", "x.csv")
  expect_true(file.exists(z_mirror))
  # Provenance sidecars on all three
  expect_true(file.exists(paste0(out, ".provenance.json")))
  expect_true(file.exists(paste0(teams_mirror, ".provenance.json")))
  expect_true(file.exists(paste0(z_mirror, ".provenance.json")))
})

test_that("producer mode tolerates single-mirror availability (Teams only)", {
  # Teams-only configuration: Z: drive intentionally unmounted.
  # The producer pre-flight should pass (one mirror is enough), and
  # the fan-out should write to Teams but skip Z: silently.
  d <- local_tempdir()
  primary_root <- file.path(d, "wrk-local")
  canon_root   <- file.path(d, "wrk-canon")
  dir.create(primary_root, recursive = TRUE)
  dir.create(canon_root, recursive = TRUE)
  local_state(
    dw_mode = "producer",
    teamsWrkData = primary_root,
    teamsWrkDataCanonical = canon_root,
    teamsFolderCanonical = canon_root,
    dw_z_available = FALSE
  )
  df <- data.frame(REF_AREA = c("AGO"), value = 1)
  out <- dw_save(df, path = file.path(primary_root, "sec/x.csv"),
                 isid = "REF_AREA", provenance = TRUE)
  expect_true(file.exists(out))
  # Teams canonical mirror was written
  teams_mirror <- file.path(canon_root, "sec", "x.csv")
  expect_true(file.exists(teams_mirror))
  expect_true(file.exists(paste0(teams_mirror, ".provenance.json")))
})

test_that("overwrite gate refuses when ANY destination already exists", {
  d <- local_tempdir()
  primary_root <- file.path(d, "wrk-local")
  canon_root   <- file.path(d, "wrk-canon")
  z_root       <- file.path(d, "z_drive")
  dir.create(primary_root, recursive = TRUE)
  dir.create(canon_root, recursive = TRUE)
  dir.create(z_root, recursive = TRUE)
  local_state(
    dw_mode = "producer",
    teamsWrkData = primary_root,
    teamsWrkDataCanonical = canon_root,
    teamsFolderCanonical = canon_root,
    dwZDrive = z_root,
    dw_z_available = TRUE
  )
  df <- data.frame(REF_AREA = c("AGO"), value = 1)
  primary <- file.path(primary_root, "sec/x.csv")

  # First write succeeds
  dw_save(df, path = primary, isid = "REF_AREA")

  # Second write with overwrite=FALSE (the v0.4.0 default) refuses
  err <- tryCatch(
    dw_save(df, path = primary, isid = "REF_AREA"),
    error = function(e) e
  )
  expect_s3_class(err, "error")
  expect_envelope(err, function_name = "dw_save")
  expect_match(conditionMessage(err), "overwrite|exists")

  # Same call with overwrite=TRUE succeeds (suppress info messages
  # from the mirror block — they are not errors / warnings).
  suppressMessages({
    out <- dw_save(df, path = primary, isid = "REF_AREA", overwrite = TRUE)
  })
  expect_true(file.exists(out))
})

test_that("reviewer-mode read prefers Teams over the local copy", {
  d <- local_tempdir()
  primary_root <- file.path(d, "wrk-local")
  canon_root   <- file.path(d, "wrk-canon")
  dir.create(file.path(primary_root, "sec"), recursive = TRUE)
  dir.create(file.path(canon_root, "sec"), recursive = TRUE)

  # Two different contents — Teams is "good", local is "stale"
  writeLines("REF_AREA,value\nAGO,42", file.path(canon_root, "sec", "x.csv"))
  writeLines("REF_AREA,value\nAGO,99", file.path(primary_root, "sec", "x.csv"))

  local_state(
    dw_mode = "reviewer",
    teamsWrkData = primary_root,
    teamsWrkDataCanonical = canon_root,
    teamsFolderCanonical = canon_root,
    dw_z_available = FALSE
  )

  df <- dw_use(path = file.path(primary_root, "sec", "x.csv"), verify_z = FALSE)
  # If we got Teams (canonical), value == 42; if we got local, value == 99.
  expect_equal(as.integer(df$value), 42L)
})

test_that("reviewer-mode local fallback emits a provenance warning", {
  d <- local_tempdir()
  primary_root <- file.path(d, "wrk-local")
  canon_root   <- file.path(d, "wrk-canon")
  dir.create(file.path(primary_root, "sec"), recursive = TRUE)
  dir.create(canon_root, recursive = TRUE)  # exists but EMPTY

  writeLines("REF_AREA,value\nAGO,99", file.path(primary_root, "sec", "x.csv"))

  local_state(
    dw_mode = "reviewer",
    teamsWrkData = primary_root,
    teamsWrkDataCanonical = canon_root,
    teamsFolderCanonical = canon_root,
    dw_z_available = FALSE
  )

  expect_warning(
    df <- dw_use(path = file.path(primary_root, "sec", "x.csv"),
                 verify_z = FALSE),
    regexp = "(provenance|unverified|local)"
  )
  expect_equal(as.integer(df$value), 99L)
})

test_that("reviewer-mode read hard-stops when file is missing everywhere", {
  d <- local_tempdir()
  canon_root <- file.path(d, "wrk-canon")
  local_state(
    dw_mode = "reviewer",
    teamsWrkData = file.path(d, "wrk-local"),
    teamsWrkDataCanonical = canon_root,
    teamsFolderCanonical = canon_root,
    dw_z_available = FALSE
  )

  err <- tryCatch(
    dw_use(path = file.path(d, "wrk-local", "missing.csv"),
           verify_z = FALSE),
    error = function(e) e
  )
  expect_s3_class(err, "error")
  expect_envelope(err, function_name = "dw_use")
  expect_match(conditionMessage(err), "(missing|not found|producer)")
})
