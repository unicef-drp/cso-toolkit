# Regression tests for issue #54 — dw_is_canonical() must recognise the
# OneDrive-mounted Teams Documents path so reviewer-mode mode-lock cannot
# overwrite canonical artifacts via that route. Today's audit found that
# HVA + ED reviewer-mode runs were writing through to canonical because
# the v0.4.5 check only looked at Z: + teamsFolder globals and missed
# the per-user OneDrive UNC pattern.

test_that("dw_is_canonical recognises OneDrive-mounted Teams Documents path", {
  p <- "C:/Users/jpazevedo/UNICEF/Chief Statistician Office - Documents/060.DW-MASTER/01_dw_prep/013_wrkdata/hva/2025/dw_hiv.csv"
  expect_true(dw_is_canonical(p))
})

test_that("dw_is_canonical handles backslash variant", {
  p <- "C:\\Users\\jpazevedo\\UNICEF\\Chief Statistician Office - Documents\\060.DW-MASTER\\01_dw_prep\\013_wrkdata\\hva\\dw_hiv.csv"
  expect_true(dw_is_canonical(p))
})

test_that("dw_is_canonical does not flag repo-local paths", {
  p <- "c:/tmp/test/01_dw_prep/013_wrkdata/_local/im/output/DW_IM_HELIX.csv"
  expect_false(dw_is_canonical(p))
})
