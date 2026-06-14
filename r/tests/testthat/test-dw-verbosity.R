# Tests for the toolkit-wide verbose/debug convention (.dw_v/.dw_d/.dw_vd,
# .dw_msg/.dw_dbg, dw_verbosity(), and per-call/option resolution on helpers).

test_that(".dw_vd resolves debug-implies-verbose and both-off", {
  op <- options(dw.verbose = TRUE, dw.debug = FALSE); on.exit(options(op), add = TRUE)
  vd <- .dw_vd(verbose = FALSE, debug = TRUE)
  expect_true(vd$v)            # debug implies verbose even when verbose = FALSE
  expect_true(vd$d)
  vd2 <- .dw_vd(verbose = FALSE, debug = FALSE)
  expect_false(vd2$v)
  expect_false(vd2$d)
})

test_that(".dw_v / .dw_d honour options and per-call overrides", {
  op <- options(dw.verbose = TRUE, dw.debug = FALSE); on.exit(options(op), add = TRUE)
  expect_true(.dw_v())         # inherit option (default TRUE)
  expect_false(.dw_d())        # inherit option (default FALSE)
  expect_false(.dw_v(FALSE))   # explicit override beats option
  expect_true(.dw_d(TRUE))
  options(dw.verbose = FALSE)
  expect_false(.dw_v())        # option change respected
})

test_that(".dw_msg / .dw_dbg emit prefixed messages and stay silent when off", {
  expect_message(.dw_msg("demo", "hello", v = TRUE), "\\[cso_toolkit\\.demo\\] hello")
  expect_silent(.dw_msg("demo", "hello", v = FALSE))
  expect_message(.dw_dbg("demo", "detail", d = TRUE), "\\[cso_toolkit\\.demo:debug\\] detail")
  expect_silent(.dw_dbg("demo", "detail", d = FALSE))
})

test_that("dw_verbosity() sets session options and returns the resolved state", {
  op <- options(dw.verbose = TRUE, dw.debug = FALSE); on.exit(options(op), add = TRUE)
  res <- suppressMessages(dw_verbosity(verbose = FALSE, debug = TRUE))
  expect_false(getOption("dw.verbose"))
  expect_true(getOption("dw.debug"))
  expect_false(res$verbose)
  expect_true(res$debug)
})

test_that("entry-point verbosity: dw_isid announces, silences, and debugs", {
  op <- options(dw.verbose = TRUE, dw.debug = FALSE); on.exit(options(op), add = TRUE)
  df <- data.frame(REF_AREA = c("AGO", "BFA"), OBS_VALUE = c(1, 2))
  expect_message(dw_isid(df, "REF_AREA"), "\\[cso_toolkit\\.dw_isid\\] OK")
  expect_silent(dw_isid(df, "REF_AREA", verbose = FALSE))
  expect_message(dw_isid(df, "REF_AREA", debug = TRUE), "\\[cso_toolkit\\.dw_isid:debug\\]")
})

test_that("dw_compare honours verbose = FALSE and surfaces debug traces", {
  op <- options(dw.verbose = TRUE, dw.debug = FALSE); on.exit(options(op), add = TRUE)
  cur <- data.frame(REF_AREA = c("AGO", "BFA", "KEN"), OBS_VALUE = c(1, 2, 3))
  ref <- data.frame(REF_AREA = c("AGO", "BFA"),        OBS_VALUE = c(1, 9))
  expect_silent(dw_compare(cur, ref, by = "REF_AREA",
                           numeric_value_cols = "OBS_VALUE", verbose = FALSE))
  expect_message(dw_compare(cur, ref, by = "REF_AREA", numeric_value_cols = "OBS_VALUE"),
                 "\\[cso_toolkit\\.dw_compare\\]")
  expect_message(dw_compare(cur, ref, by = "REF_AREA",
                            numeric_value_cols = "OBS_VALUE", debug = TRUE),
                 "\\[cso_toolkit\\.dw_compare:debug\\]")
})

test_that("pure lookups expose debug only (no verbose output)", {
  op <- options(dw.verbose = TRUE, dw.debug = FALSE); on.exit(options(op), add = TRUE)
  expect_silent(dw_toolkit_version())                # no verbose line even with dw.verbose = TRUE
  expect_message(dw_toolkit_version(debug = TRUE),
                 "\\[cso_toolkit\\.dw_toolkit_version:debug\\]")
})
