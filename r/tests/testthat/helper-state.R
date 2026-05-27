# Shared fixtures for the testthat suite.
#
# Session-level state in cso-toolkit lives as bindings in .GlobalEnv
# (set by the consumer's profile_<repo>.R at session start).  Tests
# need to (a) set known values before exercising a helper and
# (b) restore the previous state afterwards so test order is
# irrelevant.

# Globals the toolkit reads via `.try_get()` — kept in sync with the
# Python `_state._PUBLIC_KEYS`.
.STATE_KEYS <- c(
  "teamsWrkData", "teamsRawData", "dwMetaData",
  "teamsFolder", "teamsFolderCanonical",
  "teamsWrkDataCanonical", "teamsRawDataCanonical",
  "dw_mode", "dw_apis_allowed",
  "dwZDrive", "dw_z_available",
  "dwFunct",
  "dw_url_allowlist", "dw_frozen_root", "githubFolder"
)

#' Snapshot current globals, assign new values, restore on test exit
#'
#' Used inside a `test_that()` block.  Pass keyword args matching the
#' state keys; the named globals are set in `.GlobalEnv` for the
#' duration of the test and restored on exit.  Unknown keys raise
#' immediately so typos surface.
local_state <- function(..., .frame = parent.frame()) {
  new <- list(...)
  unknown <- setdiff(names(new), .STATE_KEYS)
  if (length(unknown) > 0) {
    stop("local_state(): unknown state keys: ",
         paste(unknown, collapse = ", "), call. = FALSE)
  }
  # Snapshot current bindings (and whether they existed at all)
  snapshot <- lapply(.STATE_KEYS, function(k) {
    list(existed = exists(k, envir = .GlobalEnv, inherits = FALSE),
         value = if (exists(k, envir = .GlobalEnv, inherits = FALSE))
                   get(k, envir = .GlobalEnv) else NULL)
  })
  names(snapshot) <- .STATE_KEYS

  # Apply new bindings
  for (k in names(new)) {
    assign(k, new[[k]], envir = .GlobalEnv)
  }

  # Restore on exit of the calling test_that() frame
  withr::defer(
    {
      for (k in .STATE_KEYS) {
        snap <- snapshot[[k]]
        if (snap$existed) {
          assign(k, snap$value, envir = .GlobalEnv)
        } else if (exists(k, envir = .GlobalEnv, inherits = FALSE)) {
          rm(list = k, envir = .GlobalEnv)
        }
      }
    },
    envir = .frame
  )
  invisible(NULL)
}

#' Create a temp dir that is cleaned up at the end of the calling test
local_tempdir <- function(.frame = parent.frame()) {
  d <- tempfile("cso_test_")
  dir.create(d, recursive = TRUE)
  withr::defer(unlink(d, recursive = TRUE, force = TRUE), envir = .frame)
  d
}

#' Pattern that matches the cso-toolkit three-part error envelope
#' (allow `:suffix` as in `[cso_toolkit.dw_use:remote]`)
.envelope_pattern <- "^\\[cso_toolkit\\.[A-Za-z0-9_.]+([:/][A-Za-z_]+)?\\]"

#' Assert a message follows the WHAT/Why/Fix envelope.
expect_envelope <- function(message, function_name = NULL) {
  if (inherits(message, "condition")) {
    message <- conditionMessage(message)
  }
  testthat::expect_match(
    message, .envelope_pattern,
    info = paste0("expected `[cso_toolkit.<func>]` prefix; got: ",
                  substr(message, 1, 120))
  )
  testthat::expect_match(
    message, "Fix:",
    info = paste0("expected `Fix:` guidance; got: ",
                  substr(message, 1, 200))
  )
  if (!is.null(function_name)) {
    # function_name may contain a literal `:` (e.g. `dw_use:remote`) —
    # treat ANY non-alnum char as a regex metacharacter and escape it.
    fn_pat <- gsub("([^A-Za-z0-9_])", "\\\\\\1", function_name)
    testthat::expect_match(
      message,
      paste0("\\[cso_toolkit\\.", fn_pat, "\\]"),
      info = paste0("expected envelope for `", function_name,
                    "`; got: ", substr(message, 1, 120))
    )
  }
  invisible(TRUE)
}
