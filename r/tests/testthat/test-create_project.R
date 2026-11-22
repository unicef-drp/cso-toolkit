# create_research_project() / create_official_stats_project(): the files
# written, the refusal to replace existing files, overwrite, the workflows
# and vendor options, cso_project.yml, and that the shipped template copies
# (inst/templates/) match the repository's templates/.

scaffold_tpl <- function(...) system.file("templates", ..., package = "csotoolkit")

new_root <- function(.frame = parent.frame()) {
	d <- tempfile("scaffold_")
	withr::defer(unlink(d, recursive = TRUE, force = TRUE), envir = .frame)
	file.path(d, "proj")
}

bytes <- function(f) readBin(f, "raw", n = file.info(f)$size)

# git in a test clone, with a fixed identity and no line-ending conversion;
# stops on failure.
clone_git <- function(d, ...) {
	out <- suppressWarnings(system2("git", c("-C", shQuote(d), "-c", "user.name=test",
	                                         "-c", "user.email=test@example.org",
	                                         "-c", "core.autocrlf=false", ...),
	                                stdout = TRUE, stderr = TRUE))
	if ((attr(out, "status") %||% 0L) != 0L) stop(paste(out, collapse = "\n"))
	out
}

# The bytes a stub helper has at `tag` (LF, written with writeBin).
stub_bytes <- function(f, tag) charToRaw(sprintf("# stub %s at %s\n", f, tag))

write_stubs <- function(d, files, tag) {
	for (f in files) writeBin(stub_bytes(f, tag), file.path(d, "r", "R", f))
}

# A minimal stand-in for a cso-toolkit clone: a git repository holding
# r/DESCRIPTION and stub r/R/*.R files, committed and tagged `tag` (NULL:
# committed, not tagged).
fake_clone <- function(files, tag = "v9.8.7", .frame = parent.frame()) {
	skip_if(!nzchar(Sys.which("git")), "git not installed")
	d <- tempfile("clone_")
	withr::defer(unlink(d, recursive = TRUE, force = TRUE), envir = .frame)
	dir.create(file.path(d, "r", "R"), recursive = TRUE)
	writeBin(charToRaw("Package: csotoolkit\nVersion: 9.9.9\n"), file.path(d, "r", "DESCRIPTION"))
	write_stubs(d, files, if (is.null(tag)) "untagged" else tag)
	clone_git(d, "init", "--quiet")
	clone_git(d, "add", "--", "r")
	clone_git(d, "commit", "--quiet", "-m", "stubs")
	if (!is.null(tag)) clone_git(d, "tag", tag)
	d
}

RESEARCH_FILES <- c(
	".checks/README.md", ".gitattributes", ".githooks/pre-push", ".github/workflows/check-record.yml",
	".gitignore", "00_functions/README.md", "CONTRIBUTING.md",
	"R/README.md", "README.md", "cso_project.yml", "data/README.md",
	"data/input_manifest.csv", "data/provenance/README.md", "docs/README.md",
	"output/README.md", "paper/README.md", "profile_proj.R", "references/README.md",
	"tests/testthat.R", "tests/testthat/helper-project.R",
	"tests/testthat/test-project.R", "tools/check", "tools/check.R")

OFFICIAL_FILES <- c(
	".checks/README.md", ".gitattributes", ".githooks/pre-push", ".github/workflows/check-record.yml",
	".gitignore", "00_documentation/README.md",
	"00_functions/README.md", "01_dw_prep/README.md", "01_dw_prep/010_metadata/README.md",
	"01_dw_prep/011_rawdata/README.md", "01_dw_prep/012_codes/README.md", "CONTRIBUTING.md",
	"README.md", "_config_template/user_config.yml", "cso_project.yml",
	"inputs/README.md", "inputs/input_manifest.csv", "profile_proj.R", "releases/README.md",
	"tests/testthat.R", "tests/testthat/helper-project.R",
	"tests/testthat/test-project.R", "tools/check", "tools/check.R")

test_that("a research project gets exactly the documented files", {
	root <- new_root()
	res <- create_research_project(root, collaboration = "single-producer", verbose = FALSE)
	expect_s3_class(res, "data.frame")
	expect_identical(res$path, sort(RESEARCH_FILES, method = "radix"))
	expect_true(all(res$status == "written"))
	on_disk <- list.files(root, recursive = TRUE, all.files = TRUE)
	expect_setequal(on_disk, RESEARCH_FILES)
})

test_that("an official-statistics project gets exactly the documented files", {
	root <- new_root()
	res <- create_official_stats_project(root, collaboration = "single-producer", verbose = FALSE)
	expect_identical(res$path, sort(OFFICIAL_FILES, method = "radix"))
	expect_setequal(list.files(root, recursive = TRUE, all.files = TRUE), OFFICIAL_FILES)
})

test_that(".gitignore, the hook and the test helper are the template bytes", {
	root <- new_root()
	create_research_project(root, collaboration = "single-producer", verbose = FALSE)
	expect_identical(bytes(file.path(root, ".gitignore")),
	                 bytes(scaffold_tpl("gitignore", "research-project.gitignore")))
	expect_identical(bytes(file.path(root, ".githooks", "pre-push")),
	                 bytes(scaffold_tpl("hooks", "pre-push")))
	expect_identical(bytes(file.path(root, ".gitattributes")),
	                 bytes(scaffold_tpl("gitattributes", "project.gitattributes")))
	# The hook and the vendored helpers stay LF in every clone.
	ga <- readLines(file.path(root, ".gitattributes"))
	expect_true(all(c(".githooks/**        text eol=lf", "00_functions/**     text eol=lf") %in% ga))
	# Tracked outputs keep their committed bytes, so they match their sidecars (#178).
	expect_true("output/**           -text" %in% ga)
	expect_false(as.raw(13) %in% bytes(file.path(root, ".githooks", "pre-push")))
	expect_identical(bytes(file.path(root, "tests", "testthat", "helper-project.R")),
	                 bytes(scaffold_tpl("testthat", "tests", "testthat", "helper-project.R")))

	root2 <- new_root()
	create_official_stats_project(root2, collaboration = "single-producer", verbose = FALSE)
	expect_identical(bytes(file.path(root2, ".gitignore")),
	                 bytes(scaffold_tpl("gitignore", "official-stats.gitignore")))
})

test_that("tools/check.R and tests/testthat.R carry the per-kind settings", {
	r <- new_root()
	create_research_project(r, collaboration = "single-producer", verbose = FALSE)
	o <- new_root()
	create_official_stats_project(o, collaboration = "single-producer", verbose = FALSE)
	rchk <- readLines(file.path(r, "tools", "check.R"))
	ochk <- readLines(file.path(o, "tools", "check.R"))
	expect_true('  OUTPUT_DIRS = "",' %in% rchk)
	expect_true('  OUTPUT_DIRS = "output outputs results wrk 013_wrkdata",' %in% ochk)
	expect_true(.CSO_DATA_DIRS_LINE %in% rchk)
	expect_true('  DATA_DIRS   = "data inputs _apis _frozen 011_rawdata",' %in% ochk)
	expect_true('  AUDIT_PATHS = "R",' %in% rchk)
	expect_true('  AUDIT_PATHS = "01_dw_prep/012_codes",' %in% ochk)
	# The contract audit reports in a research project, blocks in official stats.
	expect_true('  AUDIT_MODE  = "advisory",' %in% rchk)
	expect_true('  AUDIT_MODE  = "blocking",' %in% ochk)
	expect_true(.CSO_AUDIT_MODE_LINE %in% readLines(scaffold_tpl("tools", "check.R")))
	# Not vendored: the two checks that need 00_functions/ are left out.
	expect_true('  CHECKS      = "tracked-data large-files secret-scan sidecars tests",' %in% rchk)
	expect_true(any(grepl('^SOURCE_DIRS <- c\\("R/functions"\\)', readLines(file.path(r, "tests", "testthat.R")))))
	expect_true(any(grepl("^SOURCE_DIRS <- character\\(0\\)", readLines(file.path(o, "tests", "testthat.R")))))
	# Placeholders are all filled.
	for (f in list.files(c(r, o), recursive = TRUE, full.names = TRUE)) {
		# an unfilled {{name}} placeholder (a workflow's ${{ expr }} is GitHub's)
		expect_false(any(grepl("(^|[^$])\\{\\{[a-z_]+\\}\\}", readLines(f, warn = FALSE))), info = f)
	}
	expect_true(any(grepl("data/input_manifest.csv", readLines(file.path(r, "tests", "testthat", "test-project.R")), fixed = TRUE)))
	expect_true(any(grepl("inputs/input_manifest.csv", readLines(file.path(o, "tests", "testthat", "test-project.R")), fixed = TRUE)))
})

test_that("AUDIT_MODE: a violation warns in a research project, fails in official stats", {
	skip_if(!nzchar(Sys.which("git")), "git not installed")
	rscript <- file.path(R.home("bin"), if (.Platform$OS.type == "windows") "Rscript.exe" else "Rscript")
	run_audit <- function(create, code_dir, env = character()) {
		root <- new_root(.frame = parent.frame())
		create(root, collaboration = "single-producer", git = TRUE, verbose = FALSE)
		# Stand-ins for the vendored helpers: an auditor that always finds
		# one violation.
		td <- file.path(root, "00_functions")
		writeLines("# dw_io stand-in", file.path(td, "dw_io.R"))
		writeLines(c("test_scripts <- function(path, ...) {",
		             "  data.frame(file = file.path(path, 'a.R'), line = 1L, rule = 'io-read-csv')",
		             "}"), file.path(td, "test_scripts.R"))
		dir.create(file.path(root, code_dir), recursive = TRUE, showWarnings = FALSE)
		out <- withr::with_dir(root, withr::with_envvar(env, suppressWarnings(
			system2(rscript, c("--no-init-file", "tools/check.R", "--only", "contract-audit"),
			        stdout = TRUE, stderr = TRUE))))
		list(status = attr(out, "status") %||% 0L, out = out)
	}
	r <- run_audit(create_research_project, "R")
	expect_identical(r$status, 0L)
	expect_true(any(grepl("^\\[WARN\\] contract-audit", r$out)))
	expect_true(any(grepl("AUDIT_MODE = \"advisory\"", r$out, fixed = TRUE)))
	o <- run_audit(create_official_stats_project, "01_dw_prep/012_codes")
	expect_identical(o$status, 1L)
	expect_true(any(grepl("^\\[FAIL\\] contract-audit", o$out)))
	# The environment variable of the same name overrides the file.
	r2 <- run_audit(create_research_project, "R", c(AUDIT_MODE = "blocking"))
	expect_identical(r2$status, 1L)
	bad <- run_audit(create_research_project, "R", c(AUDIT_MODE = "strict"))
	expect_identical(bad$status, 1L)
	expect_true(any(grepl("AUDIT_MODE is \"strict\"", bad$out, fixed = TRUE)))
})

test_that("official stats: the deposit stages are ignored, their sidecars kept", {
	skip_if(!nzchar(Sys.which("git")), "git not installed")
	root <- new_root()
	create_official_stats_project(root, collaboration = "single-producer", git = TRUE, verbose = FALSE)
	ignored <- function(path) {
		st <- attr(suppressWarnings(system2("git", c("-C", shQuote(root), "check-ignore", "-q", "--no-index", path),
		                                    stdout = TRUE, stderr = TRUE)), "status") %||% 0L
		identical(as.integer(st), 0L)
	}
	# Work data and outputs: embargoed, sidecars included.
	expect_true(ignored("01_dw_prep/013_wrkdata/nt/dw_nt.csv"))
	expect_true(ignored("01_dw_prep/013_wrkdata/nt/dw_nt.csv.provenance.json"))
	expect_true(ignored("01_dw_prep/013_wrkdata/README.md"))
	# Raw data: ignored; READMEs, sidecars and manifests are kept.
	expect_true(ignored("01_dw_prep/011_rawdata/nt/input/survey.csv"))
	expect_true(ignored("01_dw_prep/011_rawdata/_apis/uis/abc.json"))
	expect_false(ignored("01_dw_prep/011_rawdata/nt/input/survey.csv.provenance.json"))
	expect_false(ignored("01_dw_prep/011_rawdata/README.md"))
	expect_false(ignored("01_dw_prep/011_rawdata/nt/.gitkeep"))
	# Code and metadata are tracked.
	expect_false(ignored("01_dw_prep/012_codes/nt/00_run_nt.R"))
	expect_false(ignored("01_dw_prep/010_metadata/region_codes.csv"))
	# Every file the scaffolder wrote can be committed.
	for (f in list.files(root, recursive = TRUE, all.files = TRUE)) {
		if (startsWith(f, ".git/")) next
		expect_false(ignored(f), info = f)
	}
})

test_that("both kinds get profile_<project>.R, and review_profile() passes it", {
	r <- new_root()
	create_research_project(r, collaboration = "multi-producer", verbose = FALSE)
	o <- new_root()
	create_official_stats_project(o, collaboration = "single-producer", verbose = FALSE)
	for (root in c(r, o)) {
		p <- file.path(root, "profile_proj.R")
		expect_true(file.exists(p))
		expect_silent(parse(p))
		src <- readLines(p)
		expect_true("profile_proj <- TRUE" %in% src)
		expect_true('repo_name <- "proj"' %in% src)
		expect_false("install.packages" %in% all.names(parse(p)))
		rev <- review_profile(p, verbose = FALSE)
		expect_false(any(rev$status == "fail"), info = paste(rev$check[rev$status == "fail"], collapse = ", "))
		expect_identical(rev$status[rev$check == "User block in user_config.yml"], "pass")
		expect_identical(rev$status[rev$check == "Collaboration model block"], "pass")
	}
	# Official statistics add the deposit paths and the Z: check.
	ro <- review_profile(file.path(o, "profile_proj.R"), require_z_drive_check = TRUE, verbose = FALSE)
	expect_false(any(ro$status == "fail"))
	osrc <- readLines(file.path(o, "profile_proj.R"))
	rsrc <- readLines(file.path(r, "profile_proj.R"))
	expect_true(any(grepl("^teamsWrkData <- ", trimws(osrc))))
	expect_false(any(grepl("teamsWrkData|dw_z_available", rsrc)))
	# A folder name that is not a valid R name still gives a valid sentinel.
	d <- tempfile("scaffold_")
	withr::defer(unlink(d, recursive = TRUE, force = TRUE))
	create_research_project(file.path(d, "my-paper.v2"), collaboration = "single-producer", verbose = FALSE)
	expect_true("profile_my_paper_v2 <- TRUE" %in% readLines(file.path(d, "my-paper.v2", "profile_my-paper.v2.R")))
})

test_that("the generated profiles load against a user-block user_config.yml", {
	skip_if_not_installed("yaml")
	rscript <- file.path(R.home("bin"), if (.Platform$OS.type == "windows") "Rscript.exe" else "Rscript")
	home <- withr::local_tempdir()
	dir.create(file.path(home, ".config"))
	cfg <- file.path(home, ".config", "user_config.yml")
	load_profile <- function(root, config) {
		writeLines(config, cfg)
		code <- "source('profile_proj.R'); cat('MODE=', dw_mode, ' WRK=', if (exists('teamsWrkData')) teamsWrkData else '-', '\\n', sep = '')"
		out <- withr::with_dir(root, withr::with_envvar(
			c(USERNAME = "tester", USER = "tester", USERPROFILE = normalizePath(home, winslash = "/")),
			suppressWarnings(system2(rscript, c("--no-init-file", "-e", shQuote(code)),
			                         stdout = TRUE, stderr = TRUE))))
		list(status = attr(out, "status") %||% 0L, out = paste(out, collapse = "\n"))
	}
	r <- new_root()
	create_research_project(r, collaboration = "single-producer", verbose = FALSE)
	res <- load_profile(r, c("tester:", '  dw_mode: "reviewer"'))
	expect_identical(res$status, 0L, info = res$out)
	expect_match(res$out, "MODE=reviewer WRK=-")
	expect_match(res$out, "profile_proj.R loaded: user tester, dw_mode reviewer, single-producer", fixed = TRUE)
	res <- load_profile(r, c("tester:", '  dw_mode: "reviewer"', "  dw_mode_by_project:", '    proj: "producer"'))
	expect_match(res$out, "MODE=producer")
	res <- load_profile(r, c("someone_else:", '  dw_mode: "reviewer"'))
	expect_false(identical(res$status, 0L))
	expect_match(res$out, 'tester:\n        dw_mode: "reviewer"', fixed = TRUE)

	o <- new_root()
	create_official_stats_project(o, collaboration = "single-producer", verbose = FALSE)
	# Forward slashes: a backslash inside a double-quoted YAML scalar is an escape.
	fwd <- function(p) gsub("\\", "/", p, fixed = TRUE)
	sandbox <- fwd(file.path(home, "dw-repro"))
	teams <- fwd(file.path(home, "teams"))
	no_mirror <- fwd(file.path(home, "no-mirror"))
	res <- load_profile(o, c("tester:", '  dw_mode: "reviewer"',
	                         sprintf('  teamsRoot: "%s"', teams), sprintf('  sandboxRoot: "%s"', sandbox),
	                         sprintf('  zDrive: "%s"', no_mirror)))
	expect_identical(res$status, 0L, info = res$out)
	expect_match(res$out, sprintf("MODE=reviewer WRK=%s/01_dw_prep/013_wrkdata", sandbox), fixed = TRUE)
	expect_true(dir.exists(file.path(sandbox, "01_dw_prep", "013_wrkdata")))
	expect_match(res$out, "not available -- non-blocking", fixed = TRUE)
	# zDrive points at a folder, never at a drive letter: probing a mapped but
	# unreachable Z: leaves a hung `vol` process behind on the test machine.
	res <- load_profile(o, c("tester:", '  dw_mode: "producer"', sprintf('  teamsRoot: "%s"', teams),
	                         sprintf('  zDrive: "%s"', no_mirror)))
	expect_identical(res$status, 0L, info = res$out)
	expect_match(res$out, sprintf("MODE=producer WRK=%s/060.DW-MASTER/01_dw_prep/013_wrkdata", teams), fixed = TRUE)
	res <- load_profile(o, c("tester:", '  dw_mode: "reviewer"', sprintf('  teamsRoot: "%s"', teams)))
	expect_false(identical(res$status, 0L))
	expect_match(res$out, "reviewer mode needs a sandboxRoot for tester", fixed = TRUE)
})

test_that("cso_project.yml records the collaboration model, date and members", {
	root <- new_root()
	create_research_project(root, collaboration = "multi-producer",
	                        members = c("jpazvd", "kbarnes"), verbose = FALSE)
	p <- yaml::read_yaml(file.path(root, "cso_project.yml"))
	expect_identical(p$schema, "cso_project/1")
	expect_identical(p$collaboration, "multi-producer")
	expect_identical(as.character(p$collaboration_since), format(Sys.Date(), "%Y-%m-%d"))
	expect_identical(unlist(p$members), c("jpazvd", "kbarnes"))
	# The toolkit's own reader accepts it (it caches the model: restore after).
	local_state(dw_collaboration_model = NULL, dw_project_file = NULL)
	expect_identical(dw_collaboration(root = root, verbose = FALSE), "multi-producer")

	root2 <- new_root()
	create_research_project(root2, collaboration = "single-producer", verbose = FALSE)
	p2 <- yaml::read_yaml(file.path(root2, "cso_project.yml"))
	expect_identical(p2$collaboration, "single-producer")
	expect_null(p2$members)
})

test_that("collaboration is required and validated; members must be plain handles", {
	root <- new_root()
	expect_envelope(tryCatch(create_research_project(root), error = identity),
	                "create_research_project")
	expect_error(create_official_stats_project(root, collaboration = "co-producer"),
	             "\\[cso_toolkit\\.create_official_stats_project\\].*no default")
	expect_error(create_research_project(root, collaboration = "single-producer",
	                                     members = "a b: c"), "plain YAML")
	expect_false(dir.exists(root))
})

test_that("existing files are never replaced silently; identical ones are left alone", {
	root <- new_root()
	create_research_project(root, collaboration = "single-producer", verbose = FALSE)

	again <- create_research_project(root, collaboration = "single-producer", verbose = FALSE)
	expect_true(all(again$status == "unchanged"))

	writeLines("my own readme", file.path(root, "README.md"))
	writeLines("keep me", file.path(root, "data", "notes.txt"))
	expect_error(create_research_project(root, collaboration = "single-producer", verbose = FALSE),
	             "1 file\\(s\\) already exist.*README.md.*Nothing was written")
	expect_identical(readLines(file.path(root, "README.md")), "my own readme")

	res <- create_research_project(root, collaboration = "single-producer",
	                               overwrite = TRUE, verbose = FALSE)
	expect_identical(res$status[res$path == "README.md"], "overwritten")
	expect_true(all(res$status[res$path != "README.md"] == "unchanged"))
	expect_true(any(grepl("create_research_project", readLines(file.path(root, "README.md")))))
	expect_identical(readLines(file.path(root, "data", "notes.txt")), "keep me")
})

test_that("a conflict anywhere stops the whole run before any write", {
	root <- new_root()
	dir.create(file.path(root, "tools"), recursive = TRUE)
	writeLines("# my checks", file.path(root, "tools", "check.R"))
	expect_error(create_official_stats_project(root, collaboration = "single-producer", verbose = FALSE),
	             "tools/check.R")
	expect_identical(list.files(root, recursive = TRUE, all.files = TRUE), "tools/check.R")
})

test_that("workflows = TRUE adds the opt-in workflows, byte for byte", {
	root <- new_root()
	res <- create_research_project(root, collaboration = "single-producer",
	                               workflows = TRUE, verbose = FALSE)
	wf <- c("ci-contract-audit.yml", "ci-hygiene.yml", "ci-manuscript.yml", "ci-r-tests.yml")
	expect_true(all(file.path(".github/workflows", wf) %in% res$path))
	for (w in wf) {
		expect_identical(bytes(file.path(root, ".github", "workflows", w)),
		                 bytes(scaffold_tpl("workflows", w)))
		# Opt-in triggers: manual dispatch and pull requests into main only.
		y <- yaml::read_yaml(file.path(root, ".github", "workflows", w))
		on <- y[["on"]] %||% y[[which(names(y) == "TRUE")]]
		expect_setequal(names(on), c("workflow_dispatch", "pull_request"))
		expect_identical(unlist(on$pull_request$branches), "main")
	}
	root2 <- new_root()
	res2 <- create_official_stats_project(root2, collaboration = "single-producer",
	                                      workflows = TRUE, verbose = FALSE)
	expect_false(".github/workflows/ci-manuscript.yml" %in% res2$path)
	expect_length(grep("^\\.github/workflows/", res2$path), 4)          # 3 opt-in + check-record
})

test_that("vendor = TRUE copies the helpers of the latest tag and records it", {
	k <- .CSO_PROJECT_KINDS$research$vendor
	clone <- fake_clone(k)
	root <- new_root()
	res <- create_research_project(root, collaboration = "single-producer", vendor = TRUE,
	                               toolkit_source = clone, verbose = FALSE)
	expect_true(all(file.path("00_functions", c(k, ".toolkit_manifest.yml")) %in% res$path))
	for (f in k) {
		expect_identical(bytes(file.path(root, "00_functions", f)), stub_bytes(f, "v9.8.7"))
	}
	m <- yaml::read_yaml(file.path(root, "00_functions", ".toolkit_manifest.yml"))
	expect_identical(m$source, "unicef-drp/cso-toolkit")
	# The tag, not r/DESCRIPTION's version (9.9.9 here).
	expect_identical(m$pulled_version, "v9.8.7")
	expect_identical(m$pulled_commit, clone_git(clone, "rev-list", "-n", "1", "v9.8.7"))
	expect_identical(unlist(m$vendored), k)
	expect_length(m$local_edits, 0)
	# Vendored: check.R keeps every default check.
	expect_true(.CSO_CHECKS_LINE %in% readLines(file.path(root, "tools", "check.R")))
})

test_that("vendoring reads the tag, whatever the clone's branch and working tree", {
	k <- .CSO_PROJECT_KINDS$research$vendor
	clone <- fake_clone(k)
	# Another branch with a newer commit, then uncommitted edits on top.
	clone_git(clone, "checkout", "--quiet", "-b", "feature/other")
	write_stubs(clone, k, "feature/other")
	clone_git(clone, "commit", "--quiet", "-a", "-m", "newer")
	write_stubs(clone, k, "local edit")
	root <- new_root()
	create_research_project(root, collaboration = "single-producer", vendor = TRUE,
	                        toolkit_source = clone, toolkit_version = "v9.8.7", verbose = FALSE)
	for (f in k) {
		expect_identical(bytes(file.path(root, "00_functions", f)), stub_bytes(f, "v9.8.7"))
	}
	m <- yaml::read_yaml(file.path(root, "00_functions", ".toolkit_manifest.yml"))
	expect_identical(m$pulled_commit, clone_git(clone, "rev-list", "-n", "1", "v9.8.7"))
	expect_false(identical(m$pulled_commit, clone_git(clone, "rev-parse", "HEAD")))
})

test_that("toolkit_version picks the tag; the default is the latest release tag", {
	k <- .CSO_VENDOR_REQUIRED
	clone <- fake_clone(k, tag = "v1.2.0")
	for (tag in c("v1.10.0", "v2.0.0-rc1")) {
		write_stubs(clone, k, tag)
		clone_git(clone, "commit", "--quiet", "-a", "-m", tag)
		clone_git(clone, "tag", tag)
	}
	pulled <- function(...) {
		root <- new_root(.frame = parent.frame())
		create_research_project(root, collaboration = "single-producer", vendor = k,
		                        toolkit_source = clone, verbose = FALSE, ...)
		m <- yaml::read_yaml(file.path(root, "00_functions", ".toolkit_manifest.yml"))
		list(version = m$pulled_version, bytes = bytes(file.path(root, "00_functions", "dw_io.R")))
	}
	# v1.10.0 sorts after v1.2.0 (version order), and the -rc1 tag is passed over.
	expect_identical(pulled()$version, "v1.10.0")
	expect_identical(pulled()$bytes, stub_bytes("dw_io.R", "v1.10.0"))
	p <- pulled(toolkit_version = "1.2.0")
	expect_identical(p$version, "v1.2.0")
	expect_identical(p$bytes, stub_bytes("dw_io.R", "v1.2.0"))
	expect_identical(pulled(toolkit_version = "v2.0.0-rc1")$version, "v2.0.0-rc1")
})

test_that("a tag that does not exist, or a clone without tags, stops before writing", {
	clone <- fake_clone(.CSO_VENDOR_REQUIRED)
	root <- new_root()
	err <- tryCatch(create_research_project(root, collaboration = "single-producer", vendor = TRUE,
	                                        toolkit_source = clone, toolkit_version = "v0.0.1",
	                                        verbose = FALSE), error = identity)
	expect_envelope(err, "create_research_project")
	expect_match(conditionMessage(err), "Tag v0.0.1 does not exist.*latest: v9.8.7")
	untagged <- fake_clone(.CSO_VENDOR_REQUIRED, tag = NULL)
	expect_error(create_research_project(root, collaboration = "single-producer", vendor = TRUE,
	                                     toolkit_source = untagged, verbose = FALSE),
	             "has no release tag")
	expect_false(dir.exists(root))
})

test_that("the default set skips helpers the tag lacks; a listed file must exist", {
	clone <- fake_clone(.CSO_VENDOR_REQUIRED)       # no dw_api.R, dw_project.R, ...
	root <- new_root()
	expect_message(
		create_research_project(root, collaboration = "single-producer", vendor = TRUE,
		                        toolkit_source = clone, verbose = TRUE),
		"not in v9.8.7, so not vendored: .*dw_project.R")
	m <- yaml::read_yaml(file.path(root, "00_functions", ".toolkit_manifest.yml"))
	expect_identical(unlist(m$vendored),
	                 intersect(.CSO_PROJECT_KINDS$research$vendor, .CSO_VENDOR_REQUIRED))

	root2 <- new_root()
	expect_error(create_research_project(root2, collaboration = "single-producer", vendor = "dw_pop.R",
	                                     toolkit_source = clone, verbose = FALSE),
	             "Not in r/R/ at v9.8.7.*dw_pop.R")
	clone2 <- fake_clone("dw_io.R")
	expect_error(create_research_project(root2, collaboration = "single-producer", vendor = TRUE,
	                                     toolkit_source = clone2, verbose = FALSE),
	             "Not in r/R/ at v9.8.7.*cso_toolkit_sync.R")
	expect_false(dir.exists(root2))
})

test_that("a vendor list always includes what tools/check.R needs", {
	clone <- fake_clone(c(.CSO_VENDOR_REQUIRED, "dw_pop.R"))
	root <- new_root()
	create_official_stats_project(root, collaboration = "single-producer", vendor = "dw_pop.R",
	                              toolkit_source = clone, verbose = FALSE)
	m <- yaml::read_yaml(file.path(root, "00_functions", ".toolkit_manifest.yml"))
	expect_identical(unlist(m$vendored), c(.CSO_VENDOR_REQUIRED, "dw_pop.R"))
})

test_that("vendoring without a git clone stops before writing", {
	root <- new_root()
	expect_error(create_research_project(root, collaboration = "single-producer", vendor = TRUE,
	                                     toolkit_source = tempdir(), verbose = FALSE),
	             "No cso-toolkit clone")
	# A copy of the files without git history is not enough.
	plain <- tempfile("plain_")
	withr::defer(unlink(plain, recursive = TRUE, force = TRUE))
	dir.create(file.path(plain, "r", "R"), recursive = TRUE)
	writeLines("Version: 1.0.0", file.path(plain, "r", "DESCRIPTION"))
	writeLines("# dw_io", file.path(plain, "r", "R", "dw_io.R"))
	expect_error(create_research_project(root, collaboration = "single-producer", vendor = TRUE,
	                                     toolkit_source = plain, verbose = FALSE),
	             "is not a git clone")
	expect_false(dir.exists(root))
})

test_that("git = TRUE initialises develop, sets the hook path and the hook's mode", {
	skip_if(!nzchar(Sys.which("git")), "git not installed")
	root <- new_root()
	create_research_project(root, collaboration = "single-producer", git = TRUE, verbose = FALSE)
	g <- function(...) system2("git", c("-C", shQuote(root), ...), stdout = TRUE, stderr = TRUE)
	expect_identical(g("symbolic-ref", "HEAD"), "refs/heads/develop")
	expect_identical(g("config", "core.hooksPath"), ".githooks")
	expect_match(g("ls-files", "-s", "--", ".githooks/pre-push"), "^100755 ")
	expect_match(g("ls-files", "-s", "--", "tools/check"), "^100755 ")
	# No commit is made.
	st <- attr(suppressWarnings(g("rev-parse", "--verify", "--quiet", "HEAD")), "status")
	expect_true(!is.null(st) && st != 0L)
})

test_that("the package's template copies match the repository's templates/", {
	src <- NULL
	dir <- normalizePath(getwd(), winslash = "/", mustWork = FALSE)
	for (i in seq_len(10)) {
		if (file.exists(file.path(dir, "templates", "project", "README.md")) &&
		    file.exists(file.path(dir, "tools", "sync_templates.py"))) {
			src <- file.path(dir, "templates")
			break
		}
		parent <- dirname(dir)
		if (identical(parent, dir)) break
		dir <- parent
	}
	if (is.null(src)) {
		skip_on_ci_or_fail <- if (nzchar(Sys.getenv("CI"))) fail else skip
		return(skip_on_ci_or_fail("repository templates/ not found from here (R CMD check runs outside the repository)"))
	}
	pkg <- scaffold_tpl()
	shipped <- list.files(pkg, recursive = TRUE, all.files = TRUE)
	expect_gt(length(shipped), 20)
	for (rel in shipped) {
		expect_true(file.exists(file.path(src, rel)), info = rel)
		expect_identical(bytes(file.path(pkg, rel)), bytes(file.path(src, rel)), info = rel)
	}
	expect_setequal(list.files(file.path(src, "project"), recursive = TRUE, all.files = TRUE),
	                list.files(file.path(pkg, "project"), recursive = TRUE, all.files = TRUE))
})
