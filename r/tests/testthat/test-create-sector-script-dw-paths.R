# #28 regression: the DW-Production wrapper of create_sector_script
# must scaffold sector scripts whose input/output paths point at the
# canonical DW layout (011_rawdata / 013_wrkdata), and whose profile
# sentinel references a global that actually exists in
# profile_DW-Production.R (projectFolder), not the never-defined
# `profile_DW_Production`.

test_that("create_dw_sector_script uses 011_rawdata / 013_wrkdata (#28)", {
  d <- local_tempdir()
  path <- create_dw_sector_script(
    sector_name  = "WASH",
    sector_code  = "ws",
    project_root = d
  )
  expect_true(file.exists(path))

  body <- readLines(path, warn = FALSE)

  # Generated script references the corrected canonical layout.
  expect_true(any(grepl("011_rawdata", body, fixed = TRUE)),
              info = "Generated script must reference 011_rawdata")
  expect_true(any(grepl("013_wrkdata", body, fixed = TRUE)),
              info = "Generated script must reference 013_wrkdata")

  # The pre-#28 broken defaults must not leak through.
  expect_false(any(grepl("011_input", body, fixed = TRUE)),
               info = "Pre-#28 default 011_input leaked into generated script")
  expect_false(any(grepl("013_output", body, fixed = TRUE)),
               info = "Pre-#28 default 013_output leaked into generated script")
})

test_that("create_dw_sector_script sentinel uses projectFolder (#28)", {
  d <- local_tempdir()
  path <- create_dw_sector_script(
    sector_name  = "WASH",
    sector_code  = "ws",
    project_root = d
  )
  body <- readLines(path, warn = FALSE)

  # The generated profile-loaded check must reference an actually-defined
  # global from profile_DW-Production.R (projectFolder is one such global).
  good_sentinel <- "exists(\"projectFolder\""
  bad_sentinel  <- "exists(\"profile_DW_Production\""
  expect_true(
    any(grepl(good_sentinel, body, fixed = TRUE)),
    info = "Sentinel check should reference projectFolder"
  )
  expect_false(
    any(grepl(bad_sentinel, body, fixed = TRUE)),
    info = paste(
      "Generated script still references the never-defined",
      "profile_DW_Production sentinel (pre-#28 bug)."
    )
  )
})
