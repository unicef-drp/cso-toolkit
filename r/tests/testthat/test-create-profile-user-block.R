# create_profile(): the generated profile reads the user's block of
# ~/.config/user_config.yml (DW-Production's template nests each person's
# settings under their user name), falls back to top-level keys, resolves
# dw_mode as dw_mode_by_project[[repo]] then dw_mode, stops with the YAML to
# add when neither is set, and never installs packages. review_profile()
# warns on a profile that reads top-level keys only.

profile_rscript <- function() {
  file.path(R.home("bin"), if (.Platform$OS.type == "windows") "Rscript.exe" else "Rscript")
}

# Generate a profile for `repo` whose packages block needs only yaml (the
# template's dplyr / tidyr / readr are placeholders for the pipeline's own).
make_profile <- function(repo = "proj-x", .frame = parent.frame()) {
  out <- withr::local_tempdir(.local_envir = .frame)
  p <- create_profile(repo, output_path = out, verbose = FALSE)
  src <- readLines(p, warn = FALSE)
  src <- sub('^required_pkgs <- c\\(.*\\)$', 'required_pkgs <- c("yaml")', src)
  writeLines(src, p)
  normalizePath(p, winslash = "/")
}

# Source the profile in a fresh R process, as user `username`, with
# `config` (lines, or NULL for no file) as ~/.config/user_config.yml.
run_profile <- function(profile, config, username = "tester") {
  home <- withr::local_tempdir()
  dir.create(file.path(home, ".config"))
  if (!is.null(config)) writeLines(config, file.path(home, ".config", "user_config.yml"))
  code <- sprintf("source('%s'); cat('MODE=', dw_mode, ' APIS=', dw_apis_allowed, '\\n', sep = '')", profile)
  out <- withr::with_envvar(
    c(USERNAME = username, USER = username,
      USERPROFILE = normalizePath(home, winslash = "/")),
    suppressWarnings(system2(profile_rscript(), c("--no-init-file", "-e", shQuote(code)),
                             stdout = TRUE, stderr = TRUE)))
  list(status = attr(out, "status") %||% 0L, out = paste(out, collapse = "\n"))
}

test_that("dw_mode comes from the user's block", {
  skip_if_not_installed("yaml")
  p <- make_profile()
  r <- run_profile(p, c("tester:", '  dw_mode: "reviewer"', "someone_else:", '  dw_mode: "producer"'))
  expect_identical(r$status, 0L, info = r$out)
  expect_match(r$out, "MODE=reviewer APIS=FALSE")
})

test_that("dw_mode_by_project for this repository wins over dw_mode", {
  skip_if_not_installed("yaml")
  p <- make_profile()
  r <- run_profile(p, c("tester:", '  dw_mode: "reviewer"', "  dw_mode_by_project:",
                        '    proj-x: "producer"', '    other-repo: "reviewer"'))
  expect_identical(r$status, 0L, info = r$out)
  expect_match(r$out, "MODE=producer APIS=TRUE")
})

test_that("top-level keys are the fallback (flat user_config.yml)", {
  skip_if_not_installed("yaml")
  p <- make_profile()
  r <- run_profile(p, 'dw_mode: "producer"')
  expect_identical(r$status, 0L, info = r$out)
  expect_match(r$out, "MODE=producer")
})

test_that("no dw_mode stops with the YAML to add, the user name filled in", {
  skip_if_not_installed("yaml")
  p <- make_profile()
  r <- run_profile(p, c("someone_else:", '  dw_mode: "producer"'))
  expect_false(identical(r$status, 0L))
  expect_match(r$out, "No valid dw_mode", fixed = TRUE)
  expect_match(r$out, 'tester:\n        dw_mode: "reviewer"', fixed = TRUE)
  expect_match(r$out, 'dw_mode_by_project:\n          proj-x: "producer"', fixed = TRUE)
  expect_false(grepl("MODE=", r$out, fixed = TRUE))

  bad <- run_profile(p, c("tester:", '  dw_mode_by_project: "producer"'))
  expect_false(identical(bad$status, 0L))
  expect_match(bad$out, "must map project names", fixed = TRUE)
})

test_that("the profile never installs packages; a missing one stops with the list", {
  out <- withr::local_tempdir()
  p <- create_profile("proj-x", output_path = out, verbose = FALSE)
  expect_false("install.packages" %in% all.names(parse(p)))
  src <- readLines(p, warn = FALSE)
  src <- sub('^required_pkgs <- c\\(.*\\)$',
             'required_pkgs <- c("yaml", "notapackage.cso123")', src)
  writeLines(src, p)
  skip_if_not_installed("yaml")
  r <- run_profile(normalizePath(p, winslash = "/"), c("tester:", '  dw_mode: "reviewer"'))
  expect_false(identical(r$status, 0L))
  expect_match(r$out, "Missing R package(s): notapackage.cso123", fixed = TRUE)
  expect_match(r$out, 'install.packages(c("notapackage.cso123"))', fixed = TRUE)
})

test_that("review_profile passes the user-block read and warns on top-level only", {
  out <- withr::local_tempdir()
  p <- create_profile("proj-x", output_path = out, verbose = FALSE)
  rev <- review_profile(p, verbose = FALSE)
  expect_identical(rev$status[rev$check == "User block in user_config.yml"], "pass")
  expect_false(any(rev$status == "fail"))

  # A profile written before the fix: dw_mode read at the top level only.
  old <- file.path(out, "profile_old.R")
  writeLines(c("set.seed(1)", 'USERNAME <- Sys.getenv("USERNAME")',
               'user_config <- yaml::read_yaml("~/.config/user_config.yml")',
               "dw_mode <- user_config$dw_mode",
               'if (!dw_mode %in% c("producer", "reviewer")) stop("x")',
               "dw_require_no_api <- function() NULL",
               "library(yaml)", "profile_old <- TRUE"), old)
  rev_old <- review_profile(old, verbose = FALSE)
  row <- rev_old[rev_old$check == "User block in user_config.yml", ]
  expect_identical(row$status, "warn")
  expect_match(row$detail, "top-level keys only", fixed = TRUE)
})
