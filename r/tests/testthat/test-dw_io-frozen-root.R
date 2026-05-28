# Tests for v0.4.4 .dw_frozen_root() discoverability + error envelope
# Issue: https://github.com/unicef-drp/cso-toolkit/issues/38

test_that(".dw_frozen_root_resolved() reports source tier #1 when dw_frozen_root is set", {
  tdir <- local_tempdir()
  local_state(dw_frozen_root = tdir)
  res <- .dw_frozen_root_resolved()
  expect_identical(res$path, tdir)
  expect_identical(res$source, "dw_frozen_root")
})

test_that(".dw_frozen_root_resolved() reports source tier #2 when only githubFolder is set", {
  tdir <- local_tempdir()
  local_state(githubFolder = tdir)
  res <- .dw_frozen_root_resolved()
  expect_identical(res$path, file.path(tdir, "_frozen"))
  expect_identical(res$source, "githubFolder")
})

test_that(".dw_frozen_root_resolved() falls back to getwd() (tier #3) when neither is set", {
  # local_state() with no args still snapshots + restores; this
  # protects against pollution from earlier tests in the suite.
  local_state()
  res <- .dw_frozen_root_resolved()
  expect_identical(res$path, file.path(getwd(), "_frozen"))
  expect_identical(res$source, "getwd")
})

test_that(".dw_frozen_root() (legacy, path-only) preserves the v0.4.3.1 contract", {
  tdir <- local_tempdir()
  local_state(dw_frozen_root = tdir)
  expect_identical(.dw_frozen_root(), tdir)
})

test_that("missing-frozen-copy error envelope honours the toolkit envelope shape AND surfaces the resolution tier", {
  tdir <- local_tempdir()
  local_state(
    dw_url_allowlist = "^https://example\\.test/",
    dw_frozen_root   = tdir,
    dw_mode          = "reviewer"
  )

  err <- tryCatch(
    .resolve_remote_url("https://example.test/does-not-exist.csv"),
    error = function(e) e
  )
  expect_s3_class(err, "error")

  # Canonical envelope shape (`[cso_toolkit.<func>] ... Fix:` block)
  # preserved from v0.4.3.1; same helper as the rest of the remote-
  # freeze suite.
  expect_envelope(err, function_name = "dw_use:remote")

  # New in v0.4.4: error envelope surfaces the chosen resolution
  # path AND the tier name so consumers can see whether the
  # explicit-global tier (#1), the githubFolder fallback (#2), or
  # the getwd fallback (#3) picked the offending path.
  expect_match(
    conditionMessage(err),
    "Frozen-root resolution:.*dw_frozen_root"
  )
})

test_that(".dw_frozen_root_notify_once fires at most once per session", {
  local_state()  # snapshots + restores the sentinel + globals
  resolved <- list(path = "/tmp/_frozen", source = "githubFolder")

  # First call -> a single message
  expect_message(
    .dw_frozen_root_notify_once(resolved),
    "dw_frozen_root.*not set.*falling back"
  )
  # Second call -> silent
  expect_silent(.dw_frozen_root_notify_once(resolved))
})

test_that(".dw_frozen_root_notify_once is silent when dw_frozen_root explicitly set", {
  local_state()
  resolved <- list(path = "/explicit/path", source = "dw_frozen_root")
  expect_silent(.dw_frozen_root_notify_once(resolved))
})
