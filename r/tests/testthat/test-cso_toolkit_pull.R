# cso_toolkit_diff() / cso_toolkit_pull() / cso_toolkit_sync(): the update
# path for vendored helpers. Offline: a throwaway upstream repository with
# tags v0.1.0, v0.2.0, v0.10.0 (and a pre-release) stands in for
# cso-toolkit, read through `toolkit_source`; a consumer folder holds
# 00_functions/ at v0.1.0. One test reads the real repository on GitHub.
# Mirror: python/tests/test_cso_toolkit_pull.py.

up_git <- function(d, ...) {
	out <- suppressWarnings(system2("git", c("-C", shQuote(d), "-c", "user.name=test",
	                                         "-c", "user.email=test@example.org",
	                                         "-c", "core.autocrlf=false", ...),
	                                stdout = TRUE, stderr = TRUE))
	if ((attr(out, "status") %||% 0L) != 0L) stop(paste(out, collapse = "\n"))
	out
}

put <- function(d, rel, text) {
	p <- file.path(d, rel)
	dir.create(dirname(p), recursive = TRUE, showWarnings = FALSE)
	writeBin(charToRaw(text), p)
}

rbytes <- function(f) readBin(f, "raw", n = file.info(f)$size)

NEWS_010 <- "# NEWS\n\n## v0.1.0 (2026-01-01)\n\n### Added\n\n- first release\n"
NEWS_020 <- paste0("# NEWS\n\n## v0.2.0 (2026-02-01)\n\n### Added\n\n- a.R learns a trick\n\n",
                   "### Changed\n\n- a.R now returns a list\n\n",
                   "## v0.1.0 (2026-01-01)\n\n### Added\n\n- first release\n")
NEWS_0100 <- paste0("# NEWS\n\n## Unreleased\n\n- nothing yet\n\n",
                    "## v0.10.0 (2026-03-01)\n\n### Breaking\n\n- b.R drops an argument\n\n",
                    "### Fixed\n\n- a.R off-by-one\n\n",
                    "## v0.2.0 (2026-02-01)\n\n### Added\n\n- a.R learns a trick\n\n",
                    "### Changed\n\n- a.R now returns a list\n\n",
                    "## v0.1.0 (2026-01-01)\n\n### Added\n\n- first release\n")

# The upstream: r/R/{a,b,c,e,m,gone}.R and python/src/p.py; each tag
# changes some of them.
fake_upstream <- function(.frame = parent.frame()) {
	skip_if(!nzchar(Sys.which("git")), "git not installed")
	d <- tempfile("upstream_")
	withr::defer(unlink(d, recursive = TRUE, force = TRUE), envir = .frame)
	dir.create(d)
	put(d, "r/DESCRIPTION", "Package: csotoolkit\nVersion: 0.0.1\n")
	for (f in c("a", "b", "c", "e", "m", "gone")) put(d, paste0("r/R/", f, ".R"), sprintf("# %s at v0.1.0\n", f))
	put(d, "python/src/p.py", "# p at v0.1.0\n")
	put(d, "NEWS.md", NEWS_010)
	up_git(d, "init", "--quiet")
	up_git(d, "add", "-A")
	up_git(d, "commit", "--quiet", "-m", "v0.1.0")
	up_git(d, "tag", "v0.1.0")
	for (f in c("a", "b", "e", "m")) put(d, paste0("r/R/", f, ".R"), sprintf("# %s at v0.2.0\n", f))
	put(d, "python/src/p.py", "# p at v0.2.0\n")
	unlink(file.path(d, "r/R/gone.R"))
	put(d, "NEWS.md", NEWS_020)
	up_git(d, "add", "-A")
	up_git(d, "commit", "--quiet", "-m", "v0.2.0")
	up_git(d, "tag", "v0.2.0")
	put(d, "r/R/a.R", "# a at v0.10.0\n")
	put(d, "NEWS.md", NEWS_0100)
	up_git(d, "add", "-A")
	up_git(d, "commit", "--quiet", "-m", "v0.10.0")
	up_git(d, "tag", "-a", "v0.10.0", "-m", "v0.10.0")   # annotated, like a release
	put(d, "r/R/a.R", "# a at v0.11.0-rc1\n")
	up_git(d, "commit", "--quiet", "-a", "-m", "rc")
	up_git(d, "tag", "v0.11.0-rc1")
	put(d, "r/R/a.R", "# a in the working tree, never read\n")
	d
}

MANIFEST <- paste0(
	"# Vendoring manifest -- a comment that must survive\n",
	"source: \"unicef-drp/cso-toolkit\"\n",
	"pulled_version: \"v0.1.0\"   # the pin\n",
	"%DATE%\n",
	"pulled_by: \"someone\"\n",
	"# target_version: \"v0.2.0\"\n",
	"custom_key: keep me\n",
	"\n",
	"vendored:\n",
	"  - a.R\n  - b.R\n  - c.R\n  - e.R\n  - gone.R\n  - m.R\n  - p.py\n",
	"\n",
	"local_edits:\n  - e.R\n")

# A consumer repository (git, one commit) with 00_functions/ at v0.1.0.
# b.R is edited here without being listed; e.R is listed under local_edits;
# m.R is missing. `date` is the date line of the manifest.
fake_consumer <- function(up, date = "pulled_date: \"2026-01-02\"", extra = "",
                          .frame = parent.frame()) {
	d <- tempfile("consumer_")
	withr::defer(unlink(d, recursive = TRUE, force = TRUE), envir = .frame)
	fd <- file.path(d, "00_functions")
	dir.create(fd, recursive = TRUE)
	sha <- up_git(up, "rev-list", "-n", "1", "v0.1.0")
	for (f in c("a.R", "b.R", "c.R", "e.R", "gone.R")) {
		writeBin(.cso_git_blob(up, sha, paste0("r/R/", f)), file.path(fd, f))
	}
	writeBin(.cso_git_blob(up, sha, "python/src/p.py"), file.path(fd, "p.py"))
	put(fd, "b.R", "# b at v0.1.0, edited here\n")
	put(fd, ".toolkit_manifest.yml", paste0(sub("%DATE%", date, MANIFEST, fixed = TRUE), extra))
	up_git(d, "init", "--quiet")
	up_git(d, "add", "-A")
	up_git(d, "commit", "--quiet", "-m", "vendor-v0.1.0")
	fd
}

tag_blob <- function(up, tag, path) .cso_git_blob(up, up_git(up, "rev-list", "-n", "1", tag), path)
mf <- function(fd) readLines(file.path(fd, ".toolkit_manifest.yml"))

test_that("diff reports every status against a tag of a local clone", {
	up <- fake_upstream()
	fd <- fake_consumer(up)
	local_state(dw_apis_allowed = TRUE, dwFunct = fd)
	d <- cso_toolkit_diff("v0.2.0", toolkit_source = up, verbose = FALSE)
	st <- stats::setNames(d$status, d$file)
	expect_identical(st[["a.R"]], "changed")
	expect_identical(st[["p.py"]], "changed")          # python/src/
	expect_identical(st[["b.R"]], "local_edit")        # differs from what v0.1.0 shipped
	expect_identical(st[["e.R"]], "local_edit")        # listed under local_edits
	expect_identical(st[["c.R"]], "unchanged")
	expect_identical(st[["gone.R"]], "missing_upstream")
	expect_identical(st[["m.R"]], "missing_local")
	expect_identical(attr(d, "target_version"), "v0.2.0")
	expect_identical(attr(d, "target_commit"), up_git(up, "rev-list", "-n", "1", "v0.2.0"))
	expect_true(all(grepl("^[0-9a-f]{64}$", d$sha256_target[d$file != "gone.R"])))
	expect_true(is.na(d$sha256_local[d$file == "m.R"]))
	# CRLF-only differences are not changes.
	writeBin(charToRaw("# c at v0.1.0\r\n"), file.path(fd, "c.R"))
	d2 <- cso_toolkit_diff("0.2.0", toolkit_source = up, verbose = FALSE)
	expect_identical(d2$status[d2$file == "c.R"], "unchanged")
	expect_message(cso_toolkit_diff("v0.2.0", toolkit_source = up, verbose = TRUE),
	               "1 changed|2 changed")
})

test_that("diff takes the clone's latest release tag, compared numerically", {
	up <- fake_upstream()
	fd <- fake_consumer(up)
	local_state(dw_apis_allowed = TRUE, dwFunct = fd)
	d <- cso_toolkit_diff(toolkit_source = up, verbose = FALSE)
	expect_identical(attr(d, "target_version"), "v0.10.0")  # not v0.2.0, not the -rc1
	expect_identical(.cso_latest_version_tag(c("v1.2.0", "v1.10.0", "v2.0.0-rc1", "x")), "v1.10.0")
	expect_null(.cso_latest_version_tag(c("v2.0.0-rc1", "latest")))
})

test_that("diff: GitHub needs producer mode; a local clone works for reviewers", {
	up <- fake_upstream()
	fd <- fake_consumer(up)
	local_state(dw_apis_allowed = FALSE, dwFunct = fd)
	withr::local_envvar(CSO_TOOLKIT_ROOT = "")
	err <- tryCatch(cso_toolkit_diff("v0.2.0", verbose = FALSE), error = identity)
	expect_envelope(err, "cso_toolkit_diff")
	expect_match(conditionMessage(err), "reviewer mode")
	d <- cso_toolkit_diff("v0.2.0", toolkit_source = up, verbose = FALSE)
	expect_identical(nrow(d), 7L)
	# CSO_TOOLKIT_ROOT works like toolkit_source.
	withr::local_envvar(CSO_TOOLKIT_ROOT = up)
	expect_identical(nrow(cso_toolkit_diff("v0.2.0", verbose = FALSE)), 7L)
})

test_that("a vendored file that is neither .R nor .py stops with an envelope", {
	up <- fake_upstream()
	fd <- fake_consumer(up)
	m <- sub("  - p.py\n", "  - p.py\n  - notes.txt\n", paste(mf(fd), collapse = "\n"), fixed = TRUE)
	writeLines(strsplit(m, "\n")[[1]], file.path(fd, ".toolkit_manifest.yml"))
	local_state(dw_apis_allowed = TRUE, dwFunct = fd)
	err <- tryCatch(cso_toolkit_diff("v0.2.0", toolkit_source = up, verbose = FALSE), error = identity)
	expect_envelope(err, "cso_toolkit_diff")
	expect_match(conditionMessage(err), "notes.txt")
})

test_that("dry_run writes nothing and says what it would do", {
	up <- fake_upstream()
	fd <- fake_consumer(up)
	local_state(dw_apis_allowed = TRUE, dwFunct = fd)
	before <- lapply(list.files(fd, all.files = TRUE, no.. = TRUE, full.names = TRUE), rbytes)
	expect_warning(res <- cso_toolkit_pull("v0.2.0", dry_run = TRUE, toolkit_source = up, verbose = FALSE),
	                      "gone.R")
	after <- lapply(list.files(fd, all.files = TRUE, no.. = TRUE, full.names = TRUE), rbytes)
	expect_identical(after, before)
	act <- stats::setNames(res$action, res$file)
	expect_identical(act[["a.R"]], "would_update")
	expect_identical(act[["m.R"]], "would_add")
	expect_identical(act[["b.R"]], "skipped_local_edit")
	expect_identical(act[["gone.R"]], "kept")
})

test_that("pull writes the tag's bytes and re-pins the manifest in place (pulled_date)", {
	up <- fake_upstream()
	fd <- fake_consumer(up)
	local_state(dw_apis_allowed = TRUE, dwFunct = fd)
	old <- mf(fd)
	expect_warning(res <- cso_toolkit_pull("v0.2.0", confirm = FALSE, toolkit_source = up, verbose = FALSE),
	                      "Not in cso-toolkit v0.2.0, kept as vendored: gone.R")
	for (f in c("a.R", "m.R")) expect_identical(rbytes(file.path(fd, f)), tag_blob(up, "v0.2.0", paste0("r/R/", f)))
	expect_identical(rbytes(file.path(fd, "p.py")), tag_blob(up, "v0.2.0", "python/src/p.py"))
	expect_identical(rbytes(file.path(fd, "b.R")), charToRaw("# b at v0.1.0, edited here\n"))
	expect_identical(rbytes(file.path(fd, "e.R")), charToRaw("# e at v0.1.0\n"))
	expect_true(file.exists(file.path(fd, "gone.R")))
	act <- stats::setNames(res$action, res$file)
	expect_identical(unname(act[c("a.R", "m.R", "p.py", "b.R", "e.R", "c.R", "gone.R")]),
	                 c("updated", "added", "updated", "skipped_local_edit", "skipped_local_edit", "none", "kept"))
	expect_false(any(file.exists(list.files(fd, pattern = "cso_tmp$", all.files = TRUE))))

	new <- mf(fd)
	sha <- up_git(up, "rev-list", "-n", "1", "v0.2.0")
	expect_identical(new[3], "pulled_version: \"v0.2.0\"   # the pin")   # comment kept
	expect_identical(new[4], sprintf("pulled_commit: \"%s\"", sha))      # added after it
	expect_identical(new[5], sprintf("pulled_date: \"%s\"", format(Sys.Date(), "%Y-%m-%d")))
	expect_identical(new[6], sprintf("pulled_by: \"%s\"", .cso_user()))
	# Everything else is untouched, line for line.
	expect_identical(new[-(3:6)], old[-(3:5)])
	m <- yaml::read_yaml(file.path(fd, ".toolkit_manifest.yml"))
	expect_identical(m$custom_key, "keep me")
	expect_identical(unlist(m$local_edits), "e.R")
	expect_null(m$target_version)
})

test_that("pull keeps a pulled_at key and updates an existing files: block", {
	up <- fake_upstream()
	h010 <- digest::digest(charToRaw("# a at v0.1.0\n"), algo = "sha256", serialize = FALSE)
	fd <- fake_consumer(up, date = "pulled_at: \"2026-01-02\"\npulled_commit: \"0000000000000000000000000000000000000000\"",
	                    extra = sprintf("\nfiles:\n  a.R    : \"%s\"\n  c.R    : \"%s\"\n", h010, h010))
	local_state(dw_apis_allowed = TRUE, dwFunct = fd)
	suppressWarnings(cso_toolkit_pull("v0.2.0", confirm = FALSE, toolkit_source = up, verbose = FALSE))
	new <- mf(fd)
	expect_identical(new[4], sprintf("pulled_at: \"%s\"", format(Sys.Date(), "%Y-%m-%d")))
	expect_identical(new[5], sprintf("pulled_commit: \"%s\"", up_git(up, "rev-list", "-n", "1", "v0.2.0")))
	expect_false(any(grepl("^pulled_date:", new)))
	ha <- digest::digest(rbytes(file.path(fd, "a.R")), algo = "sha256", serialize = FALSE)
	hc <- digest::digest(rbytes(file.path(fd, "c.R")), algo = "sha256", serialize = FALSE)
	expect_true(sprintf("  a.R    : \"%s\"", ha) %in% new)
	expect_true(sprintf("  c.R    : \"%s\"", hc) %in% new)
})

test_that("uncommitted changes in 00_functions/ stop the pull", {
	up <- fake_upstream()
	fd <- fake_consumer(up)
	local_state(dw_apis_allowed = TRUE, dwFunct = fd)
	put(fd, "c.R", "# c, uncommitted edit\n")
	err <- tryCatch(cso_toolkit_pull("v0.2.0", confirm = FALSE, toolkit_source = up, verbose = FALSE),
	                error = identity)
	expect_envelope(err, "cso_toolkit_pull")
	expect_match(conditionMessage(err), "uncommitted changes")
	expect_identical(rbytes(file.path(fd, "a.R")), charToRaw("# a at v0.1.0\n"))
})

test_that("a downgrade is refused unless allow_downgrade = TRUE", {
	up <- fake_upstream()
	fd <- fake_consumer(up)
	local_state(dw_apis_allowed = TRUE, dwFunct = fd)
	suppressWarnings(cso_toolkit_pull("v0.10.0", confirm = FALSE, toolkit_source = up, verbose = FALSE))
	up_git(dirname(fd), "add", "-A")
	up_git(dirname(fd), "commit", "--quiet", "-m", "v0.10.0")
	err <- tryCatch(cso_toolkit_pull("v0.2.0", confirm = FALSE, toolkit_source = up, verbose = FALSE),
	                error = identity)
	expect_envelope(err, "cso_toolkit_pull")
	expect_match(conditionMessage(err), "allow_downgrade = TRUE")
	suppressWarnings(cso_toolkit_pull("v0.2.0", confirm = FALSE, toolkit_source = up,
	                                  allow_downgrade = TRUE, verbose = FALSE))
	expect_identical(rbytes(file.path(fd, "a.R")), charToRaw("# a at v0.2.0\n"))
	expect_true("pulled_version: \"v0.2.0\"   # the pin" %in% mf(fd))
})

test_that("the same tag reports 'already at' and warns when the tag moved", {
	up <- fake_upstream()
	fd <- fake_consumer(up, date = "pulled_date: \"2026-01-02\"\npulled_commit: \"1111111111111111111111111111111111111111\"")
	local_state(dw_apis_allowed = TRUE, dwFunct = fd)
	old <- mf(fd)
	expect_warning(
		expect_message(res <- cso_toolkit_pull("v0.1.0", confirm = FALSE, toolkit_source = up),
		               "already at v0.1.0"),
		"now points to")
	expect_true(all(res$action %in% c("none", "skipped_local_edit", "kept")))
	expect_identical(mf(fd), old)
})

test_that("a tag the clone lacks stops with git fetch --tags in the Fix", {
	up <- fake_upstream()
	fd <- fake_consumer(up)
	local_state(dw_apis_allowed = TRUE, dwFunct = fd)
	err <- tryCatch(cso_toolkit_pull("v9.9.9", confirm = FALSE, toolkit_source = up, verbose = FALSE),
	                error = identity)
	expect_envelope(err, "cso_toolkit_pull")
	expect_match(conditionMessage(err), "Tag v9.9.9 does not exist")
	expect_match(conditionMessage(err), "fetch --tags", fixed = TRUE)
})

test_that("reviewer mode refuses pull and sync, even with a local clone", {
	up <- fake_upstream()
	fd <- fake_consumer(up)
	local_state(dw_apis_allowed = FALSE, dwFunct = fd)
	for (f in list(list("cso_toolkit_pull", function() cso_toolkit_pull("v0.2.0", toolkit_source = up)),
	               list("cso_toolkit_sync", function() cso_toolkit_sync(toolkit_source = up)))) {
		err <- tryCatch(f[[2]](), error = identity)
		expect_envelope(err, f[[1]])
		expect_match(conditionMessage(err), "reviewer mode")
	}
})

test_that("confirm = TRUE in a non-interactive session stops before writing", {
	up <- fake_upstream()
	fd <- fake_consumer(up)
	local_state(dw_apis_allowed = TRUE, dwFunct = fd)
	err <- tryCatch(cso_toolkit_pull("v0.2.0", toolkit_source = up, verbose = FALSE), error = identity)
	expect_envelope(err, "cso_toolkit_pull")
	expect_match(conditionMessage(err), "confirm = FALSE", fixed = TRUE)
	expect_identical(rbytes(file.path(fd, "a.R")), charToRaw("# a at v0.1.0\n"))
	expect_true("pulled_version: \"v0.1.0\"   # the pin" %in% mf(fd))
})

test_that("confirm = TRUE asks per file: show diff, overwrite, skip", {
	up <- fake_upstream()
	fd <- fake_consumer(up)
	local_state(dw_apis_allowed = TRUE, dwFunct = fd)
	answers <- c("d", "o", "s", "o")        # a.R: diff then overwrite; m.R: skip; p.py: overwrite
	asked <- character(0)
	local_mocked_bindings(
		.cso_interactive = function() TRUE,
		.cso_ask = function(prompt) {
			asked <<- c(asked, prompt)
			a <- answers[1]; answers <<- answers[-1]; a
		})
	msgs <- character(0)
	res <- withCallingHandlers(
		suppressWarnings(cso_toolkit_pull("v0.2.0", toolkit_source = up, verbose = TRUE)),
		message = function(m) { msgs <<- c(msgs, conditionMessage(m)); invokeRestart("muffleMessage") })
	expect_length(asked, 4)
	expect_match(asked[1], "a.R changed upstream (v0.1.0 -> v0.2.0)", fixed = TRUE)
	expect_true(any(grepl("+# a at v0.2.0", msgs, fixed = TRUE)))     # the diff was shown
	act <- stats::setNames(res$action, res$file)
	expect_identical(unname(act[c("a.R", "m.R", "p.py")]), c("updated", "skipped", "updated"))
	expect_false(file.exists(file.path(fd, "m.R")))
	expect_true(any(grepl("next: read NEWS, run tools/check.R and the tests, commit 00_functions/ in one commit", msgs, fixed = TRUE)))
})

test_that("sync: up to date says so and writes nothing", {
	up <- fake_upstream()
	fd <- fake_consumer(up)
	local_state(dw_apis_allowed = TRUE, dwFunct = fd)
	suppressWarnings(cso_toolkit_pull("v0.10.0", confirm = FALSE, toolkit_source = up, verbose = FALSE))
	old <- mf(fd)
	expect_message(res <- cso_toolkit_sync(toolkit_source = up), "up to date: vendored v0.10.0, latest release v0.10.0")
	expect_null(res)
	expect_identical(mf(fd), old)
})

test_that("sync prints the NEWS sections between the versions, flagging Breaking/Changed", {
	up <- fake_upstream()
	fd <- fake_consumer(up)
	local_state(dw_apis_allowed = TRUE, dwFunct = fd)
	msgs <- character(0)
	res <- withCallingHandlers(
		suppressWarnings(cso_toolkit_sync(dry_run = TRUE, toolkit_source = up)),
		message = function(m) { msgs <<- c(msgs, conditionMessage(m)); invokeRestart("muffleMessage") })
	out <- paste(msgs, collapse = "\n")
	expect_match(out, "release notes v0.1.0 -> v0.10.0", fixed = TRUE)
	news <- attr(res, "news")
	expect_true(any(grepl("## v0.10.0", news)) && any(grepl("## v0.2.0", news)))
	expect_false(any(grepl("## v0.1.0", news)) || any(grepl("Unreleased", news)))
	expect_true("!! ### Breaking" %in% news)
	expect_true("!! - b.R drops an argument" %in% news)
	expect_true("!! ### Changed" %in% news)
	expect_true("   ### Fixed" %in% news)
	expect_match(out, "flagged:\n   v0.10.0: ### Breaking\n   v0.2.0: ### Changed", fixed = TRUE)
	expect_identical(res$action[res$file == "a.R"], "would_update")
	expect_identical(attr(res, "target_version"), "v0.10.0")
	# Between two releases only the later section.
	nw <- .cso_news_between(NEWS_0100, "v0.2.0", "v0.10.0")$lines
	expect_false(any(grepl("## v0.2.0", nw)))
})

test_that("the GitHub path (shallow clone over a URL) reads the same bytes", {
	up <- fake_upstream()
	fd <- fake_consumer(up)
	local_state(dw_apis_allowed = TRUE, dwFunct = fd)
	withr::local_envvar(CSO_TOOLKIT_ROOT = "")
	url <- paste0("file:///", sub("^/", "", normalizePath(up, winslash = "/")))
	local_mocked_bindings(.cso_remote_url = function(source_repo) url,
	                      .cso_upstream_latest_tag = function(source_repo) .cso_ls_remote_latest(source_repo))
	expect_identical(.cso_ls_remote_latest("unicef-drp/cso-toolkit"), "v0.10.0")
	d <- cso_toolkit_diff("v0.2.0", verbose = FALSE)
	expect_identical(d$status, cso_toolkit_diff("v0.2.0", toolkit_source = up, verbose = FALSE)$status)
	suppressWarnings(cso_toolkit_pull("v0.2.0", confirm = FALSE, verbose = FALSE))
	expect_identical(rbytes(file.path(fd, "a.R")), tag_blob(up, "v0.2.0", "r/R/a.R"))
	err <- tryCatch(cso_toolkit_diff("v9.9.9", verbose = FALSE), error = identity)
	expect_envelope(err, "cso_toolkit_diff")
	expect_match(conditionMessage(err), "Could not read tag v9.9.9")
	# The temporary clones are gone.
	expect_length(list.files(tempdir(), pattern = "^cso_upstream_"), 0)
})

test_that("the real repository at v0.9.1 (network; dry run)", {
	skip_on_cran()
	skip_if(!nzchar(Sys.which("git")), "git not installed")
	skip_if(is.null(.cso_ls_remote_latest("unicef-drp/cso-toolkit")), "GitHub not reachable")
	d <- tempfile("consumer_net_")
	withr::defer(unlink(d, recursive = TRUE, force = TRUE))
	dir.create(d)
	writeLines(c('source: "unicef-drp/cso-toolkit"', 'pulled_version: "v0.9.0"',
	             "vendored:", "  - cso_toolkit_sync.R", "  - dw_io.R", "local_edits: []"),
	           file.path(d, ".toolkit_manifest.yml"))
	local_state(dw_apis_allowed = TRUE, dwFunct = d)
	withr::local_envvar(CSO_TOOLKIT_ROOT = "")
	res <- cso_toolkit_pull("v0.9.1", dry_run = TRUE, verbose = FALSE)
	expect_identical(res$status, c("missing_local", "missing_local"))
	expect_identical(res$action, c("would_add", "would_add"))
	expect_match(attr(res, "target_commit"), "^[0-9a-f]{40}$")
	expect_true(all(grepl("^[0-9a-f]{64}$", res$sha256_target)))
	expect_false(file.exists(file.path(d, "dw_io.R")))
})
