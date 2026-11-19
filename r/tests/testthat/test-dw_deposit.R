# Regression suite for dw_fetch_inputs() and dw_check_deposit() -- fetch
# pipeline inputs kept out of Git from the canonical deposit (Teams / Z:) and
# verify every local input has an identical deposited copy. Each test builds
# a self-contained local / Teams / Z: tempdir fixture (no real Teams sync or
# Z: mount is touched).

REL <- file.path("02_consultations", "023_targets", "inputs")
PATTERN <- "_20(23|24|25)\\.(csv|txt)$"

setup_deposit_fixture <- function(env = parent.frame(), z = FALSE) {
  root <- tempfile("dwdeposit_")
  dir.create(root, recursive = TRUE)
  teams_root <- file.path(root, "teams")
  z_root <- file.path(root, "z")
  local_root <- file.path(root, "repo", REL)
  dir.create(file.path(teams_root, REL), recursive = TRUE)
  dir.create(file.path(z_root, REL), recursive = TRUE)
  dir.create(local_root, recursive = TRUE)
  writeLines("# not an input", file.path(local_root, "README.md"))

  local_state(
    dw_mode              = "reviewer",
    teamsFolderCanonical = teams_root,
    dwZDrive             = if (z) z_root else NA_character_,
    dw_z_available       = z,
    .frame               = env
  )
  withr::defer(unlink(root, recursive = TRUE, force = TRUE), envir = env)

  files <- list(
    "2024/NUTRITION_2024.csv" = "Country,Value\nAFG,1\nBGD,2\n",
    "2025/WASH_2025.csv"      = "Country,Value\nAFG,3\n"
  )
  list(root = root, teams_root = teams_root, z_root = z_root,
       local_root = local_root, files = files)
}

put <- function(dir, files) {
  for (f in names(files)) {
    p <- file.path(dir, f)
    dir.create(dirname(p), recursive = TRUE, showWarnings = FALSE)
    writeLines(files[[f]], p)
  }
}

deposit <- function(fx, where = "teams", files = fx$files) {
  put(file.path(if (where == "teams") fx$teams_root else fx$z_root, REL), files)
}

sha <- function(p) digest::digest(file = p, algo = "sha256")

test_that("D1: empty local folder is filled from Teams, copies verified (#dw_fetch_inputs)", {
  fx <- setup_deposit_fixture()
  deposit(fx)
  m <- dw_fetch_inputs(fx$local_root, REL, pattern = PATTERN, verbose = FALSE)

  expect_setequal(m$file, names(fx$files))
  expect_true(all(m$origin == "copied from Teams"))
  expect_true(all(file.exists(file.path(fx$local_root, names(fx$files)))))
  for (i in seq_len(nrow(m))) {
    expect_identical(m$sha256[i], sha(file.path(fx$teams_root, REL, m$file[i])))
  }
  expect_true(all(m$teams == "match"))
  expect_false(any(file.exists(paste0(m$path, ".dw_fetch.tmp"))))
})

test_that("D2: Z: is preferred as the copy source when it is available", {
  fx <- setup_deposit_fixture(z = TRUE)
  deposit(fx, "teams"); deposit(fx, "z")
  m <- dw_fetch_inputs(fx$local_root, REL, pattern = PATTERN, verbose = FALSE)
  expect_true(all(m$origin == "copied from Z:"))
  expect_true(all(m$z == "match" & m$teams == "match"))
})

test_that("D3: copy = FALSE reads deposit files in place and leaves local untouched", {
  fx <- setup_deposit_fixture()
  deposit(fx)
  m <- dw_fetch_inputs(fx$local_root, REL, pattern = PATTERN, copy = FALSE,
                       verbose = FALSE)
  expect_true(all(m$origin == "read from Teams"))
  expect_true(all(startsWith(normalizePath(m$path, winslash = "/"),
                             normalizePath(fx$teams_root, winslash = "/"))))
  expect_identical(list.files(fx$local_root, recursive = TRUE), "README.md")
  # the folder layout is still mirrored locally, data files are not
  expect_true(file.exists(file.path(fx$local_root, "2024", ".gitkeep")))
})

test_that("D4: a partial local set is completed; existing local files are verified", {
  fx <- setup_deposit_fixture()
  deposit(fx)
  put(fx$local_root, fx$files[1])
  m <- dw_fetch_inputs(fx$local_root, REL, pattern = PATTERN, verbose = FALSE)
  expect_identical(m$origin[m$file == names(fx$files)[1]], "local")
  expect_identical(m$origin[m$file == names(fx$files)[2]], "copied from Teams")
})

test_that("D5: a local file that differs from the deposit stops with an envelope", {
  fx <- setup_deposit_fixture()
  deposit(fx)
  put(fx$local_root, list("2024/NUTRITION_2024.csv" = "Country,Value\nAFG,999\n"))
  err <- expect_error(
    dw_fetch_inputs(fx$local_root, REL, pattern = PATTERN, verbose = FALSE))
  expect_envelope(err, "dw_check_deposit")
  expect_match(conditionMessage(err), "differs")
})

test_that("D6: a local file missing from the deposit stops with an envelope", {
  fx <- setup_deposit_fixture()
  put(fx$local_root, fx$files)
  deposit(fx, files = fx$files[1])
  err <- expect_error(
    dw_fetch_inputs(fx$local_root, REL, pattern = PATTERN, verbose = FALSE))
  expect_envelope(err, "dw_check_deposit")
  expect_match(conditionMessage(err), "missing")
})

test_that("D7: Teams and Z: disagreeing on a file is a stop", {
  fx <- setup_deposit_fixture(z = TRUE)
  deposit(fx, "teams")
  deposit(fx, "z", files = list("2024/NUTRITION_2024.csv" = "Country,Value\nAFG,7\n"))
  err <- expect_error(
    dw_fetch_inputs(fx$local_root, REL, pattern = PATTERN, verbose = FALSE))
  expect_envelope(err, "dw_fetch_inputs")
  expect_match(conditionMessage(err), "different versions")
  expect_identical(list.files(fx$local_root, recursive = TRUE), "README.md")
})

test_that("D8: no input anywhere is a stop; README.md is not an input", {
  fx <- setup_deposit_fixture()
  err <- expect_error(
    dw_fetch_inputs(fx$local_root, REL, pattern = PATTERN, verbose = FALSE))
  expect_envelope(err, "dw_fetch_inputs")
  expect_match(conditionMessage(err), "No input files")
})

test_that("D9: local inputs with no reachable deposit cannot be verified", {
  fx <- setup_deposit_fixture()
  put(fx$local_root, fx$files)
  local_state(teamsFolderCanonical = NA_character_, dw_z_available = FALSE)
  err <- expect_error(
    dw_fetch_inputs(fx$local_root, REL, pattern = PATTERN, verbose = FALSE))
  expect_envelope(err, "dw_check_deposit")
})

test_that("D10: dw_check_deposit(stop_on_fail = FALSE) returns the report", {
  fx <- setup_deposit_fixture()
  put(fx$local_root, fx$files)
  deposit(fx, files = fx$files[1])
  paths <- file.path(fx$local_root, names(fx$files))
  rep <- dw_check_deposit(paths, fx$local_root, REL, stop_on_fail = FALSE,
                          verbose = FALSE)
  expect_identical(rep$ok, c(TRUE, FALSE))
  expect_identical(rep$teams, c("match", "missing"))
  expect_identical(rep$z, c("no access", "no access"))
})

test_that("D11: explicit teams_root / z_root override the session globals", {
  fx <- setup_deposit_fixture()
  deposit(fx)
  local_state(teamsFolderCanonical = NA_character_, dw_z_available = FALSE)
  m <- dw_fetch_inputs(fx$local_root, REL, pattern = PATTERN,
                       teams_root = fx$teams_root, verbose = FALSE)
  expect_true(all(m$origin == "copied from Teams"))
})

test_that("D13: gitkeep (default) keeps every local and deposit folder visible", {
  fx <- setup_deposit_fixture()
  deposit(fx)
  dir.create(file.path(fx$teams_root, REL, "2023"))       # empty deposit folder
  dir.create(file.path(fx$local_root, "notes"))          # local-only folder
  m <- dw_fetch_inputs(fx$local_root, REL, pattern = PATTERN, verbose = FALSE)

  for (d in c("", "2023", "2024", "2025", "notes")) {
    expect_true(file.exists(file.path(fx$local_root, d, ".gitkeep")), info = d)
  }
  expect_false(any(grepl("gitkeep", m$file)))
  # idempotent: a second run neither fails nor lists .gitkeep as an input
  m2 <- dw_fetch_inputs(fx$local_root, REL, pattern = PATTERN, verbose = FALSE)
  expect_identical(m2$file, m$file)
})

test_that("D14: gitkeep = FALSE creates no placeholder; pattern = NULL ignores .gitkeep", {
  fx <- setup_deposit_fixture()
  deposit(fx)
  writeLines("", file.path(fx$teams_root, REL, ".gitkeep"))
  unlink(file.path(fx$local_root, "README.md"))
  m <- dw_fetch_inputs(fx$local_root, REL, gitkeep = FALSE, verbose = FALSE)
  expect_setequal(m$file, names(fx$files))
  expect_length(list.files(fx$local_root, pattern = "^\\.gitkeep$",
                           recursive = TRUE, all.files = TRUE), 0)
})

test_that("D12: a path outside local_root is rejected", {
  fx <- setup_deposit_fixture()
  outside <- file.path(fx$root, "elsewhere.csv")
  writeLines("x", outside)
  err <- expect_error(dw_check_deposit(outside, fx$local_root, REL, verbose = FALSE))
  expect_envelope(err, "dw_check_deposit")
})
