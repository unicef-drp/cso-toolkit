# #25 regression: dw_save's `.gz` suffix must be applied BEFORE the
# remote mirror destinations are computed. Pre-fix, the mirror paths
# captured the un-suffixed name, so:
#   - compressed bytes landed at the mirror under a filename without .gz
#   - the overwrite check looked for the un-suffixed mirror and missed
#     any existing .gz mirror at the destination.
# These tests pin the fix from the producer-mode perspective: when
# compress = TRUE OR the path already ends in .gz, the resolved Teams
# mirror path must carry the same suffix as the primary write. (The
# Z: mirror derives from the Teams canonical path via the same string
# transform, so once the Teams contract holds it inherits.)
#
# Each test pins `dw_z_available = FALSE` and `dwZDrive = ""` so the
# producer-mode mirror block doesn't try to touch a real Z: drive on
# a developer's machine where those globals might already be set
# (Copilot, PR #75 hermeticity finding).

test_that("dw_save: Teams mirror carries .gz when compress = TRUE (#25)", {
  primary <- local_tempdir()
  canonical <- local_tempdir()
  local_state(
    teamsWrkData          = primary,
    teamsWrkDataCanonical = canonical,
    teamsFolder           = primary,
    teamsFolderCanonical  = canonical,
    dw_mode               = "producer",
    dw_z_available        = FALSE,
    dwZDrive              = ""
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
              info = "Teams mirror is missing the .gz suffix")
  expect_false(file.exists(teams_mirror_bare),
               info = "Pre-fix: compressed bytes written to bare .csv at mirror")
})

test_that("dw_save: Teams mirror keeps .gz when path already ends in .gz (#25)", {
  primary <- local_tempdir()
  canonical <- local_tempdir()
  local_state(
    teamsWrkData          = primary,
    teamsWrkDataCanonical = canonical,
    teamsFolder           = primary,
    teamsFolderCanonical  = canonical,
    dw_mode               = "producer",
    dw_z_available        = FALSE,
    dwZDrive              = ""
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
    dw_mode               = "producer",
    dw_z_available        = FALSE,
    dwZDrive              = ""
  )
  df <- data.frame(a = 1:3)

  # Plant a pre-existing .gz file at the mirror destination.
  dir.create(file.path(canonical, "sector"), recursive = TRUE, showWarnings = FALSE)
  file.create(file.path(canonical, "sector", "collide.csv.gz"))

  # Default overwrite (FALSE in producer mode) must catch the .gz mirror
  # collision now that mirror paths share the .gz suffix. Match on the
  # gz-suffixed mirror filename to ensure the error is specifically about
  # the .csv.gz collision (Copilot, PR #75).
  expect_error(
    dw_save(df,
            path = file.path(primary, "sector", "collide.csv"),
            compress = TRUE),
    regexp = "collide\\.csv\\.gz"
  )
})
