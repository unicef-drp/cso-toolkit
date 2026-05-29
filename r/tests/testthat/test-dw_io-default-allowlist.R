# Tests for v0.4.4 dw_default_unicef_allowlist()
# Issue: https://github.com/unicef-drp/cso-toolkit/issues/37

test_that("dw_default_unicef_allowlist() returns a non-empty character vector", {
  allow <- dw_default_unicef_allowlist()
  expect_type(allow, "character")
  expect_gt(length(allow), 0L)
  expect_true(all(nzchar(allow)))
})

test_that("default allowlist patterns are anchored regex (start with ^)", {
  allow <- dw_default_unicef_allowlist()
  expect_true(all(startsWith(allow, "^")))
})

test_that("default allowlist matches the canonical raw.githubusercontent.com/unicef-drp/ URL", {
  allow <- dw_default_unicef_allowlist()
  local_state(dw_url_allowlist = allow)
  expect_true(.is_allowlisted_url(
    "https://raw.githubusercontent.com/unicef-drp/Country-and-Region-Metadata/refs/heads/main/output/AU.csv"
  ))
})

test_that("default allowlist matches a generic github.com/unicef-drp/ URL", {
  allow <- dw_default_unicef_allowlist()
  local_state(dw_url_allowlist = allow)
  expect_true(.is_allowlisted_url("https://github.com/unicef-drp/cso-toolkit/issues/37"))
})

test_that("default allowlist REJECTS a non-UNICEF-DRP raw URL", {
  allow <- dw_default_unicef_allowlist()
  local_state(dw_url_allowlist = allow)
  expect_false(.is_allowlisted_url(
    "https://raw.githubusercontent.com/some-other-org/some-repo/main/data.csv"
  ))
})

test_that("default allowlist composes with project-specific extras via c(...)", {
  allow <- c(
    dw_default_unicef_allowlist(),
    "^https://yourorg\\.github\\.io/"
  )
  local_state(dw_url_allowlist = allow)
  # UNICEF-DRP pattern still matches
  expect_true(.is_allowlisted_url("https://github.com/unicef-drp/cso-toolkit"))
  # Project-specific extra also matches
  expect_true(.is_allowlisted_url("https://yourorg.github.io/datasets/v1.csv"))
  # Non-allowlisted still rejected
  expect_false(.is_allowlisted_url("https://example.com/leak.csv"))
})
