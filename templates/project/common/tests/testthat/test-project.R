# Starter tests for the repository itself, written by cso-toolkit's
# create_research_project() / create_official_stats_project().
#
# Keep them and add your own: a test per project function, and a regression
# test per bug fix that names the issue in its title and fails on the old
# code (The CSO Handbook, "Checks and CI").
# Tests use tiny synthetic fixtures in tests/testthat/fixtures/, never real
# data: the data are not in the repository.

testthat::local_edition(3)

root <- if (exists(".test_root")) .test_root else
  normalizePath(file.path(testthat::test_path(), "..", ".."))

test_that("cso_project.yml declares the project's collaboration model", {
  testthat::skip_if_not_installed("yaml")
  p <- yaml::read_yaml(file.path(root, "cso_project.yml"))
  expect_identical(p$schema, "cso_project/1")
  expect_true(p$collaboration %in% c("single-producer", "multi-producer"))
})

test_that("every input in the manifest has a sidecar with the same sha256", {
  testthat::skip_if_not_installed("jsonlite")
  man <- utils::read.csv(file.path(root, "{{input_manifest}}"),  # cso-allow: io-read-csv
                         stringsAsFactors = FALSE, colClasses = "character")
  expect_identical(names(man), c("file", "sha256", "bytes", "origin", "sidecar"))
  for (i in seq_len(nrow(man))) {
    sc <- file.path(root, man$sidecar[i])
    expect_true(file.exists(sc), info = man$sidecar[i])
    if (!file.exists(sc)) next
    j <- jsonlite::read_json(sc)
    expect_match(j$sha256, "^[0-9a-f]{64}$", info = sc)
    expect_identical(j$sha256, man$sha256[i], info = sc)
  }
})

test_that("the suite runs in reviewer mode (no network, no canonical writes)", {
  expect_identical(get("dw_mode", envir = globalenv()), "reviewer")
  expect_false(isTRUE(get("dw_apis_allowed", envir = globalenv())))
})
