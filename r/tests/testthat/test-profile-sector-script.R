# A sector script scaffolded by create_sector_script() runs against a profile
# scaffolded by create_profile() (#236): the profile sets rootFolder (the
# working directory unless set first) and projectFolder, which the script
# builds its input and output paths from.

test_that("a scaffolded sector script runs against a create_profile() profile (#236)", {
  skip_if_not_installed("yaml")
  repo <- normalizePath(withr::local_tempdir(), winslash = "/")
  p <- create_profile("proj-x", output_path = repo, verbose = FALSE)
  src <- readLines(p, warn = FALSE)
  writeLines(sub("^required_pkgs <- c\\(.*\\)$", 'required_pkgs <- c("yaml")', src), p)
  s <- create_sector_script("Water", "ws", base_dir = repo,
                            profile_file = basename(p), verbose = FALSE)

  home <- withr::local_tempdir()
  dir.create(file.path(home, ".config"))
  writeLines(c("tester:", '  dw_mode: "reviewer"'), file.path(home, ".config", "user_config.yml"))
  code <- sprintf("setwd('%s'); source('%s'); source('%s'); cat('PF=', projectFolder, sep = '')",
                  repo, normalizePath(p, winslash = "/"), normalizePath(s, winslash = "/"))
  rscript <- file.path(R.home("bin"), if (.Platform$OS.type == "windows") "Rscript.exe" else "Rscript")
  out <- withr::with_envvar(
    c(USERNAME = "tester", USER = "tester", USERPROFILE = normalizePath(home, winslash = "/")),
    suppressWarnings(system2(rscript, c("--no-init-file", "-e", shQuote(code)),
                             stdout = TRUE, stderr = TRUE)))
  txt <- paste(out, collapse = "\n")
  status <- attr(out, "status")
  expect_true(is.null(status) || identical(status, 0L), info = txt)
  expect_match(txt, paste0("PF=", repo), fixed = TRUE)
  expect_true(dir.exists(file.path(repo, "01_dw_prep", "013_wrkdata", "ws")), info = txt)
})

test_that("the profile keeps a rootFolder set before it is sourced", {
  repo <- withr::local_tempdir()
  p <- create_profile("proj-x", output_path = repo, verbose = FALSE)
  src <- readLines(p, warn = FALSE)
  expect_true(any(src == 'if (!exists("rootFolder")) rootFolder <- getwd()'))
  expect_true(any(src == "projectFolder <- rootFolder"))
})
