#!/usr/bin/env Rscript
# docs/dashboard/collect.R
# -----------------------------------------------------------------------------
# Collect state for the cso-toolkit sector dashboard.
#
# Reads from four sources and assembles a master data/state.json that
# render.R turns into a static SPA.
#
# Sources:
#   (a) UNICEF SDMX        — rsdmx, with retry + timeout, caches to
#                            data/sdmx_cache_latest.json on success.
#                            Falls back to cache on network failure.
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

SCRIPT_DIR     <- tryCatch(
  dirname(normalizePath(sys.frame(1)$ofile, winslash = "/")),
  error = function(e) getwd()
)
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
  args <- c("api", endpoint)
  if (paginate) args <- c(args, "--paginate")
  env  <- c()
  if (!is.null(token) && nzchar(token)) {
    env <- c(env, paste0("GH_TOKEN=", token))
  }
  out <- tryCatch(
    system2(cmd, args, stdout = TRUE, stderr = TRUE, env = env),
    error = function(e) NULL
  )
  if (is.null(out) || length(out) == 0) return(NULL)
  status <- attr(out, "status")
  if (!is.null(status) && status != 0) {
    log_warn(sprintf("gh api %s failed (status %s)", endpoint, status))
    return(NULL)
  }
  tryCatch(
    jsonlite::fromJSON(paste(out, collapse = "\n"), simplifyVector = FALSE),
    error = function(e) {
      log_warn(sprintf("gh api %s: non-JSON output", endpoint))
      NULL
    }
  )
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

collect_dw_production_github <- function() {
  log_info("GH: DW-Production starting")
  repo  <- "unicef-drp/DW-Production"
  token <- Sys.getenv("DW_PROD_READ_TOKEN", unset = NA)
  if (is.na(token) || !nzchar(token)) {
    log_warn("DW_PROD_READ_TOKEN not set; DW-Production will be empty")
    return(list(repo = repo, fetched_at = NOWUTC, reachable = FALSE))
  }

  prs       <- gh_api(sprintf("repos/%s/pulls?state=all&per_page=100", repo), token, paginate = TRUE)
  branches  <- gh_api(sprintf("repos/%s/branches?per_page=100", repo),         token, paginate = TRUE)
  issues    <- gh_api(sprintf("repos/%s/issues?state=all&per_page=100", repo),  token, paginate = TRUE)
  milestones <- gh_api(sprintf("repos/%s/milestones?state=all", repo),          token)

  list(
    repo         = repo,
    fetched_at   = NOWUTC,
    reachable    = !is.null(prs),
    prs          = prs       %||% list(),
    branches     = branches  %||% list(),
    issues       = issues    %||% list(),
    milestones   = milestones %||% list()
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

  # Lightweight YAML parser — flat key:value only.
  # We bring in yaml if available, else fall back to a simple scanner.
  if (requireNamespace("yaml", quietly = TRUE)) {
    out <- lapply(yml_files, function(f) {
      tryCatch(yaml::read_yaml(f), error = function(e) {
        log_warn(sprintf("YAML parse failed: %s", basename(f)))
        list(id = tools::file_path_sans_ext(basename(f)), parse_error = TRUE)
      })
    })
  } else {
    out <- lapply(yml_files, function(f) {
      lines <- readLines(f, warn = FALSE)
      kv    <- list()
      for (ln in lines) {
        if (!grepl(":", ln) || grepl("^\\s*#", ln)) next
        parts <- strsplit(ln, ":", fixed = TRUE)[[1]]
        k <- trimws(parts[1])
        v <- trimws(paste(parts[-1], collapse = ":"))
        v <- gsub('^"|"$', "", v)
        kv[[k]] <- v
      }
      if (is.null(kv$id)) kv$id <- tools::file_path_sans_ext(basename(f))
      kv
    })
  }
  out
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
