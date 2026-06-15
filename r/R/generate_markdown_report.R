################################################################################
# Script Name: Generate Markdown Reports for CSV Files
# Author: Joao Pedro Azevedo
# Date: 20240409 (original); 2026-05-24 (cso-toolkit hygiene pass)
# Version: 1.1
#
# Description:
# This script processes all CSV files in a specified folder, generates summary
# statistics and descriptive statistics reports in Markdown format for each file.
# The reports include general preamble information, variable details, and optional
# summaries by country, year, and indicator if the necessary columns are present.
#
# Usage:
# - Set the folder path containing CSV files and the output path for saving Markdown reports.
# - Define the column names for country, year, indicator, and value.
# - Call the `process_all_csv_files` function with the specified parameters.
#
# Dependencies:
# - R packages: dplyr, readr, rlang (all calls are namespace-qualified; the
#   helper does NOT attach packages at source-time).
#
# Notes:
# - The script handles missing columns gracefully by skipping summaries if columns
#   are not found and still outputs the preambles.
# - Ensure that the folder paths and column names are correctly specified.
#
# Example:
# folder_path <- "path/to/csv/folder"
# output_path <- "path/to/output/directory"
# process_all_csv_files(folder_path, "countrycode", "year", "indicator", "value", output_path)
#
################################################################################

# NOTE: `.cso_require()` lives in zzz.R as a single shared helper.
# Dependency checks happen INSIDE the public function body
# (generate_markdown_report) below, not at file source-time, so
# vendoring this file does not force the dependency at source().

#' Generate a descriptive-statistics Markdown report from a single CSV file
#'
#' Reads the CSV at `csv_file_path` and writes a Markdown report that
#' includes:
#' \itemize{
#'   \item A general preamble (filename, timestamp, user, number of
#'         observations, number of unique countries / years / indicators,
#'         number of variables).
#'   \item A variable-details table (type, unique cases, mean / SD / min /
#'         max for numerics).
#'   \item Optional summary tables by country, year, and indicator (only
#'         when those columns are present in the input).
#' }
#'
#' Columns that are not present are skipped silently — the preamble still
#' renders.
#'
#' @param csv_file_path Character. Path to the input CSV.
#' @param country_column Character. Column name holding country identifiers.
#' @param year_column Character. Column name holding year values.
#' @param indicator_column Character. Column name holding indicator codes.
#' @param value_column Character. Column name holding the numeric value to
#'   summarise.
#' @param output_path Character. Directory to write `<basename>.md` into.
#'   Default `NULL` writes the file in the current working directory.
#' @param verbose Logical or `NULL`. Show high-level progress and result
#'   messages. `NULL` (default) inherits `getOption("dw.verbose", TRUE)`;
#'   set `TRUE`/`FALSE` to override for this call. See [dw_verbosity()].
#' @param debug Logical or `NULL`. Show internal troubleshooting detail
#'   (resolved paths, dims, branch decisions). `NULL` (default) inherits
#'   `getOption("dw.debug", FALSE)`; implies `verbose`. See [dw_verbosity()].
#'
#' @return Invisibly, `NULL`. Side effect: writes a `.md` file.
#'
#' @examples
#' \dontrun{
#' generate_markdown_report(
#'   "input.csv",
#'   country_column   = "countrycode",
#'   year_column      = "year",
#'   indicator_column = "indicator",
#'   value_column     = "value",
#'   output_path      = "reports/"
#' )
#' }
#' @seealso [process_all_csv_files()] to loop over a folder of CSVs.
#' @family reporting
#' @param verbose Logical or `NULL`. Show high-level progress and result
#'   messages. `NULL` (default) inherits `getOption("dw.verbose", TRUE)`;
#'   set `TRUE`/`FALSE` to override for this call. See [dw_verbosity()].
#' @param debug Logical or `NULL`. Show internal troubleshooting detail.
#'   `NULL` (default) inherits `getOption("dw.debug", FALSE)`; implies
#'   `verbose`. See [dw_verbosity()].
#' @export
generate_markdown_report <- function(csv_file_path, country_column, year_column, indicator_column, value_column, output_path = NULL, verbose = NULL, debug = NULL) {

  .cso_require(c("dplyr", "readr", "rlang"), where = "generate_markdown_report")

  vd <- .dw_vd(verbose, debug); v <- vd$v; d <- vd$d
  .dw_msg("generate_markdown_report", "reading ", basename(csv_file_path), v = v)
  .dw_dbg("generate_markdown_report", "csv_file_path=", csv_file_path, " output_path=", if (is.null(output_path)) "<cwd>" else output_path, d = d)

  # Read the CSV file (generic helper accepting an arbitrary path; dw_use
  # is not applicable because the file is not part of the warehouse layout).
  data <- readr::read_csv(csv_file_path, show_col_types = FALSE)  # cso-allow: io-read-csv

  # Calculate general preamble information
  time_date <- Sys.time()
  user <- Sys.info()[["user"]]
  filename <- basename(csv_file_path)
  num_unique_countries <- if (country_column %in% names(data)) dplyr::n_distinct(data[[country_column]]) else NA
  num_unique_years <- if (year_column %in% names(data)) dplyr::n_distinct(data[[year_column]]) else NA
  num_unique_indicators <- if (indicator_column %in% names(data)) dplyr::n_distinct(data[[indicator_column]]) else NA
  num_variables <- ncol(data)
  num_observations <- nrow(data)  # Number of observations (rows) in the dataset
  .dw_dbg("generate_markdown_report", "rows=", num_observations, " cols=", num_variables, " countries=", num_unique_countries, " years=", num_unique_years, " indicators=", num_unique_indicators, d = d)

  # Function to get variable details
  get_variable_details <- function(data) {
    details <- lapply(names(data), function(var_name) {
      var_data <- data[[var_name]]
      var_type <- if (is.numeric(var_data)) "Numeric" else "String"
      num_unique <- dplyr::n_distinct(var_data)

      if (var_type == "Numeric") {
        mean_val <- mean(var_data, na.rm = TRUE)
        sd_val <- stats::sd(var_data, na.rm = TRUE)
        min_val <- min(var_data, na.rm = TRUE)
        max_val <- max(var_data, na.rm = TRUE)

        c(var_name, var_type, num_unique,
          format(mean_val, scientific = FALSE, big.mark = ",", digits = 2),
          format(sd_val, scientific = FALSE, big.mark = ",", digits = 2),
          format(min_val, scientific = FALSE, big.mark = ",", digits = 2),
          format(max_val, scientific = FALSE, big.mark = ",", digits = 2))
      } else {
        c(var_name, var_type, num_unique, "", "", "", "")
      }
    })

    # Convert list to data frame
    details_df <- as.data.frame(do.call(rbind, details))
    names(details_df) <- c("Variable Name", "Type", "Unique Cases", "Mean", "SD", "Min", "Max")
    details_df
  }

  # Get variable details
  variable_details <- get_variable_details(data)

  # Function to summarize data — `N` is the row count in the group (NOT a
  # distinct-value count; previous label `N_Unique` was misleading).
  summarize_data <- function(data, group_var, value_var) {
    if (value_var %in% names(data)) {
      data |>
        dplyr::group_by(!!rlang::sym(group_var)) |>
        dplyr::summarise(
          N    = dplyr::n(),
          Mean = mean(!!rlang::sym(value_var), na.rm = TRUE),
          SD   = stats::sd(!!rlang::sym(value_var), na.rm = TRUE),
          Min  = min(!!rlang::sym(value_var), na.rm = TRUE),
          Max  = max(!!rlang::sym(value_var), na.rm = TRUE),
          .groups = "drop"
        ) |>
        dplyr::mutate(dplyr::across(dplyr::where(is.numeric), ~ format(.x, scientific = FALSE, big.mark = ",", digits = 2)))
    } else {
      warning(sprintf(
        "[cso_toolkit.generate_markdown_report] Column '%s' not found in data. Skipping summary statistics for '%s'.",
        value_var, group_var
      ), call. = FALSE)
      return(NULL)
    }
  }

  # Summarize by Country (if available)
  summary_by_country <- if (country_column %in% names(data)) {
    summarize_data(data, country_column, value_column)
  } else {
    NULL
  }

  # Summarize by Year (if available)
  summary_by_year <- if (year_column %in% names(data)) {
    summarize_data(data, year_column, value_column)
  } else {
    NULL
  }

  # Summarize by Indicator (if available)
  summary_by_indicator <- if (indicator_column %in% names(data)) {
    summarize_data(data, indicator_column, value_column)
  } else {
    NULL
  }

  # Create Markdown content
  markdown_content <- paste0(
    "# Descriptive Statistics Report\n\n",

    "## General Preamble\n\n",
    "- **Filename**: ", filename, "\n",
    "- **Date and Time**: ", format(time_date, "%Y-%m-%d %H:%M:%S"), "\n",
    "- **User**: ", user, "\n",
    "- **Number of Observations**: ", num_observations, "\n",
    "- **Number of Unique Country Names**: ", ifelse(is.na(num_unique_countries), "N/A", num_unique_countries), "\n",
    "- **Number of Unique Years**: ", ifelse(is.na(num_unique_years), "N/A", num_unique_years), "\n",
    "- **Number of Unique Indicators**: ", ifelse(is.na(num_unique_indicators), "N/A", num_unique_indicators), "\n",
    "- **Number of Variables in the Database**: ", num_variables, "\n\n",

    "## Variable Details Preamble\n\n",
    "| Variable Name | Type | Unique Cases | Mean | SD | Min | Max |\n",
    "|---------------|------|--------------|------|----|-----|-----|\n",
    paste(
      apply(variable_details, 1, function(row) paste("|", paste(row, collapse = " | "), "|")),
      collapse = "\n"
    ), "\n\n"
  )

  # Add summaries only if they are available
  if (!is.null(summary_by_country)) {
    markdown_content <- paste0(markdown_content,
                               "## Summary by Country\n\n",
                               "| ", country_column, " | N | Mean | SD | Min | Max |\n",
                               "|----------------|---------|------|------|-----|-----|\n",
                               paste(
                                 apply(summary_by_country, 1, function(row) paste("|", paste(row, collapse = " | "), "|")),
                                 collapse = "\n"
                               ), "\n\n"
    )
  }

  if (!is.null(summary_by_year)) {
    markdown_content <- paste0(markdown_content,
                               "## Summary by Year\n\n",
                               "| ", year_column, " | N | Mean | SD | Min | Max |\n",
                               "|-------------|---------|------|------|-----|-----|\n",
                               paste(
                                 apply(summary_by_year, 1, function(row) paste("|", paste(row, collapse = " | "), "|")),
                                 collapse = "\n"
                               ), "\n\n"
    )
  }

  if (!is.null(summary_by_indicator)) {
    markdown_content <- paste0(markdown_content,
                               "## Summary by Indicator\n\n",
                               "| ", indicator_column, " | N | Mean | SD | Min | Max |\n",
                               "|----------------|---------|------|------|-----|-----|\n",
                               paste(
                                 apply(summary_by_indicator, 1, function(row) paste("|", paste(row, collapse = " | "), "|")),
                                 collapse = "\n"
                               ), "\n"
    )
  }

  # Generate output file name based on CSV file name
  output_file_name <- paste0(tools::file_path_sans_ext(basename(csv_file_path)), ".md")

  # Determine the full output file path
  if (!is.null(output_path)) {
    output_file <- file.path(output_path, output_file_name)
  } else {
    output_file <- output_file_name
  }

  # Save the markdown content to the output file
  writeLines(markdown_content, con = output_file)
  .dw_msg("generate_markdown_report", "report saved to ", output_file, v = v)
}

#' Generate descriptive-statistics Markdown reports for every CSV in a folder
#'
#' Lists every `.csv` file in `folder_path` and calls
#' [generate_markdown_report()] on each. A thin convenience wrapper.
#'
#' @param folder_path Character. Directory containing input CSVs (not
#'   recursed).
#' @param country_column,year_column,indicator_column,value_column
#'   Column names — see [generate_markdown_report()].
#' @param output_path Character. Output directory for `.md` files. Default
#'   `NULL` writes into the current working directory.
#' @param verbose Logical or `NULL`. Show high-level progress and result
#'   messages. `NULL` (default) inherits `getOption("dw.verbose", TRUE)`;
#'   set `TRUE`/`FALSE` to override for this call. See [dw_verbosity()].
#' @param debug Logical or `NULL`. Show internal troubleshooting detail
#'   (resolved paths, dims, branch decisions). `NULL` (default) inherits
#'   `getOption("dw.debug", FALSE)`; implies `verbose`. See [dw_verbosity()].
#'
#' @return Invisibly, `NULL`.
#'
#' @examples
#' \dontrun{
#' process_all_csv_files(
#'   folder_path     = "data/raw/",
#'   country_column   = "countrycode",
#'   year_column      = "year",
#'   indicator_column = "indicator",
#'   value_column     = "value",
#'   output_path      = "reports/"
#' )
#' }
#' @seealso [generate_markdown_report()] (single-file engine).
#' @family reporting
#' @param verbose Logical or `NULL`. Show high-level progress and result
#'   messages. `NULL` (default) inherits `getOption("dw.verbose", TRUE)`;
#'   set `TRUE`/`FALSE` to override for this call. See [dw_verbosity()].
#' @param debug Logical or `NULL`. Show internal troubleshooting detail.
#'   `NULL` (default) inherits `getOption("dw.debug", FALSE)`; implies
#'   `verbose`. See [dw_verbosity()].
#' @export
process_all_csv_files <- function(folder_path, country_column, year_column, indicator_column, value_column, output_path = NULL, verbose = NULL, debug = NULL) {
  # List all CSV files in the folder
  csv_files <- list.files(path = folder_path, pattern = "\\.csv$", full.names = TRUE)

  # Loop through each CSV file and generate a Markdown report
  vd <- .dw_vd(verbose, debug); v <- vd$v; d <- vd$d
  .dw_msg("process_all_csv_files", "found ", length(csv_files), " CSV file(s) in ", folder_path, v = v)
  .dw_dbg("process_all_csv_files", "folder_path=", folder_path, " output_path=", if (is.null(output_path)) "<cwd>" else output_path, d = d)

  for (csv_file in csv_files) {
    .dw_msg("process_all_csv_files", "processing ", csv_file, v = v)
    generate_markdown_report(csv_file, country_column, year_column, indicator_column, value_column, output_path, verbose = v, debug = d)
  }
}

# =============================================================================
# v0.4.5 — dw_-prefixed canonical aliases (issue #42)
# =============================================================================

#' @rdname generate_markdown_report
#' @export
dw_generate_markdown_report <- generate_markdown_report

#' @rdname process_all_csv_files
#' @export
dw_process_all_csv_files <- process_all_csv_files
