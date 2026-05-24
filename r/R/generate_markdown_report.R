################################################################################
# Script Name: Generate Markdown Reports for CSV Files
# Author: Joao Pedro Azevedo
# Date: 20240409
# Version: 1.0
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
# - R packages: dplyr, readr, tidyr
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


# Function to generate Markdown report for a single CSV file

generate_markdown_report <- function(csv_file_path, country_column, year_column, indicator_column, value_column, output_path = NULL) {

  
  # Read the CSV file
  data <- read_csv(csv_file_path)
  
  # Calculate general preamble information
  time_date <- Sys.time()
  user <- Sys.info()[["user"]]
  filename <- basename(csv_file_path)
  num_unique_countries <- if (country_column %in% names(data)) n_distinct(data[[country_column]]) else NA
  num_unique_years <- if (year_column %in% names(data)) n_distinct(data[[year_column]]) else NA
  num_unique_indicators <- if (indicator_column %in% names(data)) n_distinct(data[[indicator_column]]) else NA
  num_variables <- ncol(data)
  num_observations <- nrow(data)  # Number of observations (rows) in the dataset
  
  # Function to get variable details
  get_variable_details <- function(data) {
    details <- lapply(names(data), function(var_name) {
      var_data <- data[[var_name]]
      var_type <- if (is.numeric(var_data)) "Numeric" else "String"
      num_unique <- n_distinct(var_data)
      
      if (var_type == "Numeric") {
        mean_val <- mean(var_data, na.rm = TRUE)
        sd_val <- sd(var_data, na.rm = TRUE)
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
  
  # Function to summarize data
  summarize_data <- function(data, group_var, value_var) {
    if (value_var %in% names(data)) {
      data %>%
        group_by(!!sym(group_var)) %>%
        summarise(
          N_Unique = n(),
          Mean = mean(!!sym(value_var), na.rm = TRUE),
          SD = sd(!!sym(value_var), na.rm = TRUE),
          Min = min(!!sym(value_var), na.rm = TRUE),
          Max = max(!!sym(value_var), na.rm = TRUE)
        ) %>%
        mutate(across(where(is.numeric), ~ format(.x, scientific = FALSE, big.mark = ",", digits = 2))) %>%
        ungroup()
    } else {
      warning("Column '", value_var, "' not found in data. Skipping summary statistics for ", group_var)
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
                               "| ", country_column, " | N_Unique | Mean | SD | Min | Max |\n",
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
                               "| ", year_column, " | N_Unique | Mean | SD | Min | Max |\n",
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
                               "| ", indicator_column, " | N_Unique | Mean | SD | Min | Max |\n",
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
  message("Markdown report saved to ", output_file)
}

# Function to process all CSV files in a folder
process_all_csv_files <- function(folder_path, country_column, year_column, indicator_column, value_column, output_path = NULL) {
  # List all CSV files in the folder
  csv_files <- list.files(path = folder_path, pattern = "\\.csv$", full.names = TRUE)
  
  # Loop through each CSV file and generate a Markdown report
  for (csv_file in csv_files) {
    message("Processing file: ", csv_file)
    generate_markdown_report(csv_file, country_column, year_column, indicator_column, value_column, output_path)
  }
}


#return message
message("The function 'generate_markdown_report' was loaded successfully.")