# create_profile(include_z_drive_check = TRUE) must emit a timeout-bounded
# Z: probe, not a bare dir.exists() that can hang for the full SMB timeout on
# a dead-mapped Windows drive letter (#106 item 3).

generate_profile <- function(include_z, env = parent.frame()) {
  out <- withr::local_tempdir(.local_envir = env)
  path <- create_profile("zprobe", output_path = out,
                         include_z_drive_check = include_z, verbose = FALSE)
  list(path = path, text = readLines(path, warn = FALSE))
}

extract_probe <- function(path) {
  exprs <- parse(path)
  is_probe <- vapply(exprs, function(e) {
    is.call(e) && identical(e[[1]], as.name("<-")) &&
      identical(e[[2]], as.name(".dw_drive_available"))
  }, logical(1))
  env <- new.env()
  eval(exprs[[which(is_probe)]], envir = env)
  env$.dw_drive_available
}

test_that("Z1: the Z: block uses the timeout-bounded probe, not dir.exists()", {
  p <- generate_profile(TRUE)
  expect_true(any(grepl("^\\.dw_drive_available <- function\\(root, timeout = 3\\)", p$text)))
  expect_true(any(p$text == "dw_z_available <- .dw_drive_available(network_root)"))
  expect_false(any(grepl("dir.exists(network_root)", p$text, fixed = TRUE)))
  expect_silent(parse(p$path))
})

test_that("Z2: without include_z_drive_check there is no Z: block", {
  p <- generate_profile(FALSE)
  expect_false(any(grepl("dw_drive_available|network_root", p$text)))
})

test_that("Z3: the generated probe reports existing and missing paths", {
  probe <- extract_probe(generate_profile(TRUE)$path)
  expect_true(probe(tempdir()))
  expect_false(probe(file.path(tempdir(), "no-such-folder-zprobe")))
})

test_that("Z4: a drive-letter probe answers within the timeout (Windows)", {
  skip_on_os(c("mac", "linux", "solaris"))
  probe <- extract_probe(generate_profile(TRUE)$path)
  # Whatever Q: is on this machine (unmapped, live or dead-mapped), the probe
  # must return a single TRUE/FALSE without blocking past its timeout.
  elapsed <- system.time(res <- probe("Q:/", timeout = 3))[["elapsed"]]
  expect_true(isTRUE(res) || isFALSE(res))
  expect_lt(elapsed, 10)
})
