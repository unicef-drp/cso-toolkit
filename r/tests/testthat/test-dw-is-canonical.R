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

# =============================================================================
# #61.2 — extend coverage to the canon_roots branch (the runtime-resolved
# teams{Wrk,Raw,Folder}Canonical globals). Pre-v0.4.7 the test file only
# exercised the OneDrive-UNC literal-regex branch and the generic negative,
# so a regression in the canon_roots path could have shipped silently.
# =============================================================================

test_that("dw_is_canonical: path under teamsWrkDataCanonical is canonical", {
  root <- "C:/Users/test/dw-canonical/01_dw_prep/013_wrkdata"
  local_state(teamsWrkDataCanonical = root)
  expect_true(dw_is_canonical(file.path(root, "im", "2024", "dw_im.csv")))
})

test_that("dw_is_canonical: path under teamsRawDataCanonical is canonical", {
  root <- "C:/Users/test/dw-canonical/01_dw_prep/011_rawdata"
  local_state(teamsRawDataCanonical = root)
  expect_true(dw_is_canonical(file.path(root, "hva", "2024", "raw_hiv.csv")))
})

test_that("dw_is_canonical: path under teamsFolderCanonical is canonical", {
  root <- "C:/Users/test/dw-canonical"
  local_state(teamsFolderCanonical = root)
  expect_true(dw_is_canonical(file.path(root, "00_master", "013_wrkdata", "x.csv")))
})

test_that("dw_is_canonical: equality (path IS the canonical root) is canonical", {
  root <- "C:/Users/test/dw-canonical"
  local_state(teamsFolderCanonical = root)
  expect_true(dw_is_canonical(root))
})

test_that("dw_is_canonical: sibling-spoof path is NOT canonical", {
  # A path that shares a common prefix with the canonical root but lives
  # under a sibling directory (e.g. `/data/wrk-canary/...` vs canonical
  # `/data/wrk-can`) must NOT be classified as canonical. The
  # implementation guards against this by requiring an exact match OR a
  # `root + "/"` prefix, NOT a bare startsWith. (See the inline comment
  # on the path-aware descendant check in dw_io.R::dw_is_canonical.)
  root <- "C:/Users/test/dw-can"
  local_state(teamsFolderCanonical = root)
  expect_false(dw_is_canonical("C:/Users/test/dw-canary/01_dw_prep/x.csv"))
})

test_that("dw_is_canonical: no canonical globals set returns FALSE", {
  # When the profile has no canonical-root globals, only the OneDrive
  # literal regex remains. A generic repo-local path that doesn't match
  # the UNC pattern must return FALSE.
  local_state(
    teamsWrkDataCanonical  = NA_character_,
    teamsRawDataCanonical  = NA_character_,
    teamsFolderCanonical   = NA_character_
  )
  expect_false(dw_is_canonical("C:/tmp/some-local/01_dw_prep/x.csv"))
})
