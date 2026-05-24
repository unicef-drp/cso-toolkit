#---------------------------------------------------------------------
# cso-toolkit: Sector Run Script Generator
#---------------------------------------------------------------------
# Purpose : Auto-generate a prefilled 00_run_<sector>.R script for a
#           data-warehouse sector pipeline.
# Origin  : Lifted from DW-Production/00_functions/create_sector_script.R
#           (2025-06-05). Generalized so the output path is no longer
#           hard-coded to DW-Production's 01_dw_prep/012_codes/ layout.
#---------------------------------------------------------------------

#' Generate a prefilled sector-run script for a data-warehouse pipeline
#'
#' Creates `<base_dir>/<sector_code>/00_run_<sector_code>.R` populated with a
#' template that includes profile verification, time-stamped logging, runtime
#' tracking, try-catch error handling, and placeholder input/output paths.
#'
#' @param sector_name Character. Full name of the sector (e.g., "Nutrition",
#'   "WASH").
#' @param sector_code Character. Short abbreviation used in the folder
#'   structure and filenames (e.g., "nt", "ws").
#' @param base_dir Character. Parent directory under which
#'   `<sector_code>/00_run_<sector_code>.R` will be created. Defaults to
#'   `"."` (current working directory). For DW-Production consumers, see
#'   [`create_dw_sector_script()`] which passes the canonical
#'   `"01_dw_prep/012_codes"` layout.
#' @param profile_name Character. Name of the project profile object the
#'   generated script will check for. Defaults to
#'   `"profile_DW_Production"`. Set to the consumer's own profile object
#'   name if different.
#' @param profile_file Character. Filename of the project profile the
#'   generated script will instruct users to source on failure. Defaults to
#'   `"profile_DW-Production.R"`.
#' @param input_subpath Character vector. Path components, relative to
#'   `projectFolder` (as defined in the profile), that the generated script
#'   uses as the sector's input folder. Defaults to
#'   `c("01_dw_prep", "011_input")`.
#' @param output_subpath Character vector. Same idea, for the sector's
#'   output folder. Defaults to `c("01_dw_prep", "013_output")`.
#' @param overwrite Logical. If `FALSE` (default), stops when the target file
#'   already exists. Set `TRUE` to overwrite.
#'
#' @return Invisibly, the path of the file written. Prints a confirmation
#'   message.
#'
#' @examples
#' \dontrun{
#' # Generic usage — writes ./ws/00_run_ws.R relative to cwd:
#' create_sector_script("WASH", "ws")
#'
#' # Targeting a specific subtree of your project:
#' create_sector_script("Nutrition", "nt", base_dir = "pipelines/sectors")
#' }
#' @export
create_sector_script <- function(sector_name,
                                 sector_code,
                                 base_dir = ".",
                                 profile_name = "profile_DW_Production",
                                 profile_file = "profile_DW-Production.R",
                                 input_subpath = c("01_dw_prep", "011_input"),
                                 output_subpath = c("01_dw_prep", "013_output"),
                                 overwrite = FALSE) {
  user <- Sys.getenv("USERNAME", unset = Sys.info()[["user"]])
  timestamp <- format(Sys.time(), "%Y-%m-%d %H:%M")

  script_dir <- file.path(base_dir, sector_code)
  script_path <- file.path(script_dir, paste0("00_run_", sector_code, ".R"))

  if (!dir.exists(script_dir)) {
    dir.create(script_dir, recursive = TRUE)
  }

  if (file.exists(script_path) && !overwrite) {
    stop("File already exists: ", script_path,
         "\nPass overwrite = TRUE to replace it.")
  }

  input_path_call  <- paste0(
    "file.path(projectFolder, \"",
    paste(c(input_subpath,  sector_code), collapse = "\", \""),
    "\")"
  )
  output_path_call <- paste0(
    "file.path(projectFolder, \"",
    paste(c(output_subpath, sector_code), collapse = "\", \""),
    "\")"
  )

  template <- c(
    "#-------------------------------------------------------------",
    paste0("# ", sector_name, " Run Script"),
    "#-------------------------------------------------------------",
    paste0("# File     : ", script_path),
    paste0("# Purpose  : Executes ", sector_name, " data preparation steps"),
    paste0("# Author   : ", user),
    paste0("# Created  : ", timestamp),
    "#-------------------------------------------------------------",
    paste0("# This script is called by the project's top-level runner."),
    paste0("# Required packages must be loaded by ", profile_file, "."),
    "#-------------------------------------------------------------",
    "",
    "#=======================#",
    "# 0. Profile Verification",
    "#=======================#",
    paste0("if (!exists(\"", profile_name, "\") || !isTRUE(", profile_name, ")) {"),
    paste0("  stop(\"❌ Project profile not loaded. Please source('", profile_file, "') before running this script.\")"),
    "}",
    "",
    "# Fallback for log_message() if the project profile did not define one.",
    "# The DW-Production profile ships a richer log_message; this stub lets",
    "# the template run out-of-the-box for projects that have not yet wired",
    "# logging.",
    "if (!exists(\"log_message\") || !is.function(log_message)) {",
    "  log_message <- function(msg) {",
    "    message(format(Sys.time(), \"[%Y-%m-%d %H:%M:%S]\"), \" \", msg)",
    "  }",
    "}",
    "",
    "# Sector-error flag consumed by the top-level runner. Initialised here",
    "# so the tryCatch handler below can set it with <<- without depending",
    "# on the caller having pre-declared the global.",
    "if (!exists(\"errorOccurred\")) errorOccurred <- FALSE",
    "",
    "#=======================#",
    paste0("# 1. Start Logging for ", sector_name),
    "#=======================#",
    "",
    paste0("log_message(\"\U0001f4e6 Starting ", sector_name, " module\")"),
    "start_time <- Sys.time()",
    "",
    "#=======================#",
    "# 2. Sector Execution Block",
    "#=======================#",
    "",
    "tryCatch({",
    "",
    "  #-------------------------------------------------------------",
    "  # 2.1 Define input and output paths",
    "  #-------------------------------------------------------------",
    paste0("  input_folder  <- ", input_path_call),
    paste0("  output_folder <- ", output_path_call),
    "  dir.create(output_folder, recursive = TRUE, showWarnings = FALSE)",
    "",
    "  #-------------------------------------------------------------",
    "  # 2.2 Load and process data (customize below)",
    "  #-------------------------------------------------------------",
    "  # Example:",
    "  # raw_data <- read_csv(file.path(input_folder, \"input_file.csv\"))",
    "  # processed_data <- raw_data %>%",
    "  #   filter(!is.na(indicator)) %>%",
    "  #   group_by(country) %>%",
    "  #   summarize(value = mean(value, na.rm = TRUE))",
    "",
    "  #-------------------------------------------------------------",
    "  # 2.3 Export outputs",
    "  #-------------------------------------------------------------",
    "  # write_csv(processed_data, file.path(output_folder, \"cleaned_data.csv\"))",
    "",
    "  #-------------------------------------------------------------",
    "  # 2.4 Wrap up",
    "  #-------------------------------------------------------------",
    "  duration <- round(difftime(Sys.time(), start_time, units = \"secs\"), 1)",
    paste0("  log_message(paste(\"✅ ", sector_name, " module completed | Duration:\", duration, \"seconds\"))"),
    "",
    "}, error = function(e) {",
    "  errorOccurred <<- TRUE",
    paste0("  log_message(paste(\"❌ Error in ", sector_name, " module:\", e$message))"),
    "})"
  )

  writeLines(template, con = script_path)
  message("✅ Sector script created: ", script_path)
  invisible(script_path)
}

#' Generate a prefilled sector-run script using DW-Production conventions
#'
#' Thin convenience wrapper around [`create_sector_script()`] that fills in
#' the DW-Production layout: scripts land at
#' `01_dw_prep/012_codes/<sector_code>/00_run_<sector_code>.R`, input under
#' `01_dw_prep/011_input/<sector_code>`, output under
#' `01_dw_prep/013_output/<sector_code>`. Suitable for use inside the
#' DW-Production repo root.
#'
#' @inheritParams create_sector_script
#' @param project_root Character. Project root the relative `base_dir` is
#'   resolved against. Defaults to `"."` (assumes you are at the
#'   DW-Production repo root when calling).
#'
#' @return Invisibly, the path of the file written.
#'
#' @examples
#' \dontrun{
#' # From the DW-Production repo root, scaffold the WASH sector:
#' create_dw_sector_script("WASH", "ws")
#' }
#' @export
create_dw_sector_script <- function(sector_name,
                                    sector_code,
                                    project_root = ".",
                                    overwrite = FALSE) {
  create_sector_script(
    sector_name    = sector_name,
    sector_code    = sector_code,
    base_dir       = file.path(project_root, "01_dw_prep", "012_codes"),
    profile_name   = "profile_DW_Production",
    profile_file   = "profile_DW-Production.R",
    input_subpath  = c("01_dw_prep", "011_input"),
    output_subpath = c("01_dw_prep", "013_output"),
    overwrite      = overwrite
  )
}
