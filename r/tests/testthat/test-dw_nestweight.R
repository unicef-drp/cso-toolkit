test_that("dw_nestweight preserves stratum totals", {
  dhs <- data.frame(
    stratum   = c("A", "A", "A", "B", "B"),
    stunting  = c(1, NA, 0, 1, NA),
    hh_weight = c(10, 20, 30, 40, 60)
  )
  out <- dw_nestweight(dhs, value = "stunting", by = "stratum",
                      weight = "hh_weight", verbose = FALSE)
  orig <- tapply(dhs$hh_weight, dhs$stratum, sum)
  adj  <- tapply(out$weight_adj, out$stratum, sum)
  for (k in names(orig)) {
    expect_lt(abs(orig[[k]] - adj[[k]]), 1e-9)
  }
})

test_that("dw_nestweight zeros weights on missing-value rows", {
  d <- data.frame(s = c("X","X"), v = c(1, NA), w = c(2, 3))
  out <- dw_nestweight(d, value = "v", by = "s", weight = "w", verbose = FALSE)
  # The NA row should get weight 0; the observed row should absorb
  # the redistributed mass: 2 -> (2 + 3) = 5.
  expect_equal(out$weight_adj[is.na(out$v)], 0)
  expect_equal(out$weight_adj[!is.na(out$v)], 5)
})

test_that("dw_nestweight errors with the envelope on missing column", {
  d <- data.frame(s = c("X","X"))
  err <- tryCatch(
    dw_nestweight(d, value = "missing", by = "s", verbose = FALSE),
    error = identity
  )
  expect_s3_class(err, "error")
  expect_envelope(err, function_name = "dw_nestweight")
})
