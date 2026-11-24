#---------------------------------------------------------------------
# cso-toolkit: profile helpers
#---------------------------------------------------------------------
# Purpose : Scaffold a project profile.R for a CSO data-warehouse
#           pipeline (create_profile) and audit an existing one for
#           the blocks the toolkit's contract relies on
#           (review_profile).
#
# The reference profile this scaffold is patterned on is the
# DW-Production profile_DW-Production.R: it cross-platforms USERNAME,
# loads a YAML user_config, reads dw_mode (producer / reviewer),
# verifies (optionally creates) the folder structure, and ends by
# setting a sentinel object (profile_<repo> <- TRUE) that downstream
# sector scripts test with `if (!exists("profile_<repo>") || ...)`.
#---------------------------------------------------------------------

#' Generate a project profile script for a CSO data-warehouse pipeline
#'
#' Writes a `profile_<repo_name>.R` template to disk. The template wires up
#' the standard CSO building blocks: user identification (USERNAME / USER
#' for Windows / Mac), reproducibility seed, optional Z: drive integrity
#' check, YAML user config load, optional producer / reviewer dw_mode
#' resolution, a block that resolves and prints the project's collaboration
#' model ([dw_collaboration()], read from `cso_project.yml`; single-producer
#' when the file is absent), a placeholder packages block, and the profile
#' sentinel object downstream sector scripts assert against.
#'
#' `~/.config/user_config.yml` follows DW-Production's template: each
#' person's settings sit in a block named after their user name, and the
#' generated profile reads that block first, then top-level keys. `dw_mode`
#' has no default; it resolves as `dw_mode_by_project[[repo_name]]`, then
#' `dw_mode`, and the profile stops with the exact YAML to add, user name
#' filled in, when neither is set:
#' \preformatted{
#' jpazevedo:
#'   dw_mode: "reviewer"
#'   dw_mode_by_project:
#'     My-Sector-Project: "producer"
#' }
#' The profile never installs packages: a missing one stops the session
#' with the list to install.
#'
#' @param repo_name Character. Repository folder name, used in the sentinel
#'   object name (`profile_<repo_name>` with `-` and `.` converted to `_`)
#'   and the generated filename (`profile_<repo_name>.R`).
#' @param project_title Character. Human-readable project title for the
#'   header block (e.g., "UNICEF DW Production"). Defaults to `repo_name`.
#' @param output_path Character. Directory the file is written to. Defaults
#'   to `"."`.
#' @param include_dw_mode Logical. Include the producer / reviewer mode
#'   block that reads `dw_mode` from `user_config.yml` and hard-fails when
#'   missing? Default `TRUE`.
#' @param include_z_drive_check Logical. Include the Z: drive availability
#'   advisory block? Default `FALSE` (DW-Production-specific). The generated
#'   check uses a timeout-bounded probe (`vol` in a child process, 3 s) for
#'   drive letters, so a dead-mapped Z: cannot hang the profile; other paths
#'   use `dir.exists()`.
#' @param author Character. Author name for the header. Defaults to the
#'   system user.
#' @param overwrite Logical. If `FALSE` (default), stops when the target
#'   file already exists.
#'
#' @return Invisibly, the absolute path of the file written.
#'
#' @examples
#' \dontrun{
#' create_profile("My-Sector-Project", project_title = "My Sector Project")
#' create_profile("DW-Production",
#'                project_title = "UNICEF DW Production",
#'                include_z_drive_check = TRUE,
#'                overwrite = TRUE)
#' }
#' @seealso [review_profile()] to audit the generated profile against the
#'   toolkit contract; [create_sector_script()] for sector-level
#'   scaffolding that depends on the profile sentinel.
#' @family scaffolding
#' @param verbose Logical or `NULL`. Show high-level progress and result
#'   messages. `NULL` (default) inherits `getOption("dw.verbose", TRUE)`;
#'   set `TRUE`/`FALSE` to override for this call. See [dw_verbosity()].
#' @param debug Logical or `NULL`. Show internal troubleshooting detail.
#'   `NULL` (default) inherits `getOption("dw.debug", FALSE)`; implies
#'   `verbose`. See [dw_verbosity()].
#' @export
create_profile <- function(repo_name,
                           project_title = repo_name,
                           output_path = ".",
                           include_dw_mode = TRUE,
                           include_z_drive_check = FALSE,
                           author = Sys.getenv("USERNAME", unset = Sys.info()[["user"]]),
                           overwrite = FALSE,
                           verbose = NULL,
                           debug = NULL) {
  sentinel <- paste0("profile_", gsub("[-.]+", "_", repo_name))
  filename <- paste0("profile_", repo_name, ".R")
  if (!dir.exists(output_path)) dir.create(output_path, recursive = TRUE)
  path <- file.path(output_path, filename)
  if (file.exists(path) && !overwrite) {
    stop(sprintf(
      "[cso_toolkit.create_profile] File already exists: %s\n  Fix: pass overwrite = TRUE to replace it, or delete the existing profile first.",
      path
    ), call. = FALSE)
  }

  vd <- .dw_vd(verbose, debug); v <- vd$v; d <- vd$d
  .dw_msg("create_profile", "scaffolding profile for repo '", repo_name, "' -> ", filename, v = v)
  .dw_dbg("create_profile", "sentinel=", sentinel, " include_dw_mode=", include_dw_mode, " include_z_drive_check=", include_z_drive_check, " overwrite=", overwrite, d = d)

  timestamp <- format(Sys.time(), "%Y-%m-%d %H:%M")

  header <- c(
    "#-------------------------------------------------------------------",
    paste0("# Project: ", project_title),
    paste0("# Script : ", filename),
    "# Purpose: Sets user-specific paths, verifies folder structure,",
    "#          loads required packages, and prepares the working",
    "#          environment for pipeline execution.",
    paste0("# Author : ", author),
    paste0("# Created: ", timestamp),
    "# Toolkit: cso-toolkit (https://github.com/unicef-drp/cso-toolkit)",
    "#-------------------------------------------------------------------",
    "",
    "# Reproducibility seed",
    "set.seed(12345)",
    "",
    "#----------------------------------------",
    "# 1. User Identification (cross-platform)",
    "#----------------------------------------",
    "USERNAME    <- Sys.getenv(\"USERNAME\")",
    "USERPROFILE <- Sys.getenv(\"USERPROFILE\")",
    "USER        <- Sys.getenv(\"USER\")",
    "if (USERNAME == \"\" || is.na(USERNAME)) USERNAME <- Sys.getenv(\"USER\")",
    "if (USERPROFILE == \"\" || is.na(USERPROFILE)) USERPROFILE <- \"~\"",
    "",
    "#----------------------------------------",
    "# 2. Flags and Controls",
    "#----------------------------------------",
    "create_missing_folders <- FALSE",
    "",
    "#----------------------------------------",
    "# 3. Repository name",
    "#----------------------------------------",
    paste0("repo_name <- \"", repo_name, "\""),
    "",
    "# Repository root: the folder the profile is sourced from, unless rootFolder",
    "# is set first. Sector scripts build their input and output paths from",
    "# projectFolder (create_sector_script()).",
    "if (!exists(\"rootFolder\")) rootFolder <- getwd()",
    "rootFolder <- normalizePath(rootFolder, winslash = \"/\", mustWork = FALSE)",
    "projectFolder <- rootFolder",
    ""
  )

  z_block <- if (include_z_drive_check) c(
    "#----------------------------------------",
    "# 4. Z: drive -- non-blocking advisory",
    "#----------------------------------------",
    "# The Z: drive is the legacy Azure file-share mirror of canonical",
    "# deposits. Absence does NOT stop execution -- only an advisory.",
    "#",
    "# Timeout-bounded probe: dir.exists() on a Windows drive letter that is",
    "# mapped but unreachable (e.g. Z: off VPN) blocks for the full SMB timeout",
    "# -- tens of seconds to minutes. For a drive letter, probe with `vol` in a",
    "# child process capped at `timeout` seconds; other paths use dir.exists().",
    ".dw_drive_available <- function(root, timeout = 3) {",
    "  is_drive_letter <- .Platform$OS.type == \"windows\" &&",
    "    nchar(root) <= 3 && substr(root, 2, 2) == \":\"",
    "  if (!is_drive_letter) return(dir.exists(root))",
    "  rc <- tryCatch(",
    "    system2(\"cmd\", c(\"/c\", \"vol\", substr(root, 1, 2)),",
    "            stdout = FALSE, stderr = FALSE, timeout = timeout),",
    "    error = function(e) 1L, warning = function(w) 1L",
    "  )",
    "  isTRUE(rc == 0L)",
    "}",
    "network_root <- \"Z:/\"",
    "dw_z_available <- .dw_drive_available(network_root)",
    "if (!dw_z_available) {",
    "  red  <- function(s) paste0(\"\\033[31m\", s, \"\\033[0m\")",
    "  bold <- function(s) paste0(\"\\033[1m\", s, \"\\033[0m\")",
    "  cat(red(bold(\"\\n[!] Network drive (Z:) not mounted -- NON-BLOCKING\\n\")))",
    "}",
    ""
  ) else character(0)

  config_block <- c(
    "#----------------------------------------",
    "# 5. Load user config (YAML required)",
    "#----------------------------------------",
    "# ~/.config/user_config.yml serves every cso-toolkit project (template:",
    "# DW-Production's _config_template/user_config.yml). Settings sit in a",
    "# block named after the user (USERNAME on Windows, USER elsewhere);",
    "# top-level keys are read as a fallback.",
    "config_path <- file.path(USERPROFILE, \".config\", \"user_config.yml\")",
    "if (!requireNamespace(\"yaml\", quietly = TRUE)) {",
    "  stop(\"[X] The yaml package is needed to read \", config_path, \".\\n\",",
    "       \"    Install it once with install.packages(\\\"yaml\\\") and rerun.\", call. = FALSE)",
    "}",
    "if (!file.exists(config_path)) {",
    "  stop(paste0(",
    "    \"[X] Configuration file not found at: \", config_path, \"\\n\",",
    "    \"=> Create it, with your settings in a block named \", USERNAME, \":\"",
    "  ), call. = FALSE)",
    "}",
    "user_config <- yaml::read_yaml(config_path)  # cso-allow: io-yaml",
    "user_block <- if (is.list(user_config[[USERNAME]])) user_config[[USERNAME]] else list()",
    "user_setting <- function(key) {",
    "  if (!is.null(user_block[[key]])) user_block[[key]] else user_config[[key]]",
    "}",
    ""
  )

  mode_block <- if (include_dw_mode) c(
    "#----------------------------------------",
    "# 6. Producer / reviewer mode (cso-toolkit contract)",
    "#----------------------------------------",
    "# dw_mode is a SESSION property read from user_config.yml; downstream",
    "# helpers (dw_save / dw_use / dw_api_fetch) route writes and forbid",
    "# external API calls based on this single setting. No default.",
    "# Precedence (as DW-Production's dw_mode_by_sector): dw_mode_by_project",
    "# for this repository, then dw_mode; each from the user block first.",
    "dw_mode_by_project <- user_setting(\"dw_mode_by_project\")",
    "if (!is.null(dw_mode_by_project) && !is.list(dw_mode_by_project)) {",
    "  stop(\"[X] dw_mode_by_project in \", config_path, \" must map project names to \",",
    "       \"\\\"producer\\\" or \\\"reviewer\\\", not a single value.\", call. = FALSE)",
    "}",
    "dw_mode <- dw_mode_by_project[[repo_name]]",
    "if (is.null(dw_mode)) dw_mode <- user_setting(\"dw_mode\")",
    "if (!(is.character(dw_mode) && length(dw_mode) == 1 &&",
    "      dw_mode %in% c(\"producer\", \"reviewer\"))) {",
    "  stop(sprintf(paste0(",
    "    \"[X] No valid dw_mode (\\\"producer\\\" or \\\"reviewer\\\") for %s.\\n\",",
    "    \"    Add it to %s, in your user block:\\n\",",
    "    \"      %s:\\n        dw_mode: \\\"reviewer\\\"\\n\",",
    "    \"    or, for this project only:\\n\",",
    "    \"      %s:\\n        dw_mode_by_project:\\n          %s: \\\"producer\\\"\"),",
    "    repo_name, config_path, USERNAME, USERNAME, repo_name), call. = FALSE)",
    "}",
    "dw_apis_allowed <- identical(dw_mode, \"producer\")",
    "# Agent sessions (handbook chapter 'Working with AI coding agents'): Claude Code sets CLAUDE_CODE_CHILD_SESSION=1",
    "# in the commands it runs. An agent works as reviewer unless the person running the",
    "# session chose producer (AGENTS.md); say so when it is a producer. Nothing is blocked.",
    "if (identical(dw_mode, \"producer\") && identical(Sys.getenv(\"CLAUDE_CODE_CHILD_SESSION\"), \"1\")) {",
    "  message(\"[!] profile: a Claude Code session is running as producer for \", repo_name,",
    "          \": it writes outputs and may call live APIs. Agents work as reviewer unless \",",
    "          \"the person running the session chose producer (AGENTS.md).\")",
    "}",
    "",
    "# Guard used by dw_api_fetch and analysis scripts in reviewer mode.",
    "dw_require_no_api <- function(context = NULL) {",
    "  if (identical(dw_mode, \"reviewer\")) {",
    "    msg <- \"[X] External API access is forbidden in reviewer mode.\"",
    "    if (!is.null(context)) msg <- paste0(msg, \" Context: \", context)",
    "    stop(msg, call. = FALSE)",
    "  }",
    "}",
    ""
  ) else character(0)

  collab_block <- c(
    "#----------------------------------------",
    "# 7. Collaboration model (cso_project.yml, committed in the repo)",
    "#----------------------------------------",
    "# dw_mode above is per person; how many people may PRODUCE is a project",
    "# property set in cso_project.yml at the repository root (no file =",
    "# single-producer). Resolve it once per session and show it.",
    "if (exists(\"dw_collaboration\", mode = \"function\")) {",
    "  dw_collaboration_model <- dw_collaboration(",
    "    root = if (exists(\"rootFolder\")) rootFolder else getwd(), refresh = TRUE)",
    "  message(\"[OK] Collaboration model: \", dw_collaboration_model)",
    "} else {",
    "  message(\"[!] cso-toolkit not loaded yet: the collaboration model \",",
    "          \"(cso_project.yml) is resolved on the first dw_save().\")",
    "}",
    ""
  )

  packages_block <- c(
    "#----------------------------------------",
    "# 8. Packages",
    "#----------------------------------------",
    "# Add the packages your pipeline needs here. They are never installed",
    "# from here: a missing package stops the session with the list, so a",
    "# run's environment never changes without its user knowing.",
    "required_pkgs <- c(\"dplyr\", \"tidyr\", \"readr\", \"yaml\")",
    "missing_pkgs <- required_pkgs[!vapply(required_pkgs, requireNamespace,",
    "                                      logical(1), quietly = TRUE)]",
    "if (length(missing_pkgs)) {",
    "  stop(\"[X] Missing R package(s): \", paste(missing_pkgs, collapse = \", \"), \"\\n\",",
    "       \"    Install them once with install.packages(c(\",",
    "       paste0(\"\\\"\", missing_pkgs, \"\\\"\", collapse = \", \"), \")) and rerun.\", call. = FALSE)",
    "}",
    "for (pkg in required_pkgs) library(pkg, character.only = TRUE)",
    ""
  )

  sentinel_block <- c(
    "#----------------------------------------",
    "# 9. Profile sentinel",
    "#----------------------------------------",
    "# Downstream sector scripts assert against this object so they can",
    "# refuse to run if the profile was not sourced.",
    paste0(sentinel, " <- TRUE"),
    paste0("message(\"[OK] ", filename, " loaded\")")
  )

  lines <- c(header, z_block, config_block, mode_block, collab_block,
             packages_block, sentinel_block)
  writeLines(lines, con = path)
  .dw_dbg("create_profile", "wrote ", length(lines), " lines", d = d)
  if (v) message("[OK] Profile written: ", path)
  .dw_msg("create_profile", "profile written to ", path, v = v)
  invisible(normalizePath(path, mustWork = FALSE))
}

#' Audit a profile script for the blocks the cso-toolkit contract expects
#'
#' Reads a `profile_<repo>.R` file and runs a series of presence checks for
#' the building blocks the cso-toolkit IO + API contract depends on (the
#' profile sentinel, cross-platform user identification, YAML config load,
#' producer / reviewer `dw_mode` resolution, the `dw_require_no_api` guard,
#' a reproducibility seed, and a packages block). It warns when the profile
#' reads only top-level keys of `user_config.yml`, which nests each person's
#' settings under their user name (DW-Production's template), and when the
#' repository's `cso_project.yml` sets `collaboration: multi-producer` but the
#' profile never calls `dw_collaboration()`.
#'
#' This is intentionally pattern-based, not parse-based: it greps for the
#' load-bearing lines so it tolerates stylistic variation across profiles
#' that were hand-written before this helper existed. Each check reports
#' `"pass"`, `"warn"`, or `"fail"`.
#'
#' @param path Character. Path to the profile script to audit.
#' @param require_dw_mode Logical. Treat absence of the `dw_mode` block as a
#'   `"fail"` (default `TRUE`) or as a `"warn"` (set `FALSE` for profiles
#'   that do not interact with `dw_io.R` / `dw_api.R`).
#' @param require_z_drive_check Logical. Default `FALSE` -- most CSO projects
#'   do not need the Z: advisory; flag as a warning only when missing.
#' @param verbose Logical. Print a formatted summary to the console (default
#'   `TRUE`).
#'
#' @return A data frame with columns `check`, `status`
#'   (`"pass"` / `"warn"` / `"fail"`), and `detail`, invisibly.
#'
#' @examples
#' \dontrun{
#' review_profile("profile_DW-Production.R")
#' review_profile("profile_my-project.R", require_dw_mode = FALSE)
#' }
#' @seealso [create_profile()] (generates a profile that passes every
#'   check by construction); [test_scripts()] for the script-level audit.
#' @family scaffolding
#' @param debug Logical or `NULL`. Show internal troubleshooting detail.
#'   `NULL` (default) inherits `getOption("dw.debug", FALSE)`; implies
#'   `verbose`. See [dw_verbosity()].
#' @export
review_profile <- function(path,
                           require_dw_mode = TRUE,
                           require_z_drive_check = FALSE,
                           verbose = TRUE,
                           debug = NULL) {
  if (!file.exists(path)) {
    stop(sprintf(
      "[cso_toolkit.review_profile] Profile file not found: %s\n  Fix: pass the correct path; relative paths resolve against %s.",
      path, getwd()
    ), call. = FALSE)
  }
  src <- readLines(path, warn = FALSE)
  vd <- .dw_vd(verbose, debug); v <- vd$v; d <- vd$d
  .dw_msg("review_profile", "auditing ", basename(path), v = v)
  .dw_dbg("review_profile", "read ", length(src), " lines from ", path, " | require_dw_mode=", require_dw_mode, " require_z_drive_check=", require_z_drive_check, d = d)
  joined <- paste(src, collapse = "\n")

  has <- function(pattern, perl = TRUE) {
    any(grepl(pattern, src, perl = perl))
  }

  result <- function(check, ok, ok_detail, fail_detail, level = "fail") {
    if (ok) list(check = check, status = "pass", detail = ok_detail)
    else    list(check = check, status = level,  detail = fail_detail)
  }

  checks <- list()

  # 1. Profile sentinel: `<name> <- TRUE` where <name> starts with "profile_"
  sentinel_pattern <- "(?m)^\\s*profile_[A-Za-z0-9_]+\\s*<-\\s*TRUE\\b"
  sentinel_hit <- regmatches(joined, regexpr(sentinel_pattern, joined, perl = TRUE))
  checks[[length(checks) + 1]] <- result(
    "Profile sentinel object",
    length(sentinel_hit) > 0 && nchar(sentinel_hit) > 0,
    paste0("Found: ", trimws(sentinel_hit)),
    "Missing `profile_<repo> <- TRUE` sentinel -- sector scripts cannot verify the profile was sourced."
  )

  # 2. User identification -- at least USERNAME or USER env read
  checks[[length(checks) + 1]] <- result(
    "Cross-platform user identification",
    has("Sys\\.getenv\\(\\s*\"USERNAME\"") || has("Sys\\.getenv\\(\\s*\"USER\""),
    "Reads USERNAME / USER via Sys.getenv().",
    "Profile never reads USERNAME / USER -- Mac/Linux/Windows paths may break."
  )

  # 3. Reproducibility seed
  checks[[length(checks) + 1]] <- result(
    "Reproducibility seed",
    has("set\\.seed\\("),
    "set.seed() is called.",
    "No set.seed() call -- reruns are not bit-reproducible.",
    level = "warn"
  )

  # 4. user_config.yml load
  loads_yaml <- has("user_config\\.ya?ml") &&
                (has("yaml::read_yaml") || has("read_yaml\\(") || has("yaml::yaml\\.load"))
  checks[[length(checks) + 1]] <- result(
    "user_config.yml load",
    loads_yaml,
    "Loads user_config.yml via yaml::read_yaml().",
    "Profile never reads user_config.yml -- per-user paths and dw_mode cannot resolve."
  )

  # 4b. The user's block. DW-Production's user_config.yml template nests each
  #     person's settings under their user name; a profile that reads only
  #     top-level keys (user_config$dw_mode) finds no dw_mode in such a file.
  reads_user_block <- has("\\[\\[\\s*USERNAME\\s*\\]\\]") || has("\\$\\s*`?USERNAME") ||
    has("\\buser_block\\b")
  checks[[length(checks) + 1]] <- result(
    "User block in user_config.yml",
    reads_user_block,
    "Reads the settings under the user's name (user_config[[USERNAME]]).",
    paste0("Reads top-level keys only -- with the user_config.yml template (settings nested under ",
           "the user name, as in DW-Production) dw_mode and the paths resolve to NULL. Read ",
           "user_config[[USERNAME]] first, then top-level keys (create_profile() emits this)."),
    level = "warn"
  )

  # 5. dw_mode block
  dw_mode_present <- has("dw_mode") && has("producer") && has("reviewer")
  checks[[length(checks) + 1]] <- result(
    "dw_mode (producer/reviewer) resolution",
    dw_mode_present,
    "dw_mode resolved against producer / reviewer.",
    "dw_mode block missing -- dw_io.R / dw_api.R route-by-mode contract will not engage.",
    level = if (require_dw_mode) "fail" else "warn"
  )

  # 6. dw_require_no_api guard
  checks[[length(checks) + 1]] <- result(
    "dw_require_no_api guard",
    has("dw_require_no_api"),
    "dw_require_no_api() is defined or invoked.",
    "dw_require_no_api() not defined -- reviewer mode cannot enforce the no-API rule.",
    level = if (require_dw_mode) "fail" else "warn"
  )

  # 7. Z: drive advisory (optional)
  checks[[length(checks) + 1]] <- result(
    "Z: drive availability advisory",
    has("dw_z_available") || has("network_root\\s*<-\\s*\"Z:"),
    "Z: drive availability is checked.",
    "Z: drive advisory not present -- runs without the legacy mirror will be silent.",
    level = if (require_z_drive_check) "fail" else "warn"
  )

  # 8. Collaboration-model block (cso_project.yml). Warn when the project
  #    is multi-producer but the profile never resolves / shows the model.
  proj_file <- .dw_find_project_file(dirname(normalizePath(path, winslash = "/", mustWork = FALSE)))
  proj_model <- if (is.na(proj_file)) "single-producer" else
    tryCatch(.dw_read_project(proj_file)$collaboration, error = function(e) "invalid")
  has_collab_block <- has("dw_collaboration\\s*\\(")
  checks[[length(checks) + 1]] <- if (has_collab_block) {
    list(check = "Collaboration model block", status = "pass",
         detail = "Resolves the collaboration model with dw_collaboration().")
  } else if (identical(proj_model, "multi-producer")) {
    list(check = "Collaboration model block", status = "warn",
         detail = paste0(proj_file, " sets multi-producer but the profile never calls dw_collaboration() -- ",
                         "add the block create_profile() emits so every session shows the model at load."))
  } else if (identical(proj_model, "invalid")) {
    list(check = "Collaboration model block", status = "warn",
         detail = paste0(proj_file, " cannot be read -- run dw_collaboration() to see the error."))
  } else {
    list(check = "Collaboration model block", status = "pass",
         detail = "Single-producer project (no multi-producer cso_project.yml); the block is optional.")
  }

  # 9. Required packages block
  checks[[length(checks) + 1]] <- result(
    "Packages block",
    has("requireNamespace\\(") || has("install\\.packages\\(") || has("library\\("),
    "A packages block is present.",
    "No requireNamespace / install.packages / library() calls -- pipeline likely fails on first run.",
    level = "warn"
  )

  out <- do.call(rbind, lapply(checks, function(c) {
    data.frame(check = c$check, status = c$status, detail = c$detail,
               stringsAsFactors = FALSE)
  }))

  if (v) {
    icon <- function(s) switch(s, pass = "[OK]", warn = "[!] ", fail = "[X]", " ")
    cat("\nProfile review:", normalizePath(path, mustWork = FALSE), "\n")
    cat(strrep("-", 72), "\n", sep = "")
    for (i in seq_len(nrow(out))) {
      cat(sprintf("%s %-44s %s\n",
                  icon(out$status[i]), out$check[i], out$detail[i]))
    }
    n_fail <- sum(out$status == "fail")
    n_warn <- sum(out$status == "warn")
    n_pass <- sum(out$status == "pass")
    cat(strrep("-", 72), "\n", sep = "")
    cat(sprintf("%d passed, %d warnings, %d failures.\n",
                n_pass, n_warn, n_fail))
  }

  .dw_dbg("review_profile", "checks: ", nrow(out), " total | ", sum(out$status == "pass"), " pass / ", sum(out$status == "warn"), " warn / ", sum(out$status == "fail"), " fail", d = d)
  invisible(out)
}

# =============================================================================
# v0.4.5 — dw_-prefixed canonical aliases (issue #42)
# =============================================================================

#' @rdname create_profile
#' @export
dw_create_profile <- create_profile

#' @rdname review_profile
#' @export
dw_review_profile <- review_profile
