# #25 regression: dw_save's `.gz` suffix must be applied BEFORE the
# remote mirror destinations are computed. Pre-fix, the mirror paths
# captured the un-suffixed name, so:
#   - compressed bytes landed at the mirror under a filename without .gz
#   - the overwrite check looked for the un-suffixed mirror and missed
#     any existing .gz mirror at the destination.
# These tests pin the fix from the producer-mode perspective: when
# compress = TRUE OR the path already ends in .gz, the resolved Teams
# and Z: mirror paths must carry the same suffix as the primary write.

test_that("dw_save: Teams mirror carries .gz when compress = TRUE (#25)", {
  primary <- local_tempdir()
  canonical <- local_tempdir()
  local_state(
    teamsWrkData          = primary,
    teamsWrkDataCanonical = canonical,
    teamsFolder           = primary,
    teamsFolderCanonical  = canonical,
    dw_mode               = "producer"
  )
  df <- data.frame(a = 1:3, b = letters[1:3], stringsAsFactors = FALSE)
  out <- dw_save(df,
                 path = file.path(primary, "sector", "out.csv"),
                 compress = TRUE)

  # Primary lands at out.csv.gz
  expect_true(endsWith(out, ".csv.gz"))
  expect_true(file.exists(out))

  # Teams mirror must also have .csv.gz (NOT bare .csv).
  teams_mirror <- file.path(canonical, "sector", "out.csv.gz")
  teams_mirror_bare <- file.path(canonical, "sector", "out.csv")
  expect_true(file.exists(teams_mirror),
              info = "Teams mirror is missing the .gz suffix the primary write has")
  expect_false(file.exists(teams_mirror_bare),
               info = "Pre-fix: compressed bytes were written to bare .csv name at mirror")
})

test_that("dw_save: Teams mirror keeps .gz when path already ends in .gz (#25)", {
  primary <- local_tempdir()
  canonical <- local_tempdir()
  local_state(
    teamsWrkData          = primary,
    teamsWrkDataCanonical = canonical,
    teamsFolder           = primary,
    teamsFolderCanonical  = canonical,
    dw_mode               = "producer"
  )
  df <- data.frame(x = 1:3)
  out <- dw_save(df,
                 path = file.path(primary, "sector", "explicit.csv.gz"))

  expect_true(endsWith(out, ".csv.gz"))
  expect_true(file.exists(file.path(canonical, "sector", "explicit.csv.gz")))
})

test_that("dw_save: overwrite check sees the .gz mirror (#25)", {
  primary <- local_tempdir()
  canonical <- local_tempdir()
  local_state(
    teamsWrkData          = primary,
    teamsWrkDataCanonical = canonical,
    teamsFolder           = primary,
    teamsFolderCanonical  = canonical,
    dw_mode               = "producer"
  )
  df <- data.frame(a = 1:3)

  # Plant a pre-existing .gz file at the mirror destination.
  dir.create(file.path(canonical, "sector"), recursive = TRUE, showWarnings = FALSE)
  file.create(file.path(canonical, "sector", "collide.csv.gz"))

  # Default overwrite (FALSE in producer mode) must catch the .gz mirror
  # collision now that mirror paths share the .gz suffix.
  expect_error(
    dw_save(df,
            path = file.path(primary, "sector", "collide.csv"),
            compress = TRUE),
    regexp = "[cC]anonical|exists|overwrite"
  )
})
