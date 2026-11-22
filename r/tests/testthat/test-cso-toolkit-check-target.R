# cso_toolkit_check() target-version alert (#106 item 4): an offline
# comparison of the vendored copy against a target version, loud (warning +
# boxed alert) when behind, warn-only in reviewer mode; plus numeric version
# comparison against the upstream tag in producer mode.

local_manifest <- function(pulled, target = NULL, env = parent.frame()) {
  dir <- withr::local_tempdir(.local_envir = env)
  lines <- c('source: "unicef-drp/cso-toolkit"',
             sprintf('pulled_version: "%s"', pulled))
  if (!is.null(target)) lines <- c(lines, sprintf('target_version: "%s"', target))
  writeLines(lines, file.path(dir, ".toolkit_manifest.yml"))
  dir
}

test_that("T1: version helpers compare numerically and ignore non-versions", {
  expect_true(.cso_version_behind("v0.9.0", "v0.9.1"))
  expect_true(.cso_version_behind("v0.9.1", "v0.10.0"))     # not lexical
  expect_false(.cso_version_behind("v0.10.0", "v0.9.1"))
  expect_false(.cso_version_behind("0.9.1", "v0.9.1"))
  expect_false(.cso_version_behind("v1.0.0-rc1", "v1.0.0"))
  expect_true(is.na(.cso_version_behind("inrepo", "v0.9.1")))
  expect_identical(.cso_tag("0.9.1"), "v0.9.1")
  expect_identical(.cso_tag("v0.9.1"), "v0.9.1")
})

test_that("T2: reviewer mode, manifest target ahead -> warning envelope, no box when quiet", {
  local_state(dw_apis_allowed = FALSE, dwFunct = local_manifest("v0.9.0", "v0.9.1"))
  w <- expect_warning(res <- cso_toolkit_check(quiet = TRUE))
  expect_envelope(w, "cso_toolkit_check")
  expect_match(conditionMessage(w), 'cso_toolkit_sync(target_version = "v0.9.1")', fixed = TRUE)
  expect_no_match(conditionMessage(w), "cso_toolkit_pull(", fixed = TRUE)   # #213
  expect_match(conditionMessage(w), "re-pins the manifest", fixed = TRUE)
  expect_match(conditionMessage(w), "Reviewer mode: no network call")
  expect_true(res$behind_target)
  expect_identical(res$target_source, "manifest")
  expect_true(is.na(res$upstream_version))
})

test_that("T3: quiet = FALSE prints the boxed alert with the exact commands", {
  local_state(dw_apis_allowed = FALSE, dwFunct = local_manifest("v0.9.0", "v0.9.1"))
  msgs <- character(0)
  withCallingHandlers(
    suppressWarnings(cso_toolkit_check(quiet = FALSE)),
    message = function(m) { msgs <<- c(msgs, conditionMessage(m)); invokeRestart("muffleMessage") }
  )
  box <- paste(msgs, collapse = "\n")
  expect_match(box, "BEHIND its target version", fixed = TRUE)
  expect_match(box, 'cso_toolkit_sync(target_version = "v0.9.1")', fixed = TRUE)
  expect_no_match(box, "cso_toolkit_pull(", fixed = TRUE)   # #213
  expect_match(box, "(?m)^\\+-+\\+$", perl = TRUE)   # ASCII box border line
})

test_that("T4: the target_version argument overrides the manifest", {
  local_state(dw_apis_allowed = FALSE, dwFunct = local_manifest("v0.9.1", "v0.9.2"))
  expect_no_warning(res <- cso_toolkit_check(quiet = TRUE, target_version = "v0.9.1"))
  expect_false(res$behind_target)
  expect_identical(res$target_source, "argument")
})

test_that("T5: at or ahead of target, or inrepo -> no warning", {
  local_state(dw_apis_allowed = FALSE, dwFunct = local_manifest("v0.10.0", "v0.9.1"))
  expect_no_warning(res <- cso_toolkit_check(quiet = TRUE))
  expect_false(res$behind_target)
  local_state(dw_apis_allowed = FALSE, dwFunct = local_manifest("inrepo", "v0.9.1"))
  expect_no_warning(res <- cso_toolkit_check(quiet = TRUE))
  expect_true(is.na(res$behind_target))
})

test_that("T6: reviewer mode without a target returns NULL, silently", {
  local_state(dw_apis_allowed = FALSE, dwFunct = local_manifest("v0.9.0"))
  expect_no_warning(res <- cso_toolkit_check(quiet = TRUE))
  expect_null(res)
})

test_that("T7: producer mode, newer upstream -> boxed notice, no warning", {
  local_state(dw_apis_allowed = TRUE, dwFunct = local_manifest("v0.9.0"))
  local_mocked_bindings(.cso_upstream_latest_tag = function(...) "v0.9.1")
  expect_no_warning(
    expect_message(res <- cso_toolkit_check(quiet = FALSE), "newer cso-toolkit release")
  )
  expect_true(res$updates_available)
  expect_identical(res$upstream_version, "v0.9.1")
  expect_true(is.na(res$behind_target))
})

test_that("T8: producer mode, vendored ahead of upstream is not 'behind' (numeric compare)", {
  local_state(dw_apis_allowed = TRUE, dwFunct = local_manifest("v0.10.0"))
  local_mocked_bindings(.cso_upstream_latest_tag = function(...) "v0.9.1")
  res <- cso_toolkit_check(quiet = TRUE)
  expect_false(res$updates_available)
})

test_that("T9: producer mode, behind both target and upstream -> warning cites target", {
  local_state(dw_apis_allowed = TRUE, dwFunct = local_manifest("v0.9.0", "v0.9.1"))
  local_mocked_bindings(.cso_upstream_latest_tag = function(...) "v0.9.2")
  w <- expect_warning(res <- cso_toolkit_check(quiet = TRUE))
  expect_match(conditionMessage(w), 'target_version = "v0.9.1"', fixed = TRUE)
  expect_true(res$behind_target)
  expect_true(res$updates_available)
})
