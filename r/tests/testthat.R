# Entry point that R CMD check runs to execute the testthat suite.
# Individual test files live in tests/testthat/test-*.R; testthat
# auto-sources helper-*.R files first to set up shared fixtures.

library(testthat)
library(csotoolkit)

test_check("csotoolkit")
