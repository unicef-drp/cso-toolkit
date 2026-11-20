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

# A minimal stand-in for a cso-toolkit clone: r/DESCRIPTION and r/R/*.R.
fake_clone <- function(files, .frame = parent.frame()) {
	d <- tempfile("clone_")
	withr::defer(unlink(d, recursive = TRUE, force = TRUE), envir = .frame)
	dir.create(file.path(d, "r", "R"), recursive = TRUE)
	writeLines(c("Package: csotoolkit", "Version: 9.8.7"), file.path(d, "r", "DESCRIPTION"))
	for (f in files) writeLines(sprintf("# stub %s", f), file.path(d, "r", "R", f))
	d
}

bytes <- function(f) readBin(f, "raw", n = file.info(f)$size)

RESEARCH_FILES <- c(
	".githooks/pre-push", ".gitignore", "00_functions/README.md", "CONTRIBUTING.md",
	"R/README.md", "README.md", "cso_project.yml", "data/README.md",
	"data/input_manifest.csv", "data/provenance/README.md", "docs/README.md",
	"output/README.md", "paper/README.md", "references/README.md",
	"tests/testthat.R", "tests/testthat/helper-project.R",
	"tests/testthat/test-project.R", "tools/check.R")

OFFICIAL_FILES <- c(
	".githooks/pre-push", ".gitignore", "00_documentation/README.md",
	"00_functions/README.md", "01_dw_prep/012_codes/README.md", "CONTRIBUTING.md",
	"README.md", "_config_template/user_config.yml", "cso_project.yml",
	"inputs/README.md", "inputs/input_manifest.csv", "releases/README.md",
	"tests/testthat.R", "tests/testthat/helper-project.R",
	"tests/testthat/test-project.R", "tools/check.R")

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
	expect_true('  OUTPUT_DIRS = "output outputs results wrk",' %in% ochk)
	expect_true('  AUDIT_PATHS = "R",' %in% rchk)
	expect_true('  AUDIT_PATHS = "01_dw_prep/012_codes",' %in% ochk)
	# Not vendored: the two checks that need 00_functions/ are left out.
	expect_true('  CHECKS      = "tracked-data large-files secret-scan sidecars tests",' %in% rchk)
	expect_true(any(grepl('^SOURCE_DIRS <- c\\("R/functions"\\)', readLines(file.path(r, "tests", "testthat.R")))))
	expect_true(any(grepl("^SOURCE_DIRS <- character\\(0\\)", readLines(file.path(o, "tests", "testthat.R")))))
	# Placeholders are all filled.
	for (f in list.files(c(r, o), recursive = TRUE, full.names = TRUE)) {
		expect_false(any(grepl("{{", readLines(f, warn = FALSE), fixed = TRUE)), info = f)
	}
	expect_true(any(grepl("data/input_manifest.csv", readLines(file.path(r, "tests", "testthat", "test-project.R")), fixed = TRUE)))
	expect_true(any(grepl("inputs/input_manifest.csv", readLines(file.path(o, "tests", "testthat", "test-project.R")), fixed = TRUE)))
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
	expect_length(grep("^\\.github/workflows/", res2$path), 3)
})

test_that("vendor = TRUE copies the helpers and writes the manifest", {
	k <- .CSO_PROJECT_KINDS$research$vendor
	clone <- fake_clone(k)
	root <- new_root()
	res <- create_research_project(root, collaboration = "single-producer", vendor = TRUE,
	                               toolkit_source = clone, verbose = FALSE)
	expect_true(all(file.path("00_functions", c(k, ".toolkit_manifest.yml")) %in% res$path))
	for (f in k) {
		expect_identical(bytes(file.path(root, "00_functions", f)),
		                 bytes(file.path(clone, "r", "R", f)))
	}
	m <- yaml::read_yaml(file.path(root, "00_functions", ".toolkit_manifest.yml"))
	expect_identical(m$source, "unicef-drp/cso-toolkit")
	expect_identical(m$pulled_version, "v9.8.7")
	expect_identical(unlist(m$vendored), k)
	expect_length(m$local_edits, 0)
	# Vendored: check.R keeps every default check.
	expect_true(.CSO_CHECKS_LINE %in% readLines(file.path(root, "tools", "check.R")))
})

test_that("a vendor list always includes what tools/check.R needs", {
	clone <- fake_clone(c(.CSO_VENDOR_REQUIRED, "dw_pop.R"))
	root <- new_root()
	create_official_stats_project(root, collaboration = "single-producer", vendor = "dw_pop.R",
	                              toolkit_source = clone, verbose = FALSE)
	m <- yaml::read_yaml(file.path(root, "00_functions", ".toolkit_manifest.yml"))
	expect_identical(unlist(m$vendored), c(.CSO_VENDOR_REQUIRED, "dw_pop.R"))
})

test_that("vendoring without a clone, or with missing files, stops before writing", {
	root <- new_root()
	expect_error(create_research_project(root, collaboration = "single-producer", vendor = TRUE,
	                                     toolkit_source = tempdir(), verbose = FALSE),
	             "No cso-toolkit clone")
	clone <- fake_clone("dw_io.R")
	expect_error(create_research_project(root, collaboration = "single-producer", vendor = TRUE,
	                                     toolkit_source = clone, verbose = FALSE),
	             "Not in .*cso_toolkit_sync.R")
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
