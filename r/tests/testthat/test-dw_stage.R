# T1-T6 regression suite for dw_stage() -- reviewer-mode auto-stage with
# hash-guard, the v0.4.9 headline feature. Five lifecycle states plus the
# cross-mirror integrity branch are each exercised against a self-contained
# sandbox/Z:/Teams tempdir fixture per test (no real Teams sync or Z: mount
# is touched).

setup_stage_fixture <- function(env = parent.frame(),
                                src_text = "id,value\nAFG,1\nBGD,2\n") {
  root <- tempfile("dwstage_")
  dir.create(root, recursive = TRUE)

  teams_root   <- file.path(root, "teams")
  z_root       <- file.path(root, "z")
  sandbox_root <- file.path(root, "sandbox")
  dir.create(teams_root); dir.create(z_root); dir.create(sandbox_root)

  rel <- file.path("nt", "input", "regions.csv")
  teams_path   <- file.path(teams_root,   rel)
  z_path       <- file.path(z_root,       rel)
  sandbox_path <- file.path(sandbox_root, rel)

  dir.create(dirname(teams_path),   recursive = TRUE)
  dir.create(dirname(z_path),       recursive = TRUE)
  dir.create(dirname(sandbox_path), recursive = TRUE)

  writeLines(src_text, teams_path)
  writeLines(src_text, z_path)

  # In reviewer mode the toolkit's path globals point at the sandbox; the
  # *Canonical globals point at the producer-side canonical Teams root.
  local_state(
    dw_mode               = "reviewer",
    teamsRawData          = sandbox_root,
    teamsRawDataCanonical = teams_root,
    teamsWrkData          = sandbox_root,
    teamsWrkDataCanonical = teams_root,
    teamsFolder           = sandbox_root,
    teamsFolderCanonical  = teams_root,
    dwZDrive              = z_root,
    dw_z_available        = TRUE,
    .frame                = env
  )
  withr::defer(unlink(root, recursive = TRUE, force = TRUE), envir = env)

  list(
    root = root, rel = rel,
    teams_path = teams_path, z_path = z_path,
    sandbox_path = sandbox_path,
    sidecar      = paste0(sandbox_path, ".staged.json"),
    src_text     = src_text
  )
}

test_that("T1: first stage -- copy + hash-verify + sidecar written (#dw_stage)", {
  fx <- setup_stage_fixture()
  out <- dw_stage(fx$sandbox_path)
  expect_true(file.exists(out))
  expect_true(file.exists(fx$sandbox_path))
  expect_true(file.exists(fx$sidecar))

  src_sha     <- digest::digest(file = fx$teams_path,   algo = "sha256")
  sandbox_sha <- digest::digest(file = fx$sandbox_path, algo = "sha256")
  expect_identical(sandbox_sha, src_sha)

  sc <- jsonlite::fromJSON(fx$sidecar, simplifyVector = TRUE)
  expect_identical(sc$type, "dw_stage")
  expect_identical(sc$sha256, src_sha)
  expect_true(sc$source_root %in% c("z", "teams"))
})

test_that("T2: second run -- copy skipped, mtime preserved (no re-copy)", {
  fx <- setup_stage_fixture()
  dw_stage(fx$sandbox_path)
  mtime_before <- file.mtime(fx$sandbox_path)
  Sys.sleep(1.1)
  dw_stage(fx$sandbox_path)
  mtime_after <- file.mtime(fx$sandbox_path)
  expect_equal(as.numeric(mtime_after), as.numeric(mtime_before))
})

test_that("T3: tampered sandbox -- STOP with SANDBOX DRIFT envelope", {
  fx <- setup_stage_fixture()
  dw_stage(fx$sandbox_path)
  writeLines("id,value\nXXX,9\n", fx$sandbox_path)
  expect_error(dw_stage(fx$sandbox_path), regexp = "SANDBOX DRIFT")
})

test_that("T4: overwrite = TRUE -- re-copies + restores from source", {
  fx <- setup_stage_fixture()
  dw_stage(fx$sandbox_path)
  writeLines("id,value\nXXX,9\n", fx$sandbox_path)
  out <- dw_stage(fx$sandbox_path, overwrite = TRUE)
  expect_true(file.exists(out))
  src_sha     <- digest::digest(file = fx$teams_path,   algo = "sha256")
  sandbox_sha <- digest::digest(file = fx$sandbox_path, algo = "sha256")
  expect_identical(sandbox_sha, src_sha)
})

test_that("T5: upstream changed -- WARN, do NOT auto-re-copy", {
  fx <- setup_stage_fixture()
  dw_stage(fx$sandbox_path)
  Sys.sleep(1.1)
  new_text <- "id,value\nAFG,9\nBGD,9\n"
  writeLines(new_text, fx$teams_path)
  writeLines(new_text, fx$z_path)
  sandbox_before <- digest::digest(file = fx$sandbox_path, algo = "sha256")
  expect_warning(out <- dw_stage(fx$sandbox_path), regexp = "UPSTREAM CHANGED")
  expect_true(file.exists(out))
  # Critical: stage copy is NOT auto-refreshed.
  sandbox_after <- digest::digest(file = fx$sandbox_path, algo = "sha256")
  expect_identical(sandbox_before, sandbox_after)
})

test_that("T6: cross-mirror disagreement -- STOP with CANONICAL INTEGRITY", {
  fx <- setup_stage_fixture()
  # Force Z: and Teams to disagree BEFORE any sandbox copy exists.
  writeLines("id,value\nDIFFERENT,1\n", fx$z_path)
  expect_error(dw_stage(fx$sandbox_path), regexp = "CANONICAL INTEGRITY")
  expect_false(file.exists(fx$sidecar))
  expect_false(file.exists(paste0(fx$sandbox_path, ".dw_stage.tmp")))
})

test_that("dw_stage is a no-op outside reviewer mode", {
  fx <- setup_stage_fixture()
  # Override reviewer mode to producer; staging must not fire.
  local_state(dw_mode = "producer")
  # File doesn't exist in sandbox; dw_stage should NOT create it because
  # producer-mode is a deliberate no-op (returns the input path unchanged).
  expect_false(file.exists(fx$sandbox_path))
  out <- dw_stage(fx$sandbox_path)
  expect_identical(out, fx$sandbox_path)
  expect_false(file.exists(fx$sandbox_path))
})

test_that("T7: CANONICAL-rooted input is normalised to the sandbox (v0.4.9.1)", {
  # Regression for the v0.4.9 bug: a sector conductor that sets
  # `inputdir <- file.path(teamsRawDataCanonical, ...)` passes dw_stage a
  # canonical-rooted path. dw_stage must map it back to the sandbox, copy the
  # canonical source in, and write the sidecar SANDBOX-side -- NOT next to the
  # Teams source. (Before the fix, the file existed at the canonical path so
  # dw_stage reported "present in sandbox" and wrote `<teams>/...staged.json`.)
  fx <- setup_stage_fixture()

  # Pass the CANONICAL path (what the conductor builds), not the sandbox path.
  out <- dw_stage(fx$teams_path)

  # Returns the sandbox target, and the sandbox copy + sandbox sidecar exist.
  expect_identical(.normalize_for_comparison(out),
                   .normalize_for_comparison(fx$sandbox_path))
  expect_true(file.exists(fx$sandbox_path))
  expect_true(file.exists(fx$sidecar))                       # sandbox-side sidecar
  expect_false(file.exists(paste0(fx$teams_path, ".staged.json")))  # NOT Teams-side
  # Content copied through, canonical source untouched.
  expect_identical(readLines(fx$sandbox_path), readLines(fx$teams_path))
})

test_that("T8: canonical input is idempotent on the second call (skip copy)", {
  fx <- setup_stage_fixture()
  dw_stage(fx$teams_path)
  mt1 <- file.mtime(fx$sandbox_path)
  Sys.sleep(1.1)
  out <- dw_stage(fx$teams_path)               # second call, canonical input again
  expect_identical(file.mtime(fx$sandbox_path), mt1)  # copy skipped
  expect_identical(.normalize_for_comparison(out),
                   .normalize_for_comparison(fx$sandbox_path))
})
