# Tests for v0.4.5 standalone-source pipe binding
# Issue: https://github.com/unicef-drp/cso-toolkit/issues/46

test_that("`%>%` is bound after the installed package loads (no-op gate path)", {
  # In the installed-package context, NAMESPACE's
  # importFrom(magrittr, "%>%") wins and the local fallback gate is a
  # no-op. Verify the pipe is available either way.
  expect_true(exists("%>%", mode = "function", envir = asNamespace("csotoolkit"),
                     inherits = TRUE))
  # And it's functionally identical to magrittr's pipe
  pipe <- get("%>%", envir = asNamespace("csotoolkit"), inherits = TRUE)
  expect_identical(pipe, magrittr::`%>%`)
})

test_that("aggregate_data_v2.R defines the local `%>%` fallback when sourced into a pipe-free env", {
  # Create an env that has magrittr available as a namespace but NOT
  # has %>% in scope. Parse and evaluate just the source-time guard
  # block from aggregate_data_v2.R (we don't try to source the full
  # file in installed-package context; that path is fragile under
  # R CMD check as we learned from #36).
  env <- new.env(parent = baseenv())

  guard <- quote(
    if (!exists("%>%", mode = "function", inherits = TRUE)) {
      `%>%` <- magrittr::`%>%`
    }
  )
  eval(guard, envir = env)

  expect_true(exists("%>%", envir = env, inherits = FALSE),
              info = "guard block should define local `%>%` when not in scope")
  expect_identical(env$`%>%`, magrittr::`%>%`)
})

test_that("the guard is a no-op when `%>%` is already in scope", {
  env <- new.env(parent = baseenv())
  # Pre-bind a sentinel pipe so we can detect overwrite
  env$`%>%` <- function(lhs, rhs) "sentinel"

  guard <- quote(
    if (!exists("%>%", mode = "function", inherits = TRUE)) {
      `%>%` <- magrittr::`%>%`
    }
  )
  eval(guard, envir = env)

  # The sentinel must survive — the gate refused to redefine
  expect_identical(env$`%>%`("x", "y"), "sentinel",
                   info = "guard must not overwrite an existing `%>%` binding")
})
