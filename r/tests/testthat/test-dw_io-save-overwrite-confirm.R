# Producer overwrite confirmation: overwriting an EXISTING producer deposit
# requires interactive confirmation or force = TRUE; a non-interactive run
# without force stops. Reviewer sandbox overwrites are NOT gated.

test_that("producer non-interactive overwrite without force stops", {
  canonical <- local_tempdir()
  local_state(teamsFolderCanonical = canonical, dw_mode = "producer")
  path <- file.path(canonical, "x.csv")
  dw_save(data.frame(a = 1, b = 2), path = path)   # first write -- no existing deposit
  expect_true(file.exists(path))

  err <- tryCatch(
    dw_save(data.frame(a = 9, b = 9), path = path, overwrite = TRUE),
    error = identity
  )
  expect_s3_class(err, "error")
  expect_match(conditionMessage(err), "non-interactively|force")
})

test_that("producer overwrite with force = TRUE replaces the deposit", {
  canonical <- local_tempdir()
  local_state(teamsFolderCanonical = canonical, dw_mode = "producer")
  path <- file.path(canonical, "x.csv")
  dw_save(data.frame(a = 1, b = 2), path = path)
  out <- dw_save(data.frame(a = 9, b = 9), path = path,
                 overwrite = TRUE, force = TRUE)
  expect_true(file.exists(out))
  back <- as.data.frame(dw_use(out))
  expect_equal(back$a, 9)
})

test_that("reviewer sandbox overwrite is not gated (no prompt, no error)", {
  tdir <- local_tempdir()
  local_state(teamsWrkData = tdir, dw_mode = "reviewer")
  path <- file.path(tdir, "ed", "x.csv")
  dw_save(data.frame(a = 1, b = 2), path = path)
  out <- dw_save(data.frame(a = 9, b = 9), path = path)  # overwrite = TRUE (reviewer default)
  expect_true(file.exists(out))
  back <- utils::read.csv(out)
  expect_equal(back$a, 9)
})
