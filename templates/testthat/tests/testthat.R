# ---------------------------------------------------------------------------
# tests/testthat.R -- run the project's testthat suite (non-package project)
# ---------------------------------------------------------------------------
# Template from unicef-drp/cso-toolkit: templates/testthat/
# Guidance: docs/ci_cd_guidelines.md (Tier 1, R tests).
#
# Run from the repo root (CI runs the same command, ci-r-tests.yml):
#   Rscript tests/testthat.R
#
# What it does:
#   1. puts the session in reviewer mode, so a test that reaches for the
#      network or a canonical deposit fails instead of silently fetching;
#   2. sources the vendored cso-toolkit helpers from TOOLKIT_DIR (dw_io.R
#      first), if the folder exists;
#   3. sources the project's own function files from SOURCE_DIRS;
#   4. runs tests/testthat/ (helper-*.R first, then test-*.R) and exits
#      non-zero when any test fails.
#
# For an R package, do not use this file: R CMD check runs the package's own
# tests/testthat.R (library(testthat); library(<pkg>); test_check("<pkg>")).
# ---------------------------------------------------------------------------

# ---- Edit for your repo ----------------------------------------------------
TOOLKIT_DIR <- "00_functions"   # vendored cso-toolkit helpers
SOURCE_DIRS <- c("R")           # files that DEFINE functions; never scripts
                                # that run an analysis or read data on source
# ---------------------------------------------------------------------------

if (!requireNamespace("testthat", quietly = TRUE) ||
    !requireNamespace("withr", quietly = TRUE)) {
  stop("[tests] testthat and withr are required.\n",
       "  Fix: install.packages(c(\"testthat\", \"withr\"))", call. = FALSE)
}

# Repo root = the folder above tests/, however the runner was invoked.
local({
  args   <- commandArgs(trailingOnly = FALSE)
  script <- sub("^--file=", "", args[grepl("^--file=", args)])
  root   <- if (length(script) == 1) {
    dirname(dirname(normalizePath(script, mustWork = TRUE)))
  } else if (basename(getwd()) == "tests") {
    dirname(getwd())
  } else {
    getwd()
  }
  assign(".test_root", root, envir = globalenv())
})

# 1. Reviewer mode: no API calls, no canonical writes.
assign("dw_mode", "reviewer", envir = globalenv())
assign("dw_apis_allowed", FALSE, envir = globalenv())

# 2. Vendored toolkit helpers (dw_io.R defines internals the others use).
toolkit <- file.path(.test_root, TOOLKIT_DIR)
if (dir.exists(toolkit)) {
  helpers <- list.files(toolkit, pattern = "\\.R$", full.names = TRUE)
  helpers <- helpers[order(basename(helpers) != "dw_io.R", basename(helpers))]
  for (f in helpers) source(f, local = globalenv())
  message("[tests] sourced ", length(helpers), " vendored helper(s) from ", TOOLKIT_DIR, "/")
} else {
  message("[tests] no ", TOOLKIT_DIR, "/ folder; running without the vendored toolkit")
}

# 3. Project functions.
for (d in file.path(.test_root, SOURCE_DIRS)) {
  if (!dir.exists(d)) next
  for (f in sort(list.files(d, pattern = "\\.[Rr]$", full.names = TRUE, recursive = TRUE))) {
    source(f, local = globalenv())
  }
}

# 4. Run the suite; stop_on_failure makes Rscript exit non-zero for CI.
testthat::test_dir(
  file.path(.test_root, "tests", "testthat"),
  load_package    = "none",
  stop_on_failure = TRUE
)
