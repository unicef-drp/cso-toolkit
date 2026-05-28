# Tests for v0.4.4 .dw_frozen_root() discoverability + error envelope
# Issue: https://github.com/unicef-drp/cso-toolkit/issues/38

test_that(".dw_frozen_root_resolved() reports source tier #1 when dw_frozen_root is set", {
  tdir <- local_tempdir()
  withr::with_options(list(), {
    assign("dw_frozen_root", tdir, envir = .GlobalEnv)
    on.exit(rm("dw_frozen_root", envir = .GlobalEnv), add = TRUE)
    res <- .dw_frozen_root_resolved()
    expect_identical(res$path, tdir)
    expect_identical(res$source, "dw_frozen_root")
  })
})

test_that(".dw_frozen_root_resolved() reports source tier #2 when only githubFolder is set", {
  tdir <- local_tempdir()
  withr::with_options(list(), {
    if (exists("dw_frozen_root", envir = .GlobalEnv)) rm("dw_frozen_root", envir = .GlobalEnv)
    assign("githubFolder", tdir, envir = .GlobalEnv)
    on.exit(rm("githubFolder", envir = .GlobalEnv), add = TRUE)
    res <- .dw_frozen_root_resolved()
    expect_identical(res$path, file.path(tdir, "_frozen"))
    expect_identical(res$source, "githubFolder")
  })
})

test_that(".dw_frozen_root_resolved() falls back to getwd() (tier #3) when neither is set", {
  withr::with_options(list(), {
    if (exists("dw_frozen_root", envir = .GlobalEnv)) rm("dw_frozen_root", envir = .GlobalEnv)
    if (exists("githubFolder", envir = .GlobalEnv)) rm("githubFolder", envir = .GlobalEnv)
    res <- .dw_frozen_root_resolved()
    expect_identical(res$path, file.path(getwd(), "_frozen"))
    expect_identical(res$source, "getwd")
  })
})

test_that(".dw_frozen_root() (legacy, path-only) preserves the v0.4.3.1 contract", {
  tdir <- local_tempdir()
  assign("dw_frozen_root", tdir, envir = .GlobalEnv)
  on.exit(rm("dw_frozen_root", envir = .GlobalEnv), add = TRUE)
  expect_identical(.dw_frozen_root(), tdir)
})

test_that("missing-frozen-copy error envelope surfaces the resolution tier", {
  skip_if_not_installed("withr")
  tdir <- local_tempdir()
  assign("dw_url_allowlist",
         "^https://example\\.test/", envir = .GlobalEnv)
  assign("dw_frozen_root", tdir, envir = .GlobalEnv)
  assign("dw_mode", "reviewer", envir = .GlobalEnv)
  on.exit({
    rm("dw_url_allowlist", "dw_frozen_root", "dw_mode", envir = .GlobalEnv)
  }, add = TRUE)

  expect_error(
    .resolve_remote_url("https://example.test/does-not-exist.csv"),
    regexp = "Frozen-root resolution:.*dw_frozen_root"
  )
})

test_that(".dw_frozen_root_notify_once fires at most once per session", {
  if (exists(".__cso_toolkit_frozen_root_notified__", envir = .GlobalEnv)) {
    rm(".__cso_toolkit_frozen_root_notified__", envir = .GlobalEnv)
  }
  on.exit({
    if (exists(".__cso_toolkit_frozen_root_notified__", envir = .GlobalEnv)) {
      rm(".__cso_toolkit_frozen_root_notified__", envir = .GlobalEnv)
    }
  }, add = TRUE)

  resolved <- list(path = "/tmp/_frozen", source = "githubFolder")

  # First call -> a single message
  expect_message(.dw_frozen_root_notify_once(resolved),
                 "dw_frozen_root.*not set.*falling back")
  # Second call -> silent
  expect_silent(.dw_frozen_root_notify_once(resolved))
})

test_that(".dw_frozen_root_notify_once is silent when dw_frozen_root explicitly set", {
  if (exists(".__cso_toolkit_frozen_root_notified__", envir = .GlobalEnv)) {
    rm(".__cso_toolkit_frozen_root_notified__", envir = .GlobalEnv)
  }
  on.exit({
    if (exists(".__cso_toolkit_frozen_root_notified__", envir = .GlobalEnv)) {
      rm(".__cso_toolkit_frozen_root_notified__", envir = .GlobalEnv)
    }
  }, add = TRUE)

  resolved <- list(path = "/explicit/path", source = "dw_frozen_root")
  expect_silent(.dw_frozen_root_notify_once(resolved))
})
