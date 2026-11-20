# =============================================================================
# create_project -- scaffold a new research or official-statistics repository
# =============================================================================
#
#   create_research_project()        papers, analysis, replication packages
#   create_official_stats_project()  DW sector pipelines, SDMX /
#                                    data.unicef.org publication, survey
#                                    processing
#
# Both write the same kinds of file -- .gitignore, tools/check.R and the
# pre-push hook, a testthat suite, cso_project.yml, README / CONTRIBUTING
# skeletons, the data or inputs README and manifest -- from the templates
# the package ships in inst/templates/ (a byte-for-byte copy of the
# repository's templates/, kept in step by tools/sync_templates.py and a
# test). They differ in layout and in where results live: git for a
# research project, the deposit (embargoed until publication) for official
# statistics.
#
# Python sibling: python/src/create_project.py (same files, same bytes).
# Stata: not provided; run the R or Python function once per repository.
# Handbook: chapter "Starting a new repository".

.CSO_PROJECT_KINDS <- list(
	research = list(
		fn = "create_research_project",
		gitignore = "research-project.gitignore",
		input_manifest = "data/input_manifest.csv",
		source_dirs = 'SOURCE_DIRS <- c("R/functions")',
		workflows = c("ci-hygiene.yml", "ci-contract-audit.yml", "ci-r-tests.yml",
		              "ci-manuscript.yml"),
		vendor = c("dw_io.R", "dw_api.R", "cso_toolkit_sync.R", "dw_provenance.R",
		           "dw_deposit.R", "dw_project.R", "test_scripts.R", "zzz.R")
	),
	`official-stats` = list(
		fn = "create_official_stats_project",
		gitignore = "official-stats.gitignore",
		input_manifest = "inputs/input_manifest.csv",
		source_dirs = "SOURCE_DIRS <- character(0)",
		workflows = c("ci-hygiene.yml", "ci-contract-audit.yml", "ci-r-tests.yml"),
		vendor = c("dw_io.R", "dw_api.R", "cso_toolkit_sync.R", "dw_provenance.R",
		           "dw_deposit.R", "dw_project.R", "test_scripts.R", "zzz.R",
		           "profile_helpers.R", "create_sector_script.R")
	)
)

# tools/check.R needs these three in 00_functions/ (contract-audit, vintage).
.CSO_VENDOR_REQUIRED <- c("dw_io.R", "cso_toolkit_sync.R", "test_scripts.R")

# Exact lines of the shipped templates that the scaffolders edit. If a
# template changes one of them, the scaffolder stops instead of writing a
# file it did not mean to (the tests catch it first).
.CSO_CHECKS_LINE <- '  CHECKS      = "tracked-data large-files secret-scan sidecars contract-audit vintage tests",'
.CSO_CHECKS_UNVENDORED <- paste0(
	"  # contract-audit and vintage need the vendored toolkit in 00_functions/:\n",
	"  # add them back here once it is vendored (see 00_functions/README.md).\n",
	'  CHECKS      = "tracked-data large-files secret-scan sidecars tests",')
.CSO_OUTPUT_DIRS_LINE <- '  OUTPUT_DIRS = "",'
.CSO_AUDIT_PATHS_LINE <- '  AUDIT_PATHS = "R",'
.CSO_SOURCE_DIRS <- 'SOURCE_DIRS <- c("R")'
.CSO_MEMBERS_EXAMPLE <- "# members:\n#   - jpazevedo\n#   - kbarnes\n"

#' Read a file as raw bytes
#' @keywords internal
#' @noRd
.cso_bytes <- function(f) readBin(f, "raw", n = file.info(f)$size)

#' Replace an exact piece of a template, or stop if it is not there
#' @keywords internal
#' @noRd
.cso_edit <- function(bytes, old, new, what, fn) {
	s <- rawToChar(bytes)
	if (!grepl(old, s, fixed = TRUE, useBytes = TRUE)) {
		stop(sprintf(
			"[cso_toolkit.%s] The shipped template %s no longer contains the line this function edits:\n   %s\n Fix: update the package (or report it at https://github.com/unicef-drp/cso-toolkit/issues); the template and the scaffolder are out of step.",
			fn, what, old), call. = FALSE)
	}
	charToRaw(sub(old, new, s, fixed = TRUE, useBytes = TRUE))
}

#' Fill `{{name}}` placeholders
#' @keywords internal
#' @noRd
.cso_fill <- function(bytes, vars) {
	s <- rawToChar(bytes)
	for (k in names(vars)) {
		s <- gsub(paste0("{{", k, "}}"), vars[[k]], s, fixed = TRUE, useBytes = TRUE)
	}
	charToRaw(s)
}

#' Locate the templates: the installed package, else a toolkit clone
#' @keywords internal
#' @noRd
.cso_templates_dir <- function(toolkit_source, fn) {
	cands <- c(system.file("templates", package = "csotoolkit"),
	           if (!is.null(toolkit_source)) file.path(toolkit_source, "templates"))
	for (d in cands) {
		if (nzchar(d) && file.exists(file.path(d, "project", "common", "00_functions", "README.md"))) {
			return(d)
		}
	}
	stop(sprintf(
		"[cso_toolkit.%s] The project templates were not found.\n Why: they ship with the installed csotoolkit package (inst/templates/), and this session has neither the package nor a toolkit clone.\n Fix: install the package from a cso-toolkit clone (devtools::install(\"<clone>/r\")), or pass `toolkit_source = \"<clone>\"`.",
		fn), call. = FALSE)
}

#' Resolve the cso-toolkit clone to vendor helpers from
#' @keywords internal
#' @noRd
.cso_toolkit_source <- function(toolkit_source, fn) {
	src <- toolkit_source
	if (is.null(src) || !nzchar(src)) src <- Sys.getenv("CSO_TOOLKIT_ROOT")
	if (!nzchar(src)) {
		# A source checkout (devtools::load_all()): the package folder is
		# <clone>/r, and system.file() may point at it or at <clone>/r/inst.
		dir <- system.file(package = "csotoolkit")
		for (i in 1:3) {
			if (!nzchar(dir)) break
			dir <- dirname(dir)
			if (file.exists(file.path(dir, "r", "R", "dw_io.R"))) {
				src <- dir
				break
			}
		}
	}
	if (!nzchar(src) || !file.exists(file.path(src, "r", "R", "dw_io.R")) ||
	    !file.exists(file.path(src, "r", "DESCRIPTION"))) {
		stop(sprintf(
			"[cso_toolkit.%s] No cso-toolkit clone to vendor the helpers from%s.\n Why: vendoring copies the helper files from a clone's r/R/ folder; the installed package does not carry them as source.\n Fix: clone unicef-drp/cso-toolkit, check out a release tag, and pass `toolkit_source = \"<clone>\"` (or set CSO_TOOLKIT_ROOT); or pass `vendor = FALSE` and vendor by hand later.",
			fn, if (nzchar(src)) paste0(" (", src, " has no r/R/dw_io.R)") else ""),
		     call. = FALSE)
	}
	normalizePath(src, winslash = "/")
}

#' The user name recorded as `pulled_by`
#' @keywords internal
#' @noRd
.cso_user <- function() {
	u <- Sys.getenv("USERNAME")
	if (!nzchar(u)) u <- Sys.getenv("USER")
	if (!nzchar(u)) u <- "unknown"
	u
}

#' Build the named list of files (relative path -> raw bytes) for a project
#' @keywords internal
#' @noRd
.cso_project_files <- function(kind, project_name, title, collaboration, members,
                               vendor_files, src, tpl, workflows, fn) {
	k <- .CSO_PROJECT_KINDS[[kind]]
	today <- format(Sys.Date(), "%Y-%m-%d")
	vars <- list(project_name = project_name, title = title,
	             collaboration = collaboration, date = today,
	             input_manifest = k$input_manifest)
	files <- list()

	# Skeleton files: common/ then the kind's own folder (same path wins).
	for (layer in c("common", kind)) {
		base <- file.path(tpl, "project", layer)
		for (rel in list.files(base, recursive = TRUE, all.files = TRUE)) {
			files[[rel]] <- .cso_fill(.cso_bytes(file.path(base, rel)), vars)
		}
	}

	files[[".gitignore"]] <- .cso_bytes(file.path(tpl, "gitignore", k$gitignore))
	files[[".githooks/pre-push"]] <- .cso_bytes(file.path(tpl, "hooks", "pre-push"))

	chk <- .cso_bytes(file.path(tpl, "tools", "check.R"))
	if (kind == "official-stats") {
		chk <- .cso_edit(chk, .CSO_OUTPUT_DIRS_LINE, '  OUTPUT_DIRS = "output outputs results wrk",',
		                 "tools/check.R", fn)
		chk <- .cso_edit(chk, .CSO_AUDIT_PATHS_LINE, '  AUDIT_PATHS = "01_dw_prep/012_codes",',
		                 "tools/check.R", fn)
	}
	if (!length(vendor_files)) {
		chk <- .cso_edit(chk, .CSO_CHECKS_LINE, .CSO_CHECKS_UNVENDORED, "tools/check.R", fn)
	}
	files[["tools/check.R"]] <- chk

	files[["tests/testthat.R"]] <- .cso_edit(
		.cso_bytes(file.path(tpl, "testthat", "tests", "testthat.R")),
		.CSO_SOURCE_DIRS, k$source_dirs, "testthat/tests/testthat.R", fn)
	files[["tests/testthat/helper-project.R"]] <-
		.cso_bytes(file.path(tpl, "testthat", "tests", "testthat", "helper-project.R"))

	proj <- .cso_bytes(file.path(tpl, "cso_project.yml"))
	# Each key line must be there (.cso_edit() stops with the envelope if not).
	for (line in c("\ncollaboration: ", "\ncollaboration_since: ")) {
		.cso_edit(proj, line, line, "cso_project.yml", fn)
	}
	s <- rawToChar(proj)
	s <- sub("\ncollaboration: [^\n]*", paste0("\ncollaboration: ", collaboration), s, useBytes = TRUE)
	s <- sub("\ncollaboration_since: [^\n]*", paste0("\ncollaboration_since: ", today), s, useBytes = TRUE)
	proj <- charToRaw(s)
	if (length(members)) {
		proj <- .cso_edit(proj, .CSO_MEMBERS_EXAMPLE,
		                  paste0("members:\n", paste0("  - ", members, "\n", collapse = "")),
		                  "cso_project.yml", fn)
	}
	files[["cso_project.yml"]] <- proj

	if (isTRUE(workflows)) {
		for (w in k$workflows) {
			files[[file.path(".github", "workflows", w)]] <- .cso_bytes(file.path(tpl, "workflows", w))
		}
	}

	if (length(vendor_files)) {
		version <- read.dcf(file.path(src, "r", "DESCRIPTION"), fields = "Version")[1, 1]
		for (f in vendor_files) {
			files[[file.path("00_functions", f)]] <- .cso_bytes(file.path(src, "r", "R", f))
		}
		manifest <- c(
			"# .toolkit_manifest.yml -- the cso-toolkit vintage this repository vendors.",
			sprintf("# Written by %s(); fields: cso-toolkit templates/.toolkit_manifest.yml.", fn),
			"# Update it every time you re-vendor, in the same pull request.",
			'source: "unicef-drp/cso-toolkit"',
			sprintf('pulled_version: "v%s"', version),
			sprintf('pulled_date: "%s"', today),
			sprintf('pulled_by: "%s"', .cso_user()),
			sprintf('# target_version: "v%s"   # optional: warn when pulled_version is behind', version),
			"",
			"# Files vendored from cso-toolkit/r/R/ into 00_functions/",
			"vendored:",
			paste0("  - ", vendor_files),
			"",
			"# Vendored files edited locally (cso_toolkit_pull() skips them).",
			"local_edits: []")
		files[["00_functions/.toolkit_manifest.yml"]] <- charToRaw(paste0(paste(manifest, collapse = "\n"), "\n"))
	}
	files[sort(names(files), method = "radix")]
}

#' Shared implementation of the two scaffolders
#' @keywords internal
#' @noRd
.cso_create_project <- function(kind, path, collaboration, members, title, vendor,
                                toolkit_source, workflows, git, overwrite,
                                verbose, debug) {
	k <- .CSO_PROJECT_KINDS[[kind]]
	fn <- k$fn
	vd <- .dw_vd(verbose, debug); v <- vd$v; d <- vd$d

	if (!(is.character(path) && length(path) == 1 && nzchar(path))) {
		stop(sprintf("[cso_toolkit.%s] `path` must be one folder path.\n Fix: pass the folder of the new repository, e.g. \"C:/GitHub/my-paper\".", fn),
		     call. = FALSE)
	}
	if (file.exists(path) && !dir.exists(path)) {
		stop(sprintf("[cso_toolkit.%s] %s is a file, not a folder.\n Fix: pass the folder of the new repository.", fn, path),
		     call. = FALSE)
	}
	if (is.null(collaboration) ||
	    !(is.character(collaboration) && length(collaboration) == 1 &&
	      collaboration %in% .DW_COLLAB_MODELS)) {
		stop(sprintf(
			"[cso_toolkit.%s] `collaboration` must be \"single-producer\" or \"multi-producer\"; it has no default.\n Why: how many people may produce results is a project decision, committed in cso_project.yml, and the toolkit does not guess it (as dw_mode has no default).\n Fix: pass collaboration = \"single-producer\" (one producer, the others review) or \"multi-producer\" (several co-authors produce).",
			fn), call. = FALSE)
	}
	if (!is.null(members)) {
		members <- as.character(members)
		bad <- members[is.na(members) | !grepl("^[A-Za-z0-9][A-Za-z0-9._-]*$", members)]
		if (length(bad)) {
			stop(sprintf(
				"[cso_toolkit.%s] Member handle(s) not usable as plain YAML: %s\n Fix: pass user names or GitHub handles (letters, digits, '.', '_', '-').",
				fn, paste(shQuote(bad), collapse = ", ")), call. = FALSE)
		}
	}
	if (is.null(title)) title <- basename(normalizePath(path, winslash = "/", mustWork = FALSE))
	project_name <- basename(normalizePath(path, winslash = "/", mustWork = FALSE))

	vendor_files <- if (isTRUE(vendor)) k$vendor else if (is.character(vendor)) {
		unique(c(.CSO_VENDOR_REQUIRED, vendor))
	} else character(0)
	src <- if (length(vendor_files)) .cso_toolkit_source(toolkit_source, fn) else toolkit_source
	if (length(vendor_files)) {
		missing <- vendor_files[!file.exists(file.path(src, "r", "R", vendor_files))]
		if (length(missing)) {
			stop(sprintf(
				"[cso_toolkit.%s] Not in %s/r/R/: %s\n Fix: check the file names, or use a clone at a release that has them.",
				fn, src, paste(missing, collapse = ", ")), call. = FALSE)
		}
	}
	if (isTRUE(git) && !nzchar(Sys.which("git"))) {
		stop(sprintf("[cso_toolkit.%s] git = TRUE, but git is not on the PATH.\n Fix: install git, or pass git = FALSE and run git init yourself.", fn),
		     call. = FALSE)
	}
	tpl <- .cso_templates_dir(src, fn)
	.dw_dbg(fn, "templates: ", tpl, "; toolkit source: ", src %||% "<none>", d = d)

	files <- .cso_project_files(kind, project_name, title, collaboration, members,
	                            vendor_files, src, tpl, workflows, fn)

	# Decide every file before writing any: never a half-written project.
	targets <- file.path(path, names(files))
	is_dir <- dir.exists(targets)
	if (any(is_dir)) {
		stop(sprintf(
			"[cso_toolkit.%s] These paths are folders under %s, where the project needs files:\n   %s\n Nothing was written.\n Fix: move the folders away, or choose another `path`.",
			fn, path, paste(names(files)[is_dir], collapse = "\n   ")), call. = FALSE)
	}
	status <- vapply(seq_along(files), function(i) {
		t <- targets[i]
		if (!file.exists(t)) return("written")
		if (identical(.cso_bytes(t), files[[i]])) "unchanged" else "conflict"
	}, character(1))
	if (any(status == "conflict") && !isTRUE(overwrite)) {
		stop(sprintf(
			"[cso_toolkit.%s] %d file(s) already exist under %s with different content:\n   %s\n Nothing was written.\n Fix: choose an empty folder, move those files away, or pass overwrite = TRUE to replace them.",
			fn, sum(status == "conflict"), path,
			paste(names(files)[status == "conflict"], collapse = "\n   ")), call. = FALSE)
	}
	status[status == "conflict"] <- "overwritten"

	for (i in seq_along(files)) {
		if (status[i] == "unchanged") next
		dir.create(dirname(targets[i]), recursive = TRUE, showWarnings = FALSE)
		writeBin(files[[i]], targets[i])
	}
	if (.Platform$OS.type != "windows") Sys.chmod(file.path(path, ".githooks", "pre-push"), mode = "0755")

	if (isTRUE(git)) .cso_git_setup(path, fn, v)

	out <- data.frame(path = names(files), status = status, stringsAsFactors = FALSE)
	.dw_msg(fn, sprintf("%s project at %s: %d file(s) written, %d overwritten, %d unchanged",
	                    kind, normalizePath(path, winslash = "/"), sum(status == "written"),
	                    sum(status == "overwritten"), sum(status == "unchanged")), v = v)
	.dw_msg(fn, "next: README.md > Quick start", if (!length(vendor_files))
		"; vendor the toolkit into 00_functions/ (00_functions/README.md)", v = v)
	invisible(out)
}

#' git init, develop as the first branch, the hook path, the hook's mode bit
#' @keywords internal
#' @noRd
.cso_git_setup <- function(path, fn, v) {
	run <- function(...) {
		out <- suppressWarnings(system2("git", c("-C", shQuote(path), ...), stdout = TRUE, stderr = TRUE))
		if ((attr(out, "status") %||% 0L) != 0L) {
			stop(sprintf(
				"[cso_toolkit.%s] The files were written, but `git %s` failed:\n   %s\n Fix: run the git steps by hand (README.md > Quick start).",
				fn, paste(c(...), collapse = " "), paste(out, collapse = "\n   ")), call. = FALSE)
		}
		out
	}
	if (!file.exists(file.path(path, ".git"))) {
		run("init", "--quiet")
		# Two trunks: work starts on develop; main is created at the first release.
		run("symbolic-ref", "HEAD", "refs/heads/develop")
		.dw_msg(fn, "git init: first branch develop", v = v)
	}
	run("config", "core.hooksPath", ".githooks")
	# Stage the hook with its executable bit, so it runs on macOS and Linux
	# clones too (Windows does not record the bit otherwise).
	run("add", "--chmod=+x", "--", ".githooks/pre-push")
	.dw_msg(fn, "git: core.hooksPath = .githooks; .githooks/pre-push staged as executable", v = v)
	invisible(TRUE)
}

#' Create a new research repository (paper, analysis, replication package)
#'
#' Writes the skeleton of a research repository into `path`, following the
#' toolkit's conventions: data never enter git while their `.provenance.json`
#' sidecars and an input manifest do; results (small tables and figures) are
#' committed with their sidecars, because in a research project git is the
#' canonical store for results; checks run locally with one command; two
#' trunks (`develop`, `main`). Everything comes from the templates the
#' package ships (a copy of the toolkit repository's `templates/`), so the
#' `.gitignore`, `tools/check.R`, the pre-push hook and the workflows are
#' the toolkit's own.
#'
#' The layout (handbook chapter "Starting a new repository"):
#' \preformatted{
#' .gitignore               templates/gitignore/research-project.gitignore
#' .githooks/pre-push       runs tools/check.R before every push
#' cso_project.yml          collaboration model (committed)
#' README.md, CONTRIBUTING.md
#' 00_functions/README.md   (+ helpers and .toolkit_manifest.yml if vendored)
#' R/README.md              numbered analysis scripts; R/functions/ for tests
#' data/README.md, data/input_manifest.csv, data/provenance/README.md
#' output/README.md         tables and figures, with sidecars
#' paper/README.md, references/README.md, docs/README.md
#' tests/testthat.R, tests/testthat/helper-project.R, test-project.R
#' tools/check.R
#' .github/workflows/*.yml  only with workflows = TRUE
#' }
#'
#' Nothing is written if any target file already exists with different
#' content, unless `overwrite = TRUE`; a file that already holds exactly
#' the bytes to be written is left alone and reported as `"unchanged"`, so
#' a second identical call changes nothing.
#'
#' @param path Character. Folder of the new repository; created if missing.
#' @param collaboration Character, required (no default, as `dw_mode` has
#'   none). `"single-producer"` (one person produces, the others review) or
#'   `"multi-producer"` (several co-authors produce). Written to
#'   `cso_project.yml`; change it later with [dw_set_collaboration()].
#' @param members Character vector or `NULL`. Collaborators' user names or
#'   GitHub handles, listed under `members:` in `cso_project.yml`
#'   (informational).
#' @param title Character or `NULL`. Title for the README; `NULL` uses the
#'   folder name.
#' @param vendor `FALSE` (default), `TRUE`, or a character vector of file
#'   names. `TRUE` copies the default helper set from a cso-toolkit clone's
#'   `r/R/` into `00_functions/` and writes `00_functions/.toolkit_manifest.yml`
#'   (`pulled_version` from the clone's `DESCRIPTION`). A character vector
#'   names the files; `dw_io.R`, `cso_toolkit_sync.R` and `test_scripts.R`
#'   are always added, because `tools/check.R` needs them. With `FALSE`,
#'   `tools/check.R` leaves out the `contract-audit` and `vintage` checks
#'   until the helpers are vendored (a comment there says so).
#' @param toolkit_source Character or `NULL`. Root of a cso-toolkit clone to
#'   vendor from, ideally checked out at a release tag. `NULL` uses the
#'   `CSO_TOOLKIT_ROOT` environment variable, else the source checkout the
#'   package was loaded from (`devtools::load_all()`). Only needed when
#'   vendoring.
#' @param workflows Logical. Also write the GitHub Actions workflows to
#'   `.github/workflows/`. Default `FALSE`: checks run locally. The
#'   workflows run only when started by hand and on pull requests into
#'   `main` (handbook chapter "Continuous integration and repository
#'   hygiene").
#' @param git Logical. Default `FALSE`. `TRUE` runs `git init` (when `path`
#'   is not a repository yet) with `develop` as the first branch, sets
#'   `core.hooksPath` to `.githooks`, and stages `.githooks/pre-push` with
#'   its executable bit. It never commits, creates a remote or pushes.
#' @param overwrite Logical. Replace existing files whose content differs.
#'   Default `FALSE`.
#' @param verbose Logical or `NULL`. Show high-level progress and result
#'   messages. `NULL` (default) inherits `getOption("dw.verbose", TRUE)`;
#'   set `TRUE`/`FALSE` to override for this call. See [dw_verbosity()].
#' @param debug Logical or `NULL`. Show internal troubleshooting detail.
#'   `NULL` (default) inherits `getOption("dw.debug", FALSE)`; implies
#'   `verbose`. See [dw_verbosity()].
#'
#' @return Invisibly, a data frame with one row per file: `path` (relative
#'   to `path`) and `status` (`"written"`, `"overwritten"` or
#'   `"unchanged"`).
#'
#' @section Errors:
#' Stops with a `[cso_toolkit.create_research_project]` envelope, before
#' writing anything, when `collaboration` is missing or unknown, when a
#' target file exists with different content and `overwrite = FALSE`, when
#' vendoring has no clone to copy from, or when `git = TRUE` and git is not
#' installed.
#'
#' @seealso [create_official_stats_project()]; [dw_set_collaboration()];
#'   [cso_toolkit_check()]; [test_scripts()].
#' @family scaffolding
#' @export
#' @examples
#' \dontrun{
#' create_research_project("C:/GitHub/learning-mobility",
#'                         collaboration = "multi-producer",
#'                         members = c("jpazvd", "kavanesian"),
#'                         title = "Schooling Mobility Is Not Learning Mobility",
#'                         vendor = TRUE, toolkit_source = "C:/GitHub/cso-toolkit",
#'                         git = TRUE)
#' }
create_research_project <- function(path, collaboration, members = NULL,
                                    title = NULL, vendor = FALSE,
                                    toolkit_source = NULL, workflows = FALSE,
                                    git = FALSE, overwrite = FALSE,
                                    verbose = NULL, debug = NULL) {
	if (missing(collaboration)) collaboration <- NULL
	.cso_create_project("research", path, collaboration, members, title, vendor,
	                    toolkit_source, workflows, git, overwrite, verbose, debug)
}

#' Create a new official-statistics repository (production pipeline)
#'
#' Writes the skeleton of an official-statistics repository -- a DW sector
#' pipeline, an SDMX or data.unicef.org publication pipeline, a
#' survey-processing repository -- into `path`. Outputs live in the deposit
#' (Teams and Z:, then SDMX and data.unicef.org) and are **embargoed until
#' publication**, so the `.gitignore` ignores output folders outright and
#' `tools/check.R` is set to fail on anything tracked in `output/`,
#' `outputs/`, `results/` or `wrk/` (`OUTPUT_DIRS`). What the repository
#' commits instead, after publication, is a release record under
#' `releases/<vintage>/`. Pipeline code follows the deposit's stage
#' numbering (`01_dw_prep/012_codes/<sector>/`), and the contract audit
#' reads that folder (`AUDIT_PATHS`).
#'
#' The layout (handbook chapter "Starting a new repository"):
#' \preformatted{
#' .gitignore                templates/gitignore/official-stats.gitignore
#' .githooks/pre-push        runs tools/check.R before every push
#' cso_project.yml           collaboration model (committed)
#' README.md, CONTRIBUTING.md
#' _config_template/user_config.yml   placeholder per-person configuration
#' 00_documentation/README.md
#' 00_functions/README.md    (+ helpers and .toolkit_manifest.yml if vendored)
#' 01_dw_prep/012_codes/README.md
#' inputs/README.md, inputs/input_manifest.csv
#' releases/README.md        release records, committed after publication
#' tests/testthat.R, tests/testthat/helper-project.R, test-project.R
#' tools/check.R             OUTPUT_DIRS and AUDIT_PATHS set
#' .github/workflows/*.yml   only with workflows = TRUE (no manuscript job)
#' }
#'
#' The arguments, the refusal to replace existing files and the returned
#' table are those of [create_research_project()]. With `vendor = TRUE`,
#' the default helper set adds `profile_helpers.R` (for [create_profile()])
#' and `create_sector_script.R` (for [create_dw_sector_script()]).
#'
#' @inheritParams create_research_project
#'
#' @return Invisibly, a data frame with one row per file: `path` (relative
#'   to `path`) and `status` (`"written"`, `"overwritten"` or
#'   `"unchanged"`).
#'
#' @section Errors:
#' As [create_research_project()], with the
#' `[cso_toolkit.create_official_stats_project]` prefix.
#'
#' @seealso [create_research_project()]; [create_profile()];
#'   [create_dw_sector_script()]; [dw_fetch_inputs()].
#' @family scaffolding
#' @export
#' @examples
#' \dontrun{
#' create_official_stats_project("C:/GitHub/DW-Nutrition",
#'                               collaboration = "single-producer",
#'                               title = "Nutrition indicators pipeline",
#'                               vendor = TRUE,
#'                               toolkit_source = "C:/GitHub/cso-toolkit")
#' }
create_official_stats_project <- function(path, collaboration, members = NULL,
                                          title = NULL, vendor = FALSE,
                                          toolkit_source = NULL, workflows = FALSE,
                                          git = FALSE, overwrite = FALSE,
                                          verbose = NULL, debug = NULL) {
	if (missing(collaboration)) collaboration <- NULL
	.cso_create_project("official-stats", path, collaboration, members, title, vendor,
	                    toolkit_source, workflows, git, overwrite, verbose, debug)
}
