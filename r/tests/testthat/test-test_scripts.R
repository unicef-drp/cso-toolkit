test_that("test_scripts returns an empty frame on a clean directory", {
  tdir <- local_tempdir()
  # A file that uses only the toolkit wrappers:
  writeLines(
    c("dw_save(df, name = 'x.csv', sector = 'ed', kind = 'wrk')",
      "warehouse <- dw_use(name = 'x.csv', sector = 'ed', kind = 'wrk')"),
    con = file.path(tdir, "clean.R")
  )
  out <- test_scripts(tdir, verbose = FALSE)
  expect_equal(nrow(out), 0)
})

test_that("test_scripts catches direct read_csv usage", {
  tdir <- local_tempdir()
  writeLines(
    c("df <- read_csv('x.csv')"),
    con = file.path(tdir, "bad.R")
  )
  out <- test_scripts(tdir, verbose = FALSE)
  expect_true("io-read-csv" %in% out$rule)
})

test_that("test_scripts catches direct httr::GET usage", {
  tdir <- local_tempdir()
  writeLines("resp <- httr::GET('https://example.com')",
             con = file.path(tdir, "bad.R"))
  out <- test_scripts(tdir, verbose = FALSE)
  expect_true("api-httr" %in% out$rule)
})

test_that("test_scripts honors per-line `# cso-allow:` escape hatch", {
  tdir <- local_tempdir()
  writeLines(
    "config <- yaml::read_yaml(p)  # cso-allow: io-yaml",
    con = file.path(tdir, "exempt.R")
  )
  out <- test_scripts(tdir, verbose = FALSE)
  expect_equal(nrow(out), 0)
})

test_that("test_scripts(error_on_violation = TRUE) raises the envelope", {
  tdir <- local_tempdir()
  writeLines("df <- read_csv('x.csv')", con = file.path(tdir, "bad.R"))
  err <- tryCatch(
    test_scripts(tdir, error_on_violation = TRUE, verbose = FALSE),
    error = identity
  )
  expect_s3_class(err, "error")
  expect_envelope(err, function_name = "test_scripts")
})

test_that("test_scripts errors with the envelope on missing path", {
  err <- tryCatch(test_scripts("/nonexistent/path/here", verbose = FALSE),
                  error = identity)
  expect_s3_class(err, "error")
  expect_envelope(err, function_name = "test_scripts")
})

test_that("api-fromjson-url fires on a URL string, not on other fromJSON calls (#237)", {
  tdir <- local_tempdir()
  writeLines(c(
    "x <- jsonlite::fromJSON('https://example.org/a.json')",
    "y <- fromJSON(\"http://example.org/b.json\")",
    "z <- jsonlite::fromJSON(txt)",
    "w <- fromJSON('{\"a\": 1}')",
    "v <- fromJSON('https://example.org/c.json')  # cso-allow: api-fromjson-url"
  ), file.path(tdir, "s.R"))
  out <- test_scripts(tdir, verbose = FALSE)
  hits <- out$line[out$rule == "api-fromjson-url"]
  expect_identical(sort(hits), c(1L, 2L))
})
