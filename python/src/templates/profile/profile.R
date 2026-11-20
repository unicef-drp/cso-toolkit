#-------------------------------------------------------------------
# Project: {{title}}
# Script : profile_{{project_name}}.R
# Purpose: Sets up every R session in this repository: who is running,
#          their user_config.yml and dw_mode, the collaboration model,
#          and the vendored cso-toolkit helpers (00_functions/).
# Usage  : source("profile_{{project_name}}.R") from the repository root,
#          first thing in every script and interactive session.
# Created: {{date}} by cso-toolkit's {{fn}}() (The CSO Handbook,
#          "Starting a new repository"). It is yours now: extend it.
#
# Conventions (cso-toolkit create_profile(), review_profile()):
#   - dw_mode has no default: the profile stops until user_config.yml
#     sets it;
#   - packages are never installed from here: a missing one stops the
#     session with the list, so a run's environment never changes
#     without its user knowing;
#   - the sentinel profile_{{sentinel}} <- TRUE comes last, so scripts can
#     refuse to run without the profile.
#-------------------------------------------------------------------

# Reproducibility seed. Scripts that draw random numbers also set their
# own seed before they do, so results never depend on what ran earlier.
set.seed(12345)

#----------------------------------------
# 1. User identification (cross-platform)
#----------------------------------------
USERNAME <- Sys.getenv("USERNAME")
if (!nzchar(USERNAME)) USERNAME <- Sys.getenv("USER")
USERPROFILE <- Sys.getenv("USERPROFILE")                 # Windows
if (!nzchar(USERPROFILE)) USERPROFILE <- Sys.getenv("HOME")
if (!nzchar(USERPROFILE)) USERPROFILE <- path.expand("~")

#----------------------------------------
# 2. Repository root: the folder holding cso_project.yml
#----------------------------------------
repo_name <- "{{project_name}}"
if (!exists("rootFolder") || !is.character(rootFolder) || !nzchar(rootFolder)) {
  rootFolder <- local({
    d <- normalizePath(getwd(), winslash = "/")
    repeat {
      if (file.exists(file.path(d, "cso_project.yml"))) break
      parent <- dirname(d)
      if (identical(parent, d)) {
        stop("[X] profile: no cso_project.yml in ", getwd(), " or above.\n",
             "    Source the profile from inside the repository, or set rootFolder first.",
             call. = FALSE)
      }
      d <- parent
    }
    d
  })
}
rootFolder <- normalizePath(rootFolder, winslash = "/")
projectFolder <- rootFolder                          # sector scripts build paths from it
dwFunct <- file.path(rootFolder, "00_functions")     # the vendored cso-toolkit helpers

#----------------------------------------
# 3. Packages (never installed automatically)
#----------------------------------------
# Add the packages your code needs to the call below; scripts can call
# require_packages() for their own lists.
require_packages <- function(pkgs, who = "profile") {
  missing <- pkgs[!vapply(pkgs, requireNamespace, logical(1), quietly = TRUE)]
  if (length(missing)) {
    stop(sprintf("[X] %s: missing R package(s): %s\n    Install them once with install.packages(c(%s)) and rerun.",
                 who, paste(missing, collapse = ", "),
                 paste0('"', missing, '"', collapse = ", ")), call. = FALSE)
  }
  invisible(TRUE)
}
require_packages(c("yaml"))

#----------------------------------------
# 4. User config (YAML required): ~/.config/user_config.yml
#----------------------------------------
# One file serves every cso-toolkit project (DW-Production's template):
# your settings sit in a block named after your user name
# (Sys.getenv("USERNAME") on Windows, USER elsewhere); top-level keys are
# read as a fallback.
#   <username>:
#     dw_mode: "reviewer"           # default for every project
#     dw_mode_by_project:           # optional, per repository
#       {{project_name}}: "producer"
config_path <- file.path(USERPROFILE, ".config", "user_config.yml")
config_hint <- sprintf(paste0(
  "    In %s, inside your user block:\n",
  "      %s:\n        dw_mode: \"reviewer\"\n",
  "    or, for this project only:\n",
  "      %s:\n        dw_mode_by_project:\n          %s: \"producer\"\n",
  "    (README.md, Quick start)."),
  config_path, USERNAME, USERNAME, repo_name)
if (!file.exists(config_path)) {
  stop("[X] profile: ", config_path, " not found. Create it:\n", config_hint, call. = FALSE)
}
user_config <- yaml::read_yaml(config_path)  # cso-allow: io-yaml
if (!is.list(user_config)) user_config <- list()
user_block <- if (is.list(user_config[[USERNAME]])) user_config[[USERNAME]] else list()
user_setting <- function(key) {
  if (!is.null(user_block[[key]])) user_block[[key]] else user_config[[key]]
}

#----------------------------------------
# 5. Session mode: dw_mode (required, no default)
#----------------------------------------
# reviewer: reproduce and review; no external API calls, no writes to
#           canonical locations. producer: deliberately produce or refresh.
# Precedence (as DW-Production's dw_mode_by_sector): dw_mode_by_project for
# this repository, then dw_mode; each from the user block first.
dw_mode_by_project <- user_setting("dw_mode_by_project")
if (!is.null(dw_mode_by_project) && !is.list(dw_mode_by_project)) {
  stop("[X] profile: dw_mode_by_project must map project names to \"producer\" or ",
       "\"reviewer\", not a single value.\n", config_hint, call. = FALSE)
}
dw_mode <- dw_mode_by_project[[repo_name]]
if (is.null(dw_mode)) dw_mode <- user_setting("dw_mode")
if (!(is.character(dw_mode) && length(dw_mode) == 1 &&
      dw_mode %in% c("producer", "reviewer"))) {
  stop("[X] profile: no valid dw_mode (\"producer\" or \"reviewer\") for ", repo_name, ".\n",
       config_hint, call. = FALSE)
}
dw_apis_allowed <- identical(dw_mode, "producer")
# Guard for code about to call an external API: a no-op for a producer.
dw_require_no_api <- function(context = NULL) {
  if (identical(dw_mode, "reviewer")) {
    msg <- "[X] External API access is forbidden in reviewer mode."
    if (!is.null(context)) msg <- paste0(msg, " Context: ", context)
    stop(msg, call. = FALSE)
  }
  invisible(NULL)
}

{{deposit_block}}
#----------------------------------------
# Vendored cso-toolkit helpers (00_functions/)
#----------------------------------------
# zzz.R first: it defines the internals the other helpers call.
if (length(list.files(dwFunct, pattern = "\\.R$"))) {
  local({
    fs <- sort(list.files(dwFunct, pattern = "\\.R$", full.names = TRUE))
    for (f in c(fs[basename(fs) == "zzz.R"], fs[basename(fs) != "zzz.R"])) {
      sys.source(f, envir = globalenv())
    }
  })
} else {
  message("[!] profile: no helpers in 00_functions/ yet; vendor them (00_functions/README.md).")
}
cso_toolkit_version <- tryCatch(
  yaml::read_yaml(file.path(dwFunct, ".toolkit_manifest.yml"))$pulled_version,  # cso-allow: io-yaml
  error = function(e) NULL)
if (is.null(cso_toolkit_version)) cso_toolkit_version <- "not vendored"

#----------------------------------------
# Collaboration model (cso_project.yml: a project setting, committed)
#----------------------------------------
# dw_mode above is per person; how many people may PRODUCE results is the
# project's, the same for everyone.
if (exists("dw_collaboration", mode = "function")) {
  dw_collaboration_model <- dw_collaboration(root = rootFolder, refresh = TRUE)
} else {
  dw_collaboration_model <- tryCatch(
    yaml::read_yaml(file.path(rootFolder, "cso_project.yml"))$collaboration,  # cso-allow: io-yaml
    error = function(e) NULL)
  if (is.null(dw_collaboration_model)) dw_collaboration_model <- "single-producer"
}

#----------------------------------------
# Profile sentinel (last)
#----------------------------------------
# Scripts can refuse to run without the profile:
#   if (!exists("profile_{{sentinel}}")) stop("source profile_{{project_name}}.R first")
profile_{{sentinel}} <- TRUE
message(sprintf("[OK] profile_{{project_name}}.R loaded: user %s, dw_mode %s, %s, cso-toolkit %s",
                USERNAME, dw_mode, dw_collaboration_model, cso_toolkit_version))
