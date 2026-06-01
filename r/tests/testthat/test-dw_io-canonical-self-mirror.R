# #26 regression: when a producer write lands directly under
# `teamsFolderCanonical` (e.g., `teamsWrkData == teamsFolderCanonical`,
# a common bootstrap config), `.dw_remote_mirrors()` used to return the
# primary path itself as the Teams mirror destination. dw_save() then
# called `.dw_mirror_to_teams(primary, primary)`, which on Windows
# emits a "file.copy onto self" warning → trapped → re-emitted as
# the alarming "[cso_toolkit.dw_save] Teams mirror FAILED" warning,
# even though nothing failed (and the primary write itself is already
# the canonical artifact, so no separate Teams copy is even needed).
#
# Fix: when primary IS canonical, `.dw_remote_mirrors()` now returns
# `teams = NA_character_` and only sets up Z:. dw_save() then skips
# the Teams mirror block entirely.

test_that("dw_remote_mirrors: teams=NA when primary is canonical (#26)", {
  canonical <- local_tempdir()
  local_state(
    teamsWrkData          = canonical,
    teamsWrkDataCanonical = canonical,
    teamsFolder           = canonical,
    teamsFolderCanonical  = canonical
  )
  primary <- file.path(canonical, "sector", "out.csv")
  m <- csotoolkit:::.dw_remote_mirrors(primary)
  expect_true(
    is.na(m$teams),
    info = paste(
      "Teams mirror must be NA when primary is canonical;",
      "pre-fix it equalled the primary path."
    )
  )
})

test_that("dw_save canonical write emits no Teams-mirror-failed warn (#26)", {
  canonical <- local_tempdir()
  local_state(
    teamsWrkData          = canonical,
    teamsWrkDataCanonical = canonical,
    teamsFolder           = canonical,
    teamsFolderCanonical  = canonical,
    dw_mode               = "producer"
  )
  df <- data.frame(a = 1:3)

  # Capture all warnings raised during the write.
  warns <- character()
  withCallingHandlers(
    dw_save(df,
            path = file.path(canonical, "sector", "out.csv"),
            allow_canonical_write = TRUE),
    warning = function(w) {
      warns <<- c(warns, conditionMessage(w))
      invokeRestart("muffleWarning")
    }
  )

  # No "Teams mirror FAILED" alarm in the warning stream.
  failed <- warns[grepl("Teams mirror FAILED", warns, fixed = TRUE)]
  expect_false(
    length(failed) > 0,
    info = sprintf(
      "Spurious Teams-mirror-failed warning(s): %s",
      paste(failed, collapse = " | ")
    )
  )
})
