# Tests for the "total" method added to aggregate_data_v2() in v0.4.10.
# "total" returns an additive count/stock total (sum(value)) for person-count
# indicators (mg refugees/IDPs/migrant-stock, dm population/births), as opposed
# to the existing "sum" method which returns a population-weighted rate.

test_that('method = "total" returns the additive sum of values per group and global', {
  df <- data.frame(
    REF_AREA    = c("AAA", "BBB", "CCC", "DDD"),
    Region_Code = c("R1", "R1", "R2", "R2"),
    value       = c(100, 200, 50, 25),
    weight      = c(10, 20, 5, 5),
    stringsAsFactors = FALSE
  )
  out <- aggregate_data_v2(df, value = "value", weight = "weight",
                           by = "Region_Code", method = "total",
                           global = TRUE, global_label = "WORLD")
  agg <- stats::setNames(out$Aggregate, out$Region_Code)
  expect_equal(unname(agg["R1"]), 300)    # 100 + 200
  expect_equal(unname(agg["R2"]), 75)     # 50 + 25
  expect_equal(unname(agg["WORLD"]), 375) # grand total
})

test_that('method = "total" ignores the weight scale (unlike "sum")', {
  df <- data.frame(
    REF_AREA    = c("AAA", "BBB"),
    Region_Code = c("R1", "R1"),
    value       = c(40, 60),
    weight      = c(1, 1000),
    stringsAsFactors = FALSE
  )
  out <- aggregate_data_v2(df, value = "value", weight = "weight",
                           by = "Region_Code", method = "total", global = FALSE)
  expect_equal(out$Aggregate[out$Region_Code == "R1"], 100)
})

test_that('existing "sum" method still returns the population-weighted rate (regression)', {
  df <- data.frame(
    REF_AREA    = c("AAA", "BBB"),
    Region_Code = c("R1", "R1"),
    value       = c(50, 50),
    weight      = c(10, 30),
    stringsAsFactors = FALSE
  )
  out <- aggregate_data_v2(df, value = "value", weight = "weight",
                           by = "Region_Code", method = "sum", global = FALSE)
  # (50 + 50) / (10 + 30) * 100 = 250
  expect_equal(out$Aggregate[out$Region_Code == "R1"], 250)
})

test_that('method = "total" drops NA values (na.rm) and totals the rest', {
  df <- data.frame(
    REF_AREA    = c("AAA", "BBB", "CCC"),
    Region_Code = c("R1", "R1", "R1"),
    value       = c(100, NA, 200),
    weight      = c(10, 10, 10),
    stringsAsFactors = FALSE
  )
  out <- aggregate_data_v2(df, value = "value", weight = "weight",
                           by = "Region_Code", method = "total", global = FALSE)
  expect_equal(out$Aggregate[out$Region_Code == "R1"], 300)
})
