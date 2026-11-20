# Shared test helpers. testthat sources every helper-*.R before the tests.
#
# Fixtures live in tests/testthat/fixtures/: tiny (a few rows), synthetic
# (made-up values, never real survey or country data) and committed. CI has
# no access to the deposit, so a test that needs real data does not belong
# in this suite; reproduce it locally in reviewer mode instead.

#' Path to a fixture file
fixture_path <- function(...) testthat::test_path("fixtures", ...)

#' Read a CSV fixture
#'
#' Raw read on purpose: fixtures are test inputs, not deposits, so they do
#' not go through dw_use(). The trailing allow comment tells the contract
#' auditor (test_scripts) this line is a documented exception.
read_fixture <- function(name) {
  utils::read.csv(fixture_path(name), stringsAsFactors = FALSE, strip.white = FALSE)  # cso-allow: io-read-csv
}

#' A temporary folder removed when the calling test ends
local_tempdir <- function(.frame = parent.frame()) {
  d <- tempfile("test_")
  dir.create(d, recursive = TRUE)
  withr::defer(unlink(d, recursive = TRUE, force = TRUE), envir = .frame)
  d
}

#' Set session globals (dw_mode, teamsWrkData, ...) for one test, then restore
#'
#' The toolkit reads its session state from .GlobalEnv (set by the profile),
#' so tests that exercise a helper set that state here and put it back.
local_dw_state <- function(..., .frame = parent.frame()) {
  new <- list(...)
  had <- vapply(names(new), exists, logical(1), envir = globalenv(), inherits = FALSE)
  old <- lapply(names(new), function(k) if (had[[k]]) get(k, envir = globalenv()))
  names(old) <- names(new)
  for (k in names(new)) assign(k, new[[k]], envir = globalenv())
  withr::defer({
    for (k in names(new)) {
      if (had[[k]]) assign(k, old[[k]], envir = globalenv())
      else if (exists(k, envir = globalenv(), inherits = FALSE)) rm(list = k, envir = globalenv())
    }
  }, envir = .frame)
  invisible(NULL)
}

#' Assert an error follows the WHAT / Why / Fix envelope
#'
#' Same shape as cso-toolkit's own errors: a `[<scope>.<function>]` prefix
#' and a `Fix:` line. Pass `function_name` to pin the function.
expect_envelope <- function(message, function_name = NULL) {
  if (is.null(message)) return(testthat::fail("no error was raised"))
  if (inherits(message, "condition")) message <- conditionMessage(message)
  testthat::expect_match(message, "^\\[[A-Za-z0-9_]+\\.[A-Za-z0-9_.:]+\\]")
  testthat::expect_match(message, "Fix:", fixed = TRUE)
  if (!is.null(function_name)) {
    testthat::expect_match(message, paste0(".", function_name, "]"), fixed = TRUE)
  }
  invisible(TRUE)
}
