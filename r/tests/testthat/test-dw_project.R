# Project-level collaboration model (cso_project.yml): dw_collaboration(),
# dw_set_collaboration(), the multi-producer dw_save() guards and lineage
# fields, the API refresh rule and the profile checks.

# Sidecar keys a single-producer dw_save() has always written (with metadata).
.SINGLE_KEYS <- c("path", "format", "written_at", "user", "dw_mode", "vintage",
                  "sha256", "isid", "schema", "metadata")
.LINEAGE_KEYS <- c("collaboration", "previous_sha256", "previous_user",
                   "previous_written_at", "git_branch", "git_commit")

write_project <- function(dir, model = "multi-producer", extra = character(0)) {
  writeLines(c("schema: cso_project/1", paste0("collaboration: ", model),
               "collaboration_since: 2026-11-20", extra),
             file.path(dir, "cso_project.yml"))
}

# A multi-producer session with no dw_mode (plain local writes: no mirror
# pre-flight, no reviewer lock), started long ago unless told otherwise.
local_multi <- function(start = "2000-01-01T00:00:00+0000", .frame = parent.frame()) {
  local_state(dw_collaboration_model = "multi-producer", dw_session_start = start,
              dw_mode = NULL, .frame = .frame)
}

save_as <- function(user, df, path, ...) {
  withr::with_envvar(c(USERNAME = user),
    suppressMessages(dw_save(df, path = path, overwrite = TRUE, ...)))
}

# --- dw_collaboration(): discovery and validation -----------------------------

test_that("no cso_project.yml means single-producer", {
  d <- local_tempdir()
  dir.create(file.path(d, ".git"))       # repository root: the walk stops here
  local_state(dw_collaboration_model = NULL, dw_project_file = NULL,
              dw_session_start = NULL)
  expect_identical(dw_collaboration(root = d), "single-producer")
  expect_true(is.na(get("dw_project_file", envir = .GlobalEnv)))
  expect_match(get("dw_session_start", envir = .GlobalEnv),
               "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\+0000$")
})

test_that("the file is found by walking up and the model is cached", {
  d <- local_tempdir()
  dir.create(file.path(d, ".git"))
  write_project(d, "multi-producer")
  sub <- file.path(d, "a", "b"); dir.create(sub, recursive = TRUE)
  local_state(dw_collaboration_model = NULL, dw_project_file = NULL,
              dw_session_start = NULL)
  expect_identical(dw_collaboration(root = sub), "multi-producer")
  expect_identical(get("dw_collaboration_model", envir = .GlobalEnv), "multi-producer")
  # Cached: a later edit is not seen until refresh.
  write_project(d, "single-producer")
  expect_identical(dw_collaboration(), "multi-producer")
  expect_identical(dw_collaboration(root = sub, refresh = TRUE), "single-producer")
})

test_that("the walk stops at the repository root", {
  parent <- local_tempdir()
  write_project(parent, "multi-producer")          # a parent folder's file ...
  repo <- file.path(parent, "repo"); dir.create(file.path(repo, ".git"), recursive = TRUE)
  local_state(dw_collaboration_model = NULL, dw_project_file = NULL)
  expect_identical(dw_collaboration(root = repo), "single-producer")  # ... is ignored
})

test_that("an unknown model or schema stops with the envelope", {
  d <- local_tempdir(); dir.create(file.path(d, ".git"))
  local_state(dw_collaboration_model = NULL, dw_project_file = NULL)
  write_project(d, "everyone-produces")
  err <- tryCatch(dw_collaboration(root = d), error = identity)
  expect_s3_class(err, "error")
  expect_envelope(err, "dw_collaboration")
  writeLines(c("schema: cso_project/9", "collaboration: multi-producer"),
             file.path(d, "cso_project.yml"))
  err <- tryCatch(dw_collaboration(root = d), error = identity)
  expect_envelope(err, "dw_collaboration")
  expect_match(conditionMessage(err), "cso_project/9")
})

# --- dw_save(): single-producer unchanged ------------------------------------

test_that("single-producer sidecars keep exactly today's key set", {
  d <- local_tempdir()
  local_state(dw_collaboration_model = "single-producer", dw_mode = NULL)
  out <- file.path(d, "x.csv")
  save_as("jp", data.frame(a = 1:2), out, metadata = list(title = "t"))
  save_as("karen", data.frame(a = 3:4), out, metadata = list(title = "t"))
  prov <- jsonlite::read_json(paste0(out, ".provenance.json"))
  expect_identical(names(prov), .SINGLE_KEYS)
})

# --- dw_save(): multi-producer guards ----------------------------------------

test_that("multi-producer: a write over another producer's output only notes it", {
  d <- local_tempdir()
  local_multi(start = "2999-01-01T00:00:00+0000")   # karen wrote before this session
  out <- file.path(d, "x.csv")
  save_as("karen", data.frame(a = 1:2), out)
  karen <- jsonlite::read_json(paste0(out, ".provenance.json"))
  msgs <- withr::with_envvar(c(USERNAME = "jp"), testthat::capture_messages(
    dw_save(data.frame(a = 3:4), path = out, overwrite = TRUE)))
  expect_true(any(grepl("\\[cso_toolkit\\.dw_save\\] note: x.csv was last written by karen", msgs)))
  prov <- jsonlite::read_json(paste0(out, ".provenance.json"))
  expect_identical(names(prov)[seq_along(.LINEAGE_KEYS) + 9L], .LINEAGE_KEYS)
  expect_identical(prov$collaboration, "multi-producer")
  expect_identical(prov$previous_sha256, karen$sha256)
  expect_identical(prov$previous_user, "karen")
  expect_identical(prov$previous_written_at, karen$written_at)
  expect_true(all(c("git_branch", "git_commit") %in% names(prov)))
  expect_null(prov$git_branch)   # temp dir: not a git repository -> null
  expect_null(prov$takeover)
})

test_that("multi-producer: the first write records null previous_* fields", {
  d <- local_tempdir()
  local_multi()
  out <- file.path(d, "new.csv")
  save_as("jp", data.frame(a = 1), out)
  prov <- jsonlite::read_json(paste0(out, ".provenance.json"))
  expect_true(all(.LINEAGE_KEYS %in% names(prov)))
  expect_null(prov$previous_sha256)
  expect_null(prov$previous_user)
  expect_null(prov$previous_written_at)
})

test_that("multi-producer: an out-of-band change stops with the envelope", {
  d <- local_tempdir()
  local_multi(start = "2999-01-01T00:00:00+0000")
  out <- file.path(d, "x.csv")
  save_as("jp", data.frame(a = 1:2), out)
  cat("9\n", file = out, append = TRUE)            # changed without dw_save()
  err <- withr::with_envvar(c(USERNAME = "jp"), tryCatch(
    suppressMessages(dw_save(data.frame(a = 5), path = out, overwrite = TRUE)),
    error = identity))
  expect_s3_class(err, "error")
  expect_envelope(err, "dw_save")
  expect_match(conditionMessage(err), "out-of-band change")
  expect_match(conditionMessage(err), "takeover = TRUE")
  # Nothing was written: the out-of-band bytes are still there.
  expect_identical(tail(readLines(out), 1), "9")
})

test_that("multi-producer: the guards also apply in producer mode", {
  canon <- local_tempdir()
  local_state(dw_collaboration_model = "multi-producer",
              dw_session_start = "2999-01-01T00:00:00+0000",
              dw_mode = "producer", teamsWrkDataCanonical = canon)
  out <- file.path(canon, "x.csv")
  withr::with_envvar(c(USERNAME = "jp"), suppressMessages(
    dw_save(data.frame(a = 1), path = out, overwrite = TRUE, force = TRUE)))
  cat("9\n", file = out, append = TRUE)
  err <- withr::with_envvar(c(USERNAME = "jp"), tryCatch(suppressMessages(
    dw_save(data.frame(a = 2), path = out, overwrite = TRUE, force = TRUE)),
    error = identity))
  expect_envelope(err, "dw_save")
  expect_match(conditionMessage(err), "out-of-band change")
})

test_that("multi-producer: a concurrent write by another user stops", {
  d <- local_tempdir()
  local_multi(start = "2000-01-01T00:00:00+0000")   # karen writes after this start
  out <- file.path(d, "x.csv")
  save_as("karen", data.frame(a = 1:2), out)
  err <- withr::with_envvar(c(USERNAME = "jp"), tryCatch(
    suppressMessages(dw_save(data.frame(a = 5), path = out, overwrite = TRUE)),
    error = identity))
  expect_envelope(err, "dw_save")
  expect_match(conditionMessage(err), "concurrent write")
  expect_match(conditionMessage(err), "karen wrote it at")
})

test_that("multi-producer: the same user re-writing in the session is not concurrent", {
  d <- local_tempdir()
  local_multi(start = "2000-01-01T00:00:00+0000")
  out <- file.path(d, "x.csv")
  save_as("jp", data.frame(a = 1:2), out)
  expect_no_error(save_as("jp", data.frame(a = 3:4), out))
})

test_that("multi-producer: takeover = TRUE overrides the guards and is recorded", {
  d <- local_tempdir()
  local_multi(start = "2000-01-01T00:00:00+0000")
  out <- file.path(d, "x.csv")
  save_as("karen", data.frame(a = 1:2), out)
  cat("9\n", file = out, append = TRUE)            # out-of-band AND concurrent
  changed_sha <- digest::digest(file = out, algo = "sha256")
  msgs <- withr::with_envvar(c(USERNAME = "jp"), testthat::capture_messages(
    dw_save(data.frame(a = 5), path = out, overwrite = TRUE, takeover = TRUE)))
  expect_true(any(grepl("takeover: replacing x.csv despite out_of_band \\+ concurrent", msgs)))
  prov <- jsonlite::read_json(paste0(out, ".provenance.json"))
  expect_identical(prov$takeover$user, "jp")
  expect_match(prov$takeover$at, "\\+0000$")
  expect_identical(unlist(prov$takeover$overrode), c("out_of_band", "concurrent"))
  # The lineage records the bytes actually replaced.
  expect_identical(prov$previous_sha256, changed_sha)
  expect_identical(prov$previous_user, "karen")
})

test_that("multi-producer: reviewer sandbox writes skip the guards", {
  d <- local_tempdir()
  local_state(dw_collaboration_model = "multi-producer",
              dw_session_start = "2000-01-01T00:00:00+0000", dw_mode = "reviewer")
  out <- file.path(d, "x.csv")
  save_as("karen", data.frame(a = 1:2), out)
  cat("9\n", file = out, append = TRUE)
  expect_no_error(save_as("jp", data.frame(a = 3), out))
  prov <- jsonlite::read_json(paste0(out, ".provenance.json"))
  expect_identical(prov$collaboration, "multi-producer")   # lineage still recorded
})

# --- dw_set_collaboration() --------------------------------------------------

test_that("dw_set_collaboration baselines sidecars without touching their fields", {
  d <- local_tempdir()
  dir.create(file.path(d, ".git"))
  local_state(dw_collaboration_model = "single-producer", dw_project_file = NULL,
              dw_mode = NULL)
  out <- file.path(d, "sub", "x.csv")
  save_as("karen", data.frame(a = 1:2, b = c("x", "y")), out,
          metadata = list(title = "T", sources = c("A", "B")))
  sc <- paste0(out, ".provenance.json")
  before_txt <- rawToChar(readBin(sc, "raw", file.info(sc)$size))
  before <- jsonlite::read_json(sc)

  res <- withr::with_envvar(c(USERNAME = "jp"), suppressMessages(
    dw_set_collaboration("multi-producer", root = d, members = c("jp", "karen"))))
  expect_true(res$project_file_changed)
  expect_identical(res$sidecars_found, 1L)
  expect_identical(res$sidecars_updated, 1L)

  after_txt <- rawToChar(readBin(sc, "raw", file.info(sc)$size))
  after <- jsonlite::read_json(sc)
  expect_identical(after[names(before)], before)   # every field, incl. sha256
  expect_identical(after$sha256, digest::digest(file = out, algo = "sha256"))
  expect_identical(after$baseline$collaboration, "multi-producer")
  expect_identical(after$baseline$by, "jp")
  # Text insertion: the original bytes up to the closing brace are kept.
  expect_true(startsWith(after_txt, sub("[[:space:]]*\\}[[:space:]]*$", "", before_txt)))

  yml <- yaml::read_yaml(file.path(d, "cso_project.yml"))
  expect_identical(yml$schema, "cso_project/1")
  expect_identical(yml$collaboration, "multi-producer")
  expect_identical(unlist(yml$members), c("jp", "karen"))
  expect_identical(dw_collaboration(), "multi-producer")    # the session follows
})

test_that("dw_set_collaboration is idempotent", {
  d <- local_tempdir()
  dir.create(file.path(d, ".git"))
  local_state(dw_collaboration_model = "single-producer", dw_project_file = NULL,
              dw_mode = NULL)
  out <- file.path(d, "x.csv")
  save_as("karen", data.frame(a = 1), out)
  suppressMessages(dw_set_collaboration("multi-producer", root = d, members = "jp"))
  files <- c(file.path(d, "cso_project.yml"), paste0(out, ".provenance.json"))
  md5 <- tools::md5sum(files)
  res <- suppressMessages(dw_set_collaboration("multi-producer", root = d, members = "jp"))
  expect_false(res$project_file_changed)
  expect_identical(res$sidecars_updated, 0L)
  expect_identical(tools::md5sum(files), md5)
  # members = NULL keeps the list.
  suppressMessages(dw_set_collaboration("multi-producer", root = d))
  expect_identical(tools::md5sum(files), md5)
})

test_that("after the switch, the first write over a baselined output is silent and clean", {
  d <- local_tempdir()
  dir.create(file.path(d, ".git"))
  local_state(dw_collaboration_model = "single-producer", dw_project_file = NULL,
              dw_mode = NULL, dw_session_start = "2999-01-01T00:00:00+0000")
  out <- file.path(d, "x.csv")
  save_as("karen", data.frame(a = 1), out)
  old_sha <- digest::digest(file = out, algo = "sha256")
  suppressMessages(dw_set_collaboration("multi-producer", root = d))
  msgs <- withr::with_envvar(c(USERNAME = "jp"), testthat::capture_messages(
    dw_save(data.frame(a = 2), path = out, overwrite = TRUE)))
  expect_false(any(grepl("last written by", msgs)))   # project-owned: no alarm
  prov <- jsonlite::read_json(paste0(out, ".provenance.json"))
  expect_identical(prov$previous_sha256, old_sha)       # the chain starts cleanly
  expect_null(prov$baseline)
  # A later baseline run skips sidecars written under multi-producer.
  res <- suppressMessages(dw_set_collaboration("multi-producer", root = d))
  expect_identical(res$sidecars_updated, 0L)
})

test_that("dw_set_collaboration refuses in reviewer mode and rejects unknown models", {
  d <- local_tempdir()
  local_state(dw_mode = "reviewer")
  err <- tryCatch(dw_set_collaboration("multi-producer", root = d), error = identity)
  expect_envelope(err, "dw_set_collaboration")
  expect_false(file.exists(file.path(d, "cso_project.yml")))
  local_state(dw_mode = "producer")
  err <- tryCatch(dw_set_collaboration("three-producers", root = d), error = identity)
  expect_envelope(err, "dw_set_collaboration")
})

# --- API cache ---------------------------------------------------------------

test_that("multi-producer: refresh over another user's cache keeps the previous fetch", {
  raw <- local_tempdir()
  local_state(teamsRawData = raw, teamsRawDataCanonical = raw,
              teamsWrkDataCanonical = raw, dw_mode = "producer",
              dw_apis_allowed = TRUE, dw_collaboration_model = "multi-producer",
              dw_session_start = "2999-01-01T00:00:00+0000")
  src <- file.path(local_tempdir(), "src.csv")
  writeLines(c("a,b", "1,x"), src)
  withr::with_envvar(c(USERNAME = "karen"), suppressMessages(
    dw_api_fetch("csv", cache_key = "k", url = src)))
  cache <- file.path(raw, "_apis", "csv", "k.csv")
  karen <- jsonlite::read_json(paste0(cache, ".provenance.json"))
  writeLines(c("a,b", "2,y"), src)
  # Without refresh, karen's cache is read, never replaced.
  hit <- withr::with_envvar(c(USERNAME = "jp"), suppressMessages(
    dw_api_fetch("csv", cache_key = "k", url = src)))
  expect_equal(hit$a, 1)
  msgs <- withr::with_envvar(c(USERNAME = "jp"), testthat::capture_messages(
    dw_api_fetch("csv", cache_key = "k", url = src, refresh = TRUE)))
  expect_true(any(grepl("refresh replaces csv/k fetched by karen", msgs)))
  prov <- jsonlite::read_json(paste0(cache, ".provenance.json"))
  expect_identical(prov$metadata$previous_fetch$sha256, karen$sha256)
  expect_identical(prov$metadata$previous_fetch$user, "karen")
  expect_identical(prov$previous_sha256, karen$sha256)
  expect_identical(prov$user, "jp")
})

# --- profiles ----------------------------------------------------------------

test_that("create_profile emits the collaboration block and review_profile passes it", {
  d <- local_tempdir()
  dir.create(file.path(d, ".git"))
  write_project(d, "multi-producer")
  p <- suppressMessages(create_profile("collab", output_path = d))
  src <- readLines(p)
  expect_true(any(grepl("dw_collaboration(", src, fixed = TRUE)))
  expect_true(any(grepl("Collaboration model", src, fixed = TRUE)))
  rev <- review_profile(p, verbose = FALSE)
  expect_identical(rev$status[rev$check == "Collaboration model block"], "pass")
})

test_that("review_profile warns when a multi-producer project's profile lacks the block", {
  d <- local_tempdir()
  dir.create(file.path(d, ".git"))
  p <- suppressMessages(create_profile("old", output_path = d))
  src <- readLines(p)
  writeLines(src[!grepl("dw_collaboration", src)], p)      # a pre-existing profile
  rev <- review_profile(p, verbose = FALSE)                  # no cso_project.yml
  expect_identical(rev$status[rev$check == "Collaboration model block"], "pass")
  write_project(d, "multi-producer")
  rev <- review_profile(p, verbose = FALSE)
  row <- rev[rev$check == "Collaboration model block", ]
  expect_identical(row$status, "warn")
  expect_match(row$detail, "multi-producer")
})
