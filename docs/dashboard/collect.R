#!/usr/bin/env Rscript
# docs/dashboard/collect.R
# -----------------------------------------------------------------------------
# Collect state for the cso-toolkit sector dashboard.
#
# Reads from four sources and assembles a master data/state.json that
# render.R turns into a static SPA.
#
# Sources:
#   (a) UNICEF SDMX        — lightweight reachability probe (url() open +
#                            setTimeLimit), caches the result to
#                            data/sdmx_cache_latest.json on success.
#                            Falls back to cache on network failure.
#                            (rsdmx is checked only as a gate — full SDMX
#                            parsing is not performed by this collector.)
#   (b) cso-toolkit GitHub — `gh api` with GITHUB_TOKEN
#                            (PRs / branches / issues / milestones).
#   (c) DW-Production GH   — `gh api -H Authorization: bearer <PAT>`
#                            with DW_PROD_READ_TOKEN
#                            (same fields as cso-toolkit).
#   (d) Operator snapshots — data/snapshots/teams_snapshot_latest.json
#                          + data/snapshots/replication_<sector>_latest.json
#
# Outputs:
#   - data/state.json
#   - data/history/YYYY-MM-DD/state.json  (point-in-time snapshot)
#
# Idempotent. Tolerant to missing optional sources (each block has its
# own tryCatch and logs a warning).
#
# Required:    gh, jsonlite
# Recommended: rsdmx (SDMX section degrades to "cached" if absent)
# -----------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(jsonlite)
})

# ----- paths --------------------------------------------------------------- #

SCRIPT_DIR     <- local({
  # Under `Rscript path/to/collect.R`, commandArgs() carries `--file=...`.
  # `sys.frame(1)$ofile` is only set when the file is source()d, so the old
  # code silently fell back to getwd() under Rscript and wrote to the wrong dir.
  a <- commandArgs(trailingOnly = FALSE)
  f <- sub("^--file=", "", grep("^--file=", a, value = TRUE))
  if (length(f) == 1L && nzchar(f)) {
    return(dirname(normalizePath(f, winslash = "/")))
  }
  ofile <- tryCatch(sys.frame(1)$ofile, error = function(e) NULL)
  if (!is.null(ofile)) return(dirname(normalizePath(ofile, winslash = "/")))
  getwd()
})
DASHBOARD_DIR  <- SCRIPT_DIR
DATA_DIR       <- file.path(DASHBOARD_DIR, "data")
SNAPSHOTS_DIR  <- file.path(DATA_DIR, "snapshots")
HISTORY_DIR    <- file.path(DATA_DIR, "history")
ACTIONS_DIR    <- file.path(DATA_DIR, "actions")
STATE_PATH     <- file.path(DATA_DIR, "state.json")
SDMX_CACHE     <- file.path(DATA_DIR, "sdmx_cache_latest.json")

dir.create(DATA_DIR,      showWarnings = FALSE, recursive = TRUE)
dir.create(SNAPSHOTS_DIR, showWarnings = FALSE, recursive = TRUE)
dir.create(HISTORY_DIR,   showWarnings = FALSE, recursive = TRUE)
dir.create(ACTIONS_DIR,   showWarnings = FALSE, recursive = TRUE)

TODAY  <- format(Sys.Date(), "%Y-%m-%d")
NOWUTC <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

SECTORS <- c("nt", "hva", "im", "ws", "mnch", "cme", "ed", "wt", "ecd")

log_info <- function(msg)  message(sprintf("[%s] %s", NOWUTC, msg))
log_warn <- function(msg)  message(sprintf("[%s] WARN: %s", NOWUTC, msg))

# ----- helpers ------------------------------------------------------------- #

read_json_safe <- function(path, default = NULL) {
  if (!file.exists(path)) return(default)
  tryCatch(
    jsonlite::fromJSON(path, simplifyVector = FALSE),
    error = function(e) {
      log_warn(sprintf("could not parse %s: %s", path, conditionMessage(e)))
      default
    }
  )
}

write_json <- function(x, path) {
  jsonlite::write_json(
    x,
    path,
    auto_unbox = TRUE,
    pretty     = TRUE,
    null       = "null",
    na         = "null"
  )
}

gh_api <- function(endpoint, token = NULL, paginate = FALSE) {
  # Returns parsed JSON, or NULL on failure.
  cmd  <- "gh"
  # Split "path?a=1&b=2" into a path + `--method GET -f a=1 -f b=2` field args.
  # Passing the raw `?a=1&b=2` query as one arg breaks on Linux runners: R's
  # system2 routes the command through a shell to redirect stdout to a file, and
  # the unescaped `&` backgrounds the command (`gh api ...pulls?state=all &
  # per_page=100 --paginate ...`), so it fails with "sh: --paginate: not found"
  # (exit 127). Field args carry no shell metacharacters; gh re-adds them as the
  # query string. (Works on Windows too, where the `&` happened to be tolerated.)
  parts <- strsplit(endpoint, "?", fixed = TRUE)[[1]]
  args  <- c("api", parts[1])
  if (length(parts) > 1L && nzchar(parts[2])) {
    args <- c(args, "--method", "GET")
    for (kv in strsplit(parts[2], "&", fixed = TRUE)[[1]]) {
      pair <- strsplit(kv, "=", fixed = TRUE)[[1]]
      if (length(pair) == 2L) args <- c(args, "-f", paste0(pair[1], "=", pair[2]))
    }
  }
  # `--slurp` merges the pages of a `--paginate` array endpoint into one JSON
  # value; without it gh concatenates page arrays ([...][...]) into invalid JSON.
  if (paginate) args <- c(args, "--paginate", "--slurp")
  # Authenticate via the GH_TOKEN environment variable (restored afterwards),
  # NOT system2's `env=` argument: on Windows that arg leaks through as a literal
  # `GH_TOKEN=...` command argument (gh then errors "unknown command", echoing
  # the token into logs) and it is shell-fragile. gh reads GH_TOKEN from the env.
  if (!is.null(token) && nzchar(token)) {
    old_tok <- Sys.getenv("GH_TOKEN", unset = NA_character_)
    Sys.setenv(GH_TOKEN = token)
    on.exit({
      if (is.na(old_tok)) Sys.unsetenv("GH_TOKEN") else Sys.setenv(GH_TOKEN = old_tok)
    }, add = TRUE)
  }
  # Capture stdout straight to a temp file and parse the file. Going through
  # system2(stdout = TRUE) splits output into lines whose re-join corrupts JSON
  # on Windows (CRLF + escaped newlines inside PR / issue bodies). Keep stderr
  # in its own temp file so we can log gh's error text on failure.
  out_file <- tempfile("ghapi_out_", fileext = ".json")
  err_file <- tempfile("ghapi_err_")
  on.exit(try(unlink(c(out_file, err_file)), silent = TRUE), add = TRUE)
  status <- tryCatch(
    system2(cmd, args, stdout = out_file, stderr = err_file),
    error = function(e) NA_integer_
  )
  if (!identical(as.integer(status), 0L)) {
    err_msg <- tryCatch(
      paste(readLines(err_file, warn = FALSE), collapse = " | "),
      error = function(e) ""
    )
    # Defensive: never surface a token even if a future error echoes one.
    err_msg <- gsub("gh[oprsu]_[A-Za-z0-9_]+", "<redacted>", err_msg)
    log_warn(sprintf("gh api %s failed (status %s): %s", endpoint, status, err_msg))
    return(NULL)
  }
  if (!file.exists(out_file) || file.info(out_file)$size == 0) return(NULL)
  parsed <- tryCatch(
    jsonlite::fromJSON(out_file, simplifyVector = FALSE),
    error = function(e) {
      log_warn(sprintf("gh api %s: non-JSON output", endpoint))
      NULL
    }
  )
  if (is.null(parsed)) return(NULL)
  # `--paginate --slurp` wraps each page as one element: [[...],[...]].
  # Flatten one level so callers see a flat array of objects, not pages.
  if (paginate && length(parsed) > 0L && is.null(names(parsed)) &&
      is.list(parsed[[1]]) && is.null(names(parsed[[1]]))) {
    parsed <- do.call(c, parsed)
  }
  parsed
}

# ----- (a) UNICEF SDMX ----------------------------------------------------- #

collect_sdmx <- function() {
  log_info("SDMX: starting")
  if (!requireNamespace("rsdmx", quietly = TRUE)) {
    log_warn("SDMX: rsdmx not installed; using cache only")
    cached <- read_json_safe(SDMX_CACHE, default = list())
    return(c(cached, list(source = "cache", note = "rsdmx not installed")))
  }

  endpoints <- list(
    list(name = "unicef_health_status", url = "https://sdmx.data.unicef.org/ws/public/sdmxapi/rest/dataflow/UNICEF/GLOBAL_DATAFLOW/1.0?format=json")
  )

  results <- list()
  ok <- TRUE
  for (ep in endpoints) {
    res <- tryCatch({
      withTimeout <- function(expr, secs) {
        setTimeLimit(elapsed = secs, transient = TRUE)
        on.exit(setTimeLimit(elapsed = Inf, transient = FALSE))
        expr
      }
      withTimeout({
        url <- ep$url
        con <- url(url, "rb")
        on.exit(try(close(con), silent = TRUE), add = TRUE)
        raw <- readLines(con, warn = FALSE, n = 1)
        list(status = "ok", probe_bytes = nchar(paste(raw, collapse = "")))
      }, secs = 15)
    }, error = function(e) {
      list(status = "error", message = conditionMessage(e))
    })

    if (identical(res$status, "ok")) {
      results[[ep$name]] <- list(status = "ok", checked_at = NOWUTC)
    } else {
      ok <- FALSE
      results[[ep$name]] <- list(
        status     = "error",
        message    = res$message,
        checked_at = NOWUTC
      )
    }
  }

  if (ok) {
    out <- list(checked_at = NOWUTC, endpoints = results, source = "live")
    tryCatch(write_json(out, SDMX_CACHE), error = function(e) NULL)
    log_info("SDMX: live probe ok, cache updated")
    return(out)
  }

  cached <- read_json_safe(SDMX_CACHE, default = list())
  log_warn("SDMX: live probe failed, returning cache")
  c(cached, list(source = "cache", probe_at = NOWUTC))
}

# ----- (b) cso-toolkit GitHub state ---------------------------------------- #

collect_cso_toolkit_github <- function() {
  log_info("GH: cso-toolkit starting")
  repo  <- "unicef-drp/cso-toolkit"
  token <- Sys.getenv("GITHUB_TOKEN", unset = NA)
  if (is.na(token) || !nzchar(token)) token <- NULL

  prs       <- gh_api(sprintf("repos/%s/pulls?state=all&per_page=100", repo), token, paginate = TRUE)
  branches  <- gh_api(sprintf("repos/%s/branches?per_page=100", repo),         token, paginate = TRUE)
  issues    <- gh_api(sprintf("repos/%s/issues?state=all&per_page=100", repo),  token, paginate = TRUE)
  milestones <- gh_api(sprintf("repos/%s/milestones?state=all", repo),          token)

  list(
    repo         = repo,
    fetched_at   = NOWUTC,
    prs          = prs       %||% list(),
    branches     = branches  %||% list(),
    issues       = issues    %||% list(),
    milestones   = milestones %||% list()
  )
}

# ----- (c) DW-Production GitHub state -------------------------------------- #
#
# DW-Production is a PRIVATE repository fetched via the DW_PROD_READ_TOKEN secret.
# The dashboard is published to PUBLIC GitHub Pages, so this collector emits ONLY
# aggregate counts — overall and per-sector — never PR/issue titles, bodies, or
# branch names. Full objects are read transiently in memory to compute the
# counts; only the integers below are written to state.json. (This keeps the
# 795cd24 privacy posture: publishing the private repo's text to a public site is
# a data-exfiltration boundary that authorization does not cross.)

collect_dw_production_github <- function() {
  log_info("GH: DW-Production starting")
  repo  <- "unicef-drp/DW-Production"
  token <- Sys.getenv("DW_PROD_READ_TOKEN", unset = NA)
  if (is.na(token) || !nzchar(token)) {
    log_warn("DW_PROD_READ_TOKEN not set; DW-Production will be empty")
    return(list(repo = repo, fetched_at = NOWUTC, reachable = FALSE))
  }

  prs        <- gh_api(sprintf("repos/%s/pulls?state=all&per_page=100", repo), token, paginate = TRUE) %||% list()
  branches   <- gh_api(sprintf("repos/%s/branches?per_page=100", repo),        token, paginate = TRUE) %||% list()
  issues_raw <- gh_api(sprintf("repos/%s/issues?state=all&per_page=100", repo), token, paginate = TRUE) %||% list()
  milestones <- gh_api(sprintf("repos/%s/milestones?state=all", repo),         token) %||% list()
  issues     <- Filter(function(i) is.null(i$pull_request), issues_raw)

  # Best-effort sector tagging from titles / branch names (read in memory only;
  # never emitted). Aliases cover the conventional-commit scopes and branch
  # naming the DW-Production sector PRs use (e.g. wt work lives on cp-cluster).
  aliases <- list(
    nt = "nutrition|\\bnt\\b", hva = "hiv|\\bhva\\b", im = "immun|\\bim\\b",
    ws = "wash|water|\\bws\\b", mnch = "mnch|maternal|newborn",
    cme = "\\bcme\\b|child.?mortal|\\bcm\\b", ed = "educat|\\bed\\b",
    wt = "\\bwt\\b|cp.?cluster|women|weighting", ecd = "ecd|early.?child"
  )
  sector_of <- function(text) {
    text <- tolower(text %||% "")
    for (s in names(aliases)) if (grepl(aliases[[s]], text)) return(s)
    NA_character_
  }
  bysec <- setNames(
    lapply(SECTORS, function(s) list(prs_open = 0L, issues_open = 0L, branches = 0L)),
    SECTORS
  )
  for (p in prs) {
    if (identical(p$state, "open")) {
      s <- sector_of(paste(p$title %||% "", p$head$ref %||% ""))
      if (!is.na(s)) bysec[[s]]$prs_open <- bysec[[s]]$prs_open + 1L
    }
  }
  for (i in issues) {
    if (identical(i$state, "open")) {
      s <- sector_of(i$title %||% "")
      if (!is.na(s)) bysec[[s]]$issues_open <- bysec[[s]]$issues_open + 1L
    }
  }
  for (b in branches) {
    s <- sector_of(b$name %||% "")
    if (!is.na(s)) bysec[[s]]$branches <- bysec[[s]]$branches + 1L
  }

  list(
    repo       = repo,
    fetched_at = NOWUTC,
    reachable  = TRUE,
    counts = list(
      prs_total      = length(prs),
      prs_open       = length(Filter(function(p) identical(p$state, "open"), prs)),
      prs_merged     = length(Filter(function(p) !is.null(p$merged_at), prs)),
      prs_closed     = length(Filter(function(p) identical(p$state, "closed") && is.null(p$merged_at), prs)),
      issues_total   = length(issues),
      issues_open    = length(Filter(function(i) identical(i$state, "open"), issues)),
      issues_closed  = length(Filter(function(i) identical(i$state, "closed"), issues)),
      branches_total = length(branches)
    ),
    by_sector = bysec
  )
}

`%||%` <- function(x, y) if (is.null(x)) y else x

# ----- (d) operator snapshots ---------------------------------------------- #

collect_teams_snapshot <- function() {
  path <- file.path(SNAPSHOTS_DIR, "teams_snapshot_latest.json")
  snap <- read_json_safe(path, default = NULL)
  if (is.null(snap)) {
    log_warn("teams_snapshot_latest.json missing or unparsable")
    return(list(present = FALSE))
  }
  snap$present <- TRUE
  snap
}

collect_replication_snapshots <- function() {
  out <- list()
  for (s in SECTORS) {
    path <- file.path(SNAPSHOTS_DIR, sprintf("replication_%s_latest.json", s))
    snap <- read_json_safe(path, default = NULL)
    if (is.null(snap)) {
      log_warn(sprintf("replication_%s_latest.json missing", s))
      out[[s]] <- list(sector = s, present = FALSE)
    } else {
      snap$sector  <- s
      snap$present <- TRUE
      out[[s]]     <- snap
    }
  }
  out
}

collect_actions <- function() {
  yml_files <- list.files(ACTIONS_DIR, pattern = "\\.ya?ml$", full.names = TRUE)
  if (length(yml_files) == 0) return(list())

  # Action YAMLs use block scalars (`description: |`) and nested arrays
  # (`references:`). A flat key:value scanner would silently mis-parse them,
  # so yaml is a hard requirement; if absent we mark every file as a parse
  # error rather than emit incorrect/partial action objects.
  if (!requireNamespace("yaml", quietly = TRUE)) {
    log_warn("yaml package not installed; cannot parse action files")
    return(lapply(yml_files, function(f) {
      list(
        id          = tools::file_path_sans_ext(basename(f)),
        parse_error = TRUE,
        parse_error_reason = "yaml package not installed"
      )
    }))
  }

  lapply(yml_files, function(f) {
    tryCatch(yaml::read_yaml(f), error = function(e) {
      log_warn(sprintf("YAML parse failed: %s", basename(f)))
      list(
        id          = tools::file_path_sans_ext(basename(f)),
        parse_error = TRUE,
        parse_error_reason = conditionMessage(e)
      )
    })
  })
}

# ----- assembly ------------------------------------------------------------ #

build_state <- function() {
  list(
    schema_version = "1.0.0",
    generated_at   = NOWUTC,
    generated_on   = TODAY,
    sectors        = SECTORS,
    sdmx           = collect_sdmx(),
    cso_toolkit    = collect_cso_toolkit_github(),
    dw_production  = collect_dw_production_github(),
    teams_snapshot = collect_teams_snapshot(),
    replication    = collect_replication_snapshots(),
    actions        = collect_actions()
  )
}

main <- function() {
  state <- build_state()

  write_json(state, STATE_PATH)
  log_info(sprintf("wrote %s", STATE_PATH))

  hist_dir <- file.path(HISTORY_DIR, TODAY)
  dir.create(hist_dir, showWarnings = FALSE, recursive = TRUE)
  hist_path <- file.path(hist_dir, "state.json")
  write_json(state, hist_path)
  log_info(sprintf("wrote %s", hist_path))

  invisible(state)
}

if (sys.nframe() == 0L) {
  main()
}
