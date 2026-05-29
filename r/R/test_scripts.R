#---------------------------------------------------------------------
# cso-toolkit: contract test for sector / project scripts
#---------------------------------------------------------------------
# Purpose : Audit a directory of R scripts and flag any direct calls
#           to the raw IO or HTTP commands that cso-toolkit wraps
#           (dw_io.R wraps file IO; dw_api.R wraps external API
#           access). The contract is: scripts should call dw_save /
#           dw_use / dw_compare / dw_merge for file IO and
#           dw_api_fetch / dw_api_cached for external access -- never
#           the raw underlying calls. test_scripts() reports
#           violations so reviewers can enforce the contract in CI.
#---------------------------------------------------------------------

# Rule registry --------------------------------------------------------
#
# Each rule is (id, pattern, family, message, suggested_replacement).
# Patterns are PCRE; they are matched against each source line after
# stripping trailing comments. Patterns deliberately match both
# unqualified and namespaced forms (e.g. `read_csv(` and `readr::read_csv(`).
# Add a `# cso-allow: <id>` trailing comment on a specific line to silence
# a particular rule for that line (escape hatch for the rare case where
# the raw call really is intentional).

.cso_test_rules <- list(
  # ---- IO commands wrapped by dw_io.R (use dw_save / dw_use) ----
  list(id = "io-read-csv",     family = "io",
       pattern = "(?<![a-zA-Z0-9_.])(?:utils::|readr::)?(?:read\\.csv2?|read_csv|read_tsv|read_delim)\\s*\\(",
       message = "Direct CSV read.",
       suggest = "dw_use(name = ..., sector = ..., kind = ...)"),
  list(id = "io-write-csv",    family = "io",
       pattern = "(?<![a-zA-Z0-9_.])(?:utils::|readr::)?(?:write\\.csv2?|write_csv|write_tsv|write_delim)\\s*\\(",
       message = "Direct CSV write.",
       suggest = "dw_save(x, name = ..., sector = ..., kind = ..., isid = ...)"),
  list(id = "io-fread",        family = "io",
       pattern = "(?<![a-zA-Z0-9_.])(?:data\\.table::)?(?:fread|fwrite)\\s*\\(",
       message = "Direct data.table fread / fwrite.",
       suggest = "dw_use(...) or dw_save(...)"),
  list(id = "io-rds",          family = "io",
       pattern = "(?<![a-zA-Z0-9_.])(?:saveRDS|readRDS)\\s*\\(",
       message = "Direct RDS read / write.",
       suggest = "dw_use(...) / dw_save(...) -- auto-dispatches on .rds."),
  list(id = "io-load-save",    family = "io",
       pattern = "(?<![a-zA-Z0-9_.])(?:save|load)\\s*\\(",
       message = "Direct save() / load() for .RData.",
       suggest = "dw_save(... , ext = 'RData') / dw_use(... , ext = 'RData')."),
  list(id = "io-dta",          family = "io",
       pattern = "(?<![a-zA-Z0-9_.])(?:haven::)?(?:read_dta|write_dta|read_stata|write_stata)\\s*\\(",
       message = "Direct Stata .dta read / write.",
       suggest = "dw_use(...) / dw_save(...) -- auto-dispatches on .dta."),
  list(id = "io-xlsx",         family = "io",
       pattern = "(?<![a-zA-Z0-9_.])(?:readxl::|openxlsx::|writexl::)?(?:read_xlsx|read_excel|write_xlsx|write\\.xlsx|read\\.xlsx)\\s*\\(",
       message = "Direct Excel read / write.",
       suggest = "dw_use(...) / dw_save(...) -- auto-dispatches on .xlsx (single + multi-sheet)."),
  list(id = "io-parquet",      family = "io",
       pattern = "(?<![a-zA-Z0-9_.])(?:arrow::)?(?:read_parquet|write_parquet)\\s*\\(",
       message = "Direct Parquet read / write.",
       suggest = "dw_use(...) / dw_save(...) -- auto-dispatches on .parquet."),
  list(id = "io-json-file",    family = "io",
       pattern = "(?<![a-zA-Z0-9_.])(?:jsonlite::)?(?:read_json|write_json)\\s*\\(",
       message = "Direct JSON file read / write.",
       suggest = "dw_use(...) / dw_save(...) -- auto-dispatches on .json."),
  list(id = "io-yaml",         family = "io",
       pattern = "(?<![a-zA-Z0-9_.])(?:yaml::)?(?:read_yaml|write_yaml|yaml\\.load_file)\\s*\\(",
       message = "Direct YAML read / write.",
       suggest = "dw_use(...) / dw_save(...) -- auto-dispatches on .yaml / .yml. (Profile YAML config load is exempt -- add `# cso-allow: io-yaml`.)"),

  # ---- API commands wrapped by dw_api.R (use dw_api_fetch / dw_api_cached) ----
  list(id = "api-httr",        family = "api",
       pattern = "(?<![a-zA-Z0-9_.])(?:httr::|httr2::)?(?:GET|POST|PUT|PATCH|DELETE|request)\\s*\\(",
       message = "Direct HTTP call via httr / httr2.",
       suggest = "dw_api_fetch(api = 'http' | 'json_get' | ..., cache_key = ..., ...)"),
  list(id = "api-fromjson-url", family = "api",
       pattern = "(?<![a-zA-Z0-9_.])(?:jsonlite::)?fromJSON\\s*\\(\\s*[\"'](?:https?|ftp)://",
       message = "fromJSON() called on a URL string (bypasses the cache).",
       suggest = "dw_api_fetch(api = 'json_get', cache_key = ..., url = ...)"),
  list(id = "api-sdmx",        family = "api",
       pattern = "(?<![a-zA-Z0-9_.])(?:rsdmx::)?readSDMX\\s*\\(",
       message = "Direct rsdmx::readSDMX call.",
       suggest = "dw_api_fetch(api = 'sdmx', providerId = ..., flowRef = ..., key = ..., cache_key = ...)"),
  list(id = "api-wbstats",     family = "api",
       pattern = "(?<![a-zA-Z0-9_.])(?:wbstats::)?wb_(?:data|indicators|countries)\\s*\\(",
       message = "Direct wbstats call.",
       suggest = "dw_api_fetch(api = 'wb' | 'wb_indicators', indicator = ..., cache_key = ...)"),
  list(id = "api-ilostat",     family = "api",
       pattern = "(?<![a-zA-Z0-9_.])(?:Rilostat::|ilostat::)?get_ilostat\\s*\\(",
       message = "Direct Rilostat::get_ilostat call.",
       suggest = "dw_api_fetch(api = 'ilo', flowRef = ..., key = ..., cache_key = ...)"),
  list(id = "api-download",    family = "api",
       pattern = "(?<![a-zA-Z0-9_.])(?:download\\.file|curl::curl_download|curl::curl_fetch_memory|curl::curl_fetch_disk)\\s*\\(",
       message = "Direct file download bypasses the cache.",
       suggest = "dw_api_fetch(api = 'http', cache_key = ...) and pass the cached bytes to your reader.")
)

#' Audit R scripts for direct calls to commands wrapped by cso-toolkit
#'
#' Recursively scans a directory of `.R` scripts and flags any line that
#' calls a raw file-IO or external-API function that `dw_io.R` or
#' `dw_api.R` is meant to wrap. The contract this enforces is:
#'
#' - File IO must go through `dw_save()` / `dw_use()` / `dw_compare()` /
#'   `dw_merge()` -- never `read_csv()`, `write_xlsx()`, `saveRDS()`, etc.
#' - External APIs must go through `dw_api_fetch()` / `dw_api_cached()` --
#'   never `httr::GET()`, `rsdmx::readSDMX()`, `wbstats::wb_data()`, etc.
#'
#' Per-line escape hatch: add a trailing `# cso-allow: <rule-id>` comment
#' on the line you genuinely need to allow (e.g. the YAML config loader in
#' a project profile is exempt: `yaml::read_yaml(config_path)  # cso-allow: io-yaml`).
#'
#' @param path Character. Directory (recursed) or single `.R` file to scan.
#' @param pattern Character. Regex of filenames to include. Default `"\\.R$"`.
#' @param recursive Logical. Recurse into subdirectories. Default `TRUE`.
#' @param ignore_files Character vector. Basenames to skip entirely (the
#'   toolkit's own implementation files are skipped by default since they
#'   must call the wrapped commands).
#' @param ignore_dirs Character vector. Directory basenames to skip (e.g.
#'   `"renv"`, `"packrat"`, `".git"`).
#' @param custom_rules Optional list of additional rules -- each element a
#'   list with `id`, `pattern`, `family`, `message`, `suggest`. Merged with
#'   the built-in registry.
#' @param error_on_violation Logical. If `TRUE`, `stop()` after reporting
#'   when any `family == "io"` or `"api"` violation is found (useful in CI).
#'   Default `FALSE`.
#' @param verbose Logical. Print a formatted summary. Default `TRUE`.
#'
#' @return A data frame with columns `file`, `line`, `rule`, `family`,
#'   `message`, `suggest`, `snippet`. Empty data frame if clean.
#'
#' @examples
#' \dontrun{
#' # Audit a sector codebase:
#' test_scripts("01_dw_prep/012_codes/nt")
#'
#' # CI-mode: stop with a non-zero exit if any violations found:
#' test_scripts("01_dw_prep/012_codes", error_on_violation = TRUE)
#'
#' # Allow a specific line:
#' # config <- yaml::read_yaml(config_path)  # cso-allow: io-yaml
#' }
#' @seealso [review_profile()] for the profile-level audit; [dw_save()] /
#'   [dw_use()] and [dw_api_fetch()] (the toolkit functions whose direct
#'   bypasses this auditor catches).
#' @family audit
#' @export
test_scripts <- function(path,
                         pattern = "\\.R$",
                         recursive = TRUE,
                         ignore_files = c("dw_io.R", "dw_api.R",
                                          "cso_toolkit_sync.R",
                                          "profile_helpers.R",
                                          "test_scripts.R"),
                         ignore_dirs = c(".git", "renv", "packrat",
                                         "node_modules", ".Rproj.user"),
                         custom_rules = NULL,
                         error_on_violation = FALSE,
                         verbose = TRUE) {
  if (!file.exists(path)) {
    stop(sprintf(
      "[cso_toolkit.test_scripts] Path not found: %s\n  Fix: pass an existing file or directory. Relative paths resolve against %s.",
      path, getwd()
    ), call. = FALSE)
  }

  files <- if (dir.exists(path)) {
    all <- list.files(path, pattern = pattern, recursive = recursive,
                      full.names = TRUE, ignore.case = TRUE)
    Filter(function(f) {
      if (basename(f) %in% ignore_files) return(FALSE)
      parts <- strsplit(dirname(f), "[/\\\\]")[[1]]
      !any(parts %in% ignore_dirs)
    }, all)
  } else {
    path
  }

  rules <- c(.cso_test_rules, if (is.null(custom_rules)) list() else custom_rules)

  violations <- vector("list", 0)

  for (f in files) {
    lines <- tryCatch(readLines(f, warn = FALSE),
                      error = function(e) character(0))
    if (length(lines) == 0) next

    for (i in seq_along(lines)) {
      raw <- lines[i]
      # Strip strings + trailing comment for matching (but keep `cso-allow`).
      no_str <- gsub("\"[^\"]*\"|'[^']*'", "\"\"", raw, perl = TRUE)
      allow_match <- regmatches(raw, regexpr("#\\s*cso-allow:\\s*([A-Za-z0-9_-]+(?:\\s*,\\s*[A-Za-z0-9_-]+)*)",
                                              raw, perl = TRUE))
      allowed_ids <- if (length(allow_match) && nchar(allow_match)) {
        ids_str <- sub("^#\\s*cso-allow:\\s*", "", allow_match, perl = TRUE)
        trimws(strsplit(ids_str, ",")[[1]])
      } else character(0)
      no_comment <- sub("#.*$", "", no_str)

      for (rule in rules) {
        if (rule$id %in% allowed_ids) next
        if (grepl(rule$pattern, no_comment, perl = TRUE)) {
          violations[[length(violations) + 1]] <- data.frame(
            file    = f,
            line    = i,
            rule    = rule$id,
            family  = rule$family,
            message = rule$message,
            suggest = rule$suggest,
            snippet = trimws(raw),
            stringsAsFactors = FALSE
          )
        }
      }
    }
  }

  out <- if (length(violations) > 0) {
    do.call(rbind, violations)
  } else {
    data.frame(file = character(0), line = integer(0), rule = character(0),
               family = character(0), message = character(0),
               suggest = character(0), snippet = character(0),
               stringsAsFactors = FALSE)
  }

  if (isTRUE(verbose)) {
    cat("\ncso-toolkit contract audit\n")
    cat(strrep("-", 72), "\n", sep = "")
    cat("Files scanned : ", length(files), "\n", sep = "")
    cat("Violations    : ", nrow(out), "\n", sep = "")
    if (nrow(out) > 0) {
      cat("\n")
      for (i in seq_len(nrow(out))) {
        cat(sprintf("[%s] %s:%d\n  %s\n  > %s\n  -> %s\n\n",
                    out$rule[i], out$file[i], out$line[i],
                    out$message[i], out$snippet[i], out$suggest[i]))
      }
    } else {
      cat("[OK] Clean.\n")
    }
    cat(strrep("-", 72), "\n", sep = "")
  }

  if (isTRUE(error_on_violation) &&
      any(out$family %in% c("io", "api"))) {
    offenders <- utils::head(unique(out$file), 5)
    more <- if (length(unique(out$file)) > 5) sprintf(" (and %d more)", length(unique(out$file)) - 5) else ""
    stop(sprintf(
      "[cso_toolkit.test_scripts] Contract audit failed: %d violation(s) across %d file(s).\n  Offending files%s:\n    %s\n  Fix: replace raw IO / HTTP calls with their cso-toolkit equivalents (`dw_save` / `dw_use` / `dw_api_fetch`). For the rare legitimate exceptions, append `# cso-allow: <rule-id>` to the offending line.",
      nrow(out), length(unique(out$file)), more,
      paste(offenders, collapse = "\n    ")
    ), call. = FALSE)
  }

  invisible(out)
}

# =============================================================================
# v0.4.5 — dw_-prefixed canonical alias (issue #42)
# =============================================================================
# The `test_` prefix collides cosmetically with `testthat::test_*` test
# naming. A future v0.5.x cycle may rename to `dw_audit_scripts` to
# surface the intent more clearly (the function audits 00_functions/
# call sites against the toolkit contract — it is not a unit-test
# runner). For now, the prefix-only alias keeps the v0.4.5 cleanup
# additive and back-compat.

#' @rdname test_scripts
#' @export
dw_test_scripts <- test_scripts
