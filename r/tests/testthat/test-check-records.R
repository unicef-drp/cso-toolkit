# Check records (#174): tools/check.R --record writes and commits
# .checks/<content-hash>.json, the pre-push hook verifies it without R, and
# the scaffolded .gitignore never ignores a record. End to end in a
# scaffolded repository; skipped without git (and the hook tests without sh).

rscript <- function() file.path(R.home("bin"), if (.Platform$OS.type == "windows") "Rscript.exe" else "Rscript")

# A scaffolded research repository with one commit and a local git identity.
record_repo <- function(.frame = parent.frame()) {
	skip_if(!nzchar(Sys.which("git")), "git not installed")
	root <- file.path(withr::local_tempdir(.local_envir = .frame), "proj")
	create_research_project(root, collaboration = "single-producer", git = TRUE, verbose = FALSE)
	g <- function(...) {
		out <- suppressWarnings(system2("git", c("-C", shQuote(root), ...), stdout = TRUE, stderr = TRUE))
		as.character(out)
	}
	g("config", "user.name", shQuote("Record Tester"))   # system2 does not quote
	g("config", "user.email", "tester@example.org")
	g("add", "-A")
	g("commit", "-q", "-m", "scaffold")
	list(root = root, g = g)
}

# Run tools/check.R in the repository: the cheap checks only (CHECKS is the
# repository's own setting; the environment variable overrides the file).
run_check <- function(root, args = character(), checks = "tracked-data large-files sidecars") {
	out <- withr::with_dir(root, withr::with_envvar(c(CHECKS = checks), suppressWarnings(
		system2(rscript(), c("--no-init-file", "tools/check.R", args), stdout = TRUE, stderr = TRUE))))
	list(status = attr(out, "status") %||% 0L, out = out)
}

test_that("--record writes a passing record named by the content hash and commits it", {
	r <- record_repo()
	before <- r$g("rev-parse", "HEAD")
	res <- run_check(r$root, "--record")
	expect_identical(res$status, 0L, info = paste(res$out, collapse = "\n"))
	expect_true(any(grepl("committed check record", res$out)))
	# The hash: git's tree of the checked commit with .checks/ left out.
	lt <- r$g("ls-tree", before)
	tf <- tempfile(); con <- file(tf, "wb"); writeLines(lt[!grepl("\t\\.checks$", lt)], con, sep = "\n"); close(con)
	h <- withr::with_dir(r$root, system2("git", "mktree", stdin = tf, stdout = TRUE))
	f <- file.path(r$root, ".checks", paste0(h, ".json"))
	expect_true(file.exists(f))
	rec <- jsonlite::read_json(f)
	expect_identical(rec$result, "pass")
	expect_identical(rec$content_hash, h)
	expect_identical(rec$commit, before)
	expect_identical(rec$user, "Record Tester")
	expect_setequal(names(rec$checks), c("tracked-data", "large-files", "sidecars"))
	# Committed, alone, and the new commit keeps the same content hash.
	expect_match(r$g("log", "-1", "--format=%s"), "^Check record ")
	expect_identical(r$g("diff", "--name-only", "HEAD~1", "HEAD"), paste0(".checks/", h, ".json"))
	lt2 <- r$g("ls-tree", "HEAD")
	con <- file(tf, "wb"); writeLines(lt2[!grepl("\t\\.checks$", lt2)], con, sep = "\n"); close(con)
	expect_identical(withr::with_dir(r$root, system2("git", "mktree", stdin = tf, stdout = TRUE)), h)
	# A second run finds the record and makes no new commit.
	head <- r$g("rev-parse", "HEAD")
	again <- run_check(r$root, "--record")
	expect_true(any(grepl("already present", again$out)))
	expect_identical(r$g("rev-parse", "HEAD"), head)
})

test_that("--record refuses --only / --skip and a dirty tree", {
	r <- record_repo()
	expect_identical(run_check(r$root, c("--record", "--only", "sidecars"))$status, 2L)
	expect_identical(run_check(r$root, c("--record", "--skip", "tests"))$status, 2L)
	cat("# edit\n", file = file.path(r$root, "README.md"), append = TRUE)
	res <- run_check(r$root, "--record")
	expect_identical(res$status, 2L)
	expect_true(any(grepl("clean working tree", res$out)))
	expect_false(dir.exists(file.path(r$root, ".checks")) &&
	             length(list.files(file.path(r$root, ".checks"), "\\.json$")) > 0)
})

test_that("a failing check writes no record", {
	r <- record_repo()
	dir.create(file.path(r$root, "data"), showWarnings = FALSE)
	writeLines("x", file.path(r$root, "data", "raw.csv"))
	r$g("add", "-f", "data/raw.csv")
	r$g("commit", "-q", "-m", "track data")
	res <- run_check(r$root, "--record")
	expect_identical(res$status, 1L)
	expect_true(any(grepl("no record written", res$out)))
	expect_length(list.files(file.path(r$root, ".checks"), "\\.json$"), 0)
})

test_that("the pre-push hook passes a recorded tip and refuses one without a record", {
	r <- record_repo()
	sh <- Sys.which("sh")
	skip_if(!nzchar(sh), "sh not available")
	unrecorded <- r$g("rev-parse", "HEAD")
	run_check(r$root, "--record")
	recorded <- r$g("rev-parse", "HEAD")
	hook <- function(sha, mode = NULL) {
		tf <- tempfile()
		writeLines(sprintf("refs/heads/develop %s refs/heads/develop %s", sha, strrep("0", 40)), tf)
		env <- if (is.null(mode)) character() else c(CHECK_HOOK_MODE = mode)
		out <- withr::with_dir(r$root, withr::with_envvar(env, suppressWarnings(
			system2(sh, ".githooks/pre-push", stdin = tf, stdout = TRUE, stderr = TRUE))))
		list(status = attr(out, "status") %||% 0L, out = out)
	}
	ok <- hook(recorded)
	expect_identical(ok$status, 0L, info = paste(ok$out, collapse = "\n"))
	expect_true(any(grepl("has a passing check record", ok$out)))
	no <- hook(unrecorded)
	expect_identical(no$status, 1L)
	expect_true(any(grepl("sh tools/check --record", no$out, fixed = TRUE)))
	bad <- hook(recorded, mode = "sometimes")
	expect_identical(bad$status, 1L)
	expect_true(any(grepl("MODE must be verify or run", bad$out)))
})

test_that("neither .gitignore template ignores a check record", {
	skip_if(!nzchar(Sys.which("git")), "git not installed")
	for (create in list(create_research_project, create_official_stats_project)) {
		root <- file.path(withr::local_tempdir(), "p")
		create(root, collaboration = "single-producer", git = TRUE, verbose = FALSE)
		st <- attr(suppressWarnings(system2("git", c("-C", shQuote(root), "check-ignore", "-q", "--no-index",
		                                             ".checks/0123456789abcdef.json"),
		                                    stdout = TRUE, stderr = TRUE)), "status") %||% 0L
		expect_identical(st, 1L)                       # 1 = not ignored
	}
})
