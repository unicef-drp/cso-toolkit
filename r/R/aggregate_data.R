#' Aggregate Data with Optional Weighting and Global Aggregation
#'
#' This function aggregates data by specified grouping variables, with options for
#' weighted aggregation and global aggregation. It calculates coverage of non-NA
#' values and allows for mean or weighted mean aggregation methods.
#'
#' @param data A data frame containing the data to be aggregated.
#' @param value The name of the column in `data` that contains the values to aggregate.
#' @param weight The name of the column in `data` that contains the weights for weighted aggregation.
#' @param by A character vector of column names in `data` to group by for aggregation.
#' @param global Logical; if TRUE, includes a global aggregation ignoring the `by` groups.
#' @param pop.coverage Logical; if TRUE, shows share of child population in the reference group covered with data
#' @param method The method of aggregation; either "mean" for unweighted mean or "weighted_mean" for weighted mean.
#' @return A data frame with aggregated data.
#' @export 
#' @examples
#' data <- data.frame(
#'   region = rep(c("North", "South"), each = 5),
#'   value = c(1:10),
#'   weight = c(5:14)
#' )
#' 
#' aggregate_data(data, "value", "weight", "region", TRUE, TRUE, "mean")



aggregate_data <- function(data, value, weight, by, 
                           global = TRUE, 
                           method = c("mean", "weighted_mean"), 
                           pop.coverage = FALSE, country.coverage = FALSE) {
  
  # Ensure method is matched to allowed methods
  method <- match.arg(method)
  
  # Convert character inputs to symbols for tidy evaluation
  value_sym   <- rlang::sym(value)
  weight_sym  <- rlang::sym(weight)
  by_syms     <- rlang::syms(by)
  
  # Calculate actual coverage as the ratio of sum of weights for non-NA values to total sum of weights
  data <- data %>%
    drop_na(all_of(by)) %>%
    group_by(across(!!!by_syms)) %>%
    mutate(total_weight = sum(!!weight_sym, na.rm = TRUE),  # Total weight per group
           weight_non_na = ifelse(!is.na(!!value_sym), !!weight_sym, 0),  # Weight for non-NA values
           coverage_actual = sum(weight_non_na, na.rm = TRUE) / total_weight, # Actual coverage
           non_na_count = ifelse(!is.na(!!value_sym), 1, 0)) %>%
    ungroup()
  
  # Aggregation based on method
  aggregated_data <- data %>%
    group_by(across(!!!by_syms)) %>%
    summarise(
      Aggregate = dplyr::case_when(
        method == "mean" ~ mean(!!value_sym, na.rm = TRUE),
        method == "weighted_mean" ~ weighted.mean(!!value_sym, !!weight_sym, na.rm = TRUE)
      ),
      Pop_Covered = mean(coverage_actual, na.rm = TRUE),  # Include population coverage if requested
      Country_Coverage = sum(non_na_count, na.rm = TRUE),  # Correctly count non-NA rows in value
      .groups = 'drop'
    )
  
  # Conditionally include coverage in the output
  if (!pop.coverage) {
    aggregated_data <- aggregated_data %>% select(-Pop_Covered)
  }
  if (!country.coverage) {
    aggregated_data <- aggregated_data %>% select(-Country_Coverage)
  }
  
  # Add global aggregation if requested
  if (global) {
    global_aggregate <- data %>%
      summarise(
        Aggregate = dplyr::case_when(
          method == "mean" ~ mean(!!value_sym, na.rm = TRUE),
          method == "weighted_mean" ~ weighted.mean(!!value_sym, !!weight_sym, na.rm = TRUE)
        ),
        Pop_Covered = sum(weight_non_na, na.rm = TRUE) / sum(!!weight_sym, na.rm = TRUE),  # Global population coverage
        Country_Coverage = sum(non_na_count, na.rm = TRUE)  # Correctly count non-NA rows globally
      )
    
    # Conditionally include coverage for the global aggregate
    if (!pop.coverage) {
      global_aggregate <- global_aggregate %>% select(-Pop_Covered)
    }
    if (!country.coverage) {
      global_aggregate <- global_aggregate %>% select(-Country_Coverage)
    }
    
    # Prepare global aggregate for binding
    global_aggregate <- global_aggregate %>%
      mutate(!!by := "World")  
    
    aggregated_data <- bind_rows(aggregated_data, global_aggregate)
  }
  
  return(aggregated_data)
}
