#---------------------------------------------------------------------
# tests/manual/check_consumer_side.R
#---------------------------------------------------------------------
# Purpose : Simulate a consumer repo using cso-toolkit as a vendored
#           dependency, then exercise `cso_toolkit_check()` end-to-end.
#
# What this script does:
#   1. Creates a tempdir layout mirroring a consumer repo
#      (<tmp>/00_functions/{dw_io.R, dw_api.R, cso_toolkit_sync.R,
#                           .toolkit_manifest.yml}).
#   2. Copies the canonical helpers from this repo into that tempdir
#      (so we exercise the real code, not a stub).
#   3. Sources the helpers, sets `dwFunct` so the manifest lookup
#      finds the tempdir, sets `dw_apis_allowed <- TRUE` so the
#      reviewer-mode guard does not short-circuit, and calls
#      `cso_toolkit_check(quiet = FALSE)`.
#   4. Asserts the return value shape (named list with `source`,
#      `pinned_version`, `upstream_version`, `updates_available`).
#
# Usage:
#   # From the repo root:
#   Rscript r/tests/manual/check_consumer_side.R
#
# Why "manual": this script hits api.github.com (or gh CLI) for the
# upstream tag lookup. It is therefore network-dependent and is not part
# of the unit-test suite; run it as a release-eve smoke test.
#---------------------------------------------------------------------

stopifnot(file.exists("r/R/cso_toolkit_sync.R"))

tmp_consumer <- file.path(tempdir(), "consumer_repo")
dir.create(file.path(tmp_consumer, "00_functions"),
           recursive = TRUE, showWarnings = FALSE)

vendored_files <- c("dw_io.R", "dw_api.R", "cso_toolkit_sync.R")
for (f in vendored_files) {
  file.copy(file.path("r", "R", f),
            file.path(tmp_consumer, "00_functions", f),
            overwrite = TRUE)
}

# Drop the template manifest into the simulated consumer repo
file.copy("templates/.toolkit_manifest.yml",
          file.path(tmp_consumer, "00_functions", ".toolkit_manifest.yml"),
          overwrite = TRUE)

# Source the vendored helpers in the same order a profile_<repo>.R would
for (f in vendored_files) {
  source(file.path(tmp_consumer, "00_functions", f))
}

# Point the manifest resolver at the simulated repo
dwFunct <- file.path(tmp_consumer, "00_functions")

# Producer mode (cso_toolkit_check refuses to call out under reviewer)
dw_apis_allowed <- TRUE

cat("\n== cso_toolkit_check (verbose) ==\n")
res <- cso_toolkit_check(quiet = FALSE)
cat("\n== Result ==\n")
print(res)

# Shape assertion — non-null, named list with the expected keys.
if (is.null(res)) {
  cat("\nNote: cso_toolkit_check returned NULL.\n",
      "  Likely reason: upstream tag lookup failed (no gh / no httr / offline).\n",
      "  This is acceptable for the smoke test as long as no error was raised.\n",
      sep = "")
} else {
  expected <- c("source", "pinned_version", "upstream_version",
                "updates_available", "updated_files")
  missing  <- setdiff(expected, names(res))
  if (length(missing)) {
    stop("FAIL: result missing keys: ", paste(missing, collapse = ", "))
  }
  cat("\nOK: shape matches expected (", paste(expected, collapse = ", "), ").\n",
      sep = "")
}

cat("\nConsumer-side smoke test complete.\n")
