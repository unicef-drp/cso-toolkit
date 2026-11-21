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
		# A paper's first scripts read data directly: the contract audit
		# reports them, and does not fail the checks, until the project moves
		# to dw_use() and sets AUDIT_MODE to "blocking".
		audit_mode = "advisory",
		deposit = FALSE,
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
		audit_mode = "blocking",
		# The profile derives the deposit paths and checks the Z: mirror.
		deposit = TRUE,
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
.CSO_OUTPUT_DIRS_OFFICIAL <- '  OUTPUT_DIRS = "output outputs results wrk 013_wrkdata",'
.CSO_DATA_DIRS_LINE <- '  DATA_DIRS   = "data inputs _apis _frozen",'
.CSO_DATA_DIRS_OFFICIAL <- '  DATA_DIRS   = "data inputs _apis _frozen 011_rawdata",'
.CSO_AUDIT_PATHS_LINE <- '  AUDIT_PATHS = "R",'
.CSO_AUDIT_MODE_LINE <- '  AUDIT_MODE  = "blocking",'
.CSO_SOURCE_DIRS <- 'SOURCE_DIRS <- c("R")'
.CSO_MEMBERS_EXAMPLE <- "# members:\n#   - jpazevedo\n#   - kbarnes\n"
.CSO_DEPOSIT_BLOCK <- "{{deposit_block}}\n"

# The git and release-tag helpers (.cso_bytes(), .cso_toolkit_source(),
# .cso_git_out(), .cso_resolve_tag(), .cso_git_blob(), .cso_user()) live in
# cso_toolkit_sync.R, which consumers vendor on its own.

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

#' Build the named list of files (relative path -> raw bytes) for a project
#' @keywords internal
#' @noRd
.cso_project_files <- function(kind, project_name, title, collaboration, members,
                               vendored, tpl, workflows, fn) {
	vendor_files <- names(vendored$files)
	k <- .CSO_PROJECT_KINDS[[kind]]
	today <- format(Sys.Date(), "%Y-%m-%d")
	vars <- list(project_name = project_name, title = title,
	             collaboration = collaboration, date = today,
	             input_manifest = k$input_manifest,
	             sentinel = gsub("[^A-Za-z0-9_]+", "_", project_name), fn = fn)
	files <- list()

	# Skeleton files: common/ then the kind's own folder (same path wins).
	for (layer in c("common", kind)) {
		base <- file.path(tpl, "project", layer)
		for (rel in list.files(base, recursive = TRUE, all.files = TRUE)) {
			files[[rel]] <- .cso_fill(.cso_bytes(file.path(base, rel)), vars)
		}
	}

	# profile_<project>.R: one template for both kinds; official statistics
	# add the deposit paths and the Z: mirror check.
	prof <- .cso_edit(.cso_bytes(file.path(tpl, "profile", "profile.R")), .CSO_DEPOSIT_BLOCK,
	                  if (isTRUE(k$deposit)) rawToChar(.cso_bytes(file.path(tpl, "profile", "deposit.R"))) else "",
	                  "profile/profile.R", fn)
	files[[paste0("profile_", project_name, ".R")]] <- .cso_fill(prof, vars)

	files[[".gitignore"]] <- .cso_bytes(file.path(tpl, "gitignore", k$gitignore))
	files[[".gitattributes"]] <- .cso_bytes(file.path(tpl, "gitattributes", "project.gitattributes"))
	files[[".githooks/pre-push"]] <- .cso_bytes(file.path(tpl, "hooks", "pre-push"))

	chk <- .cso_bytes(file.path(tpl, "tools", "check.R"))
	if (kind == "official-stats") {
		# The deposit layout's stages: 013_wrkdata is embargoed like any output
		# folder, 011_rawdata holds data like any input folder.
		chk <- .cso_edit(chk, .CSO_OUTPUT_DIRS_LINE, .CSO_OUTPUT_DIRS_OFFICIAL,
		                 "tools/check.R", fn)
		chk <- .cso_edit(chk, .CSO_DATA_DIRS_LINE, .CSO_DATA_DIRS_OFFICIAL,
		                 "tools/check.R", fn)
		chk <- .cso_edit(chk, .CSO_AUDIT_PATHS_LINE, '  AUDIT_PATHS = "01_dw_prep/012_codes",',
		                 "tools/check.R", fn)
	}
	chk <- .cso_edit(chk, .CSO_AUDIT_MODE_LINE,
	                 sprintf('  AUDIT_MODE  = "%s",', k$audit_mode), "tools/check.R", fn)
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
		for (f in vendor_files) {
			files[[file.path("00_functions", f)]] <- vendored$files[[f]]
		}
		manifest <- c(
			"# .toolkit_manifest.yml -- the cso-toolkit vintage this repository vendors.",
			sprintf("# Written by %s(); fields: cso-toolkit templates/.toolkit_manifest.yml.", fn),
			"# Update it every time you re-vendor, in the same pull request.",
			'source: "unicef-drp/cso-toolkit"',
			sprintf('pulled_version: "%s"', vendored$tag),
			sprintf('pulled_commit: "%s"', vendored$sha),
			sprintf('pulled_date: "%s"', today),
			sprintf('pulled_by: "%s"', .cso_user()),
			sprintf('# target_version: "%s"   # optional: warn when pulled_version is behind', vendored$tag),
			"",
			"# Files vendored from cso-toolkit/r/R/ at pulled_version into 00_functions/",
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
                                toolkit_source, toolkit_version, workflows, git,
                                overwrite, verbose, debug) {
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
	vendored <- list(files = list(), tag = NULL, sha = NULL)
	if (length(vendor_files)) {
		# Always a release tag, read from git history: never the working tree,
		# which may be on another branch or carry local edits.
		rel <- .cso_resolve_tag(src, toolkit_version, fn)
		blobs <- lapply(vendor_files, function(f) .cso_git_blob(src, rel$sha, paste0("r/R/", f)))
		names(blobs) <- vendor_files
		absent <- vendor_files[vapply(blobs, is.null, logical(1))]
		# The default set may name helpers newer than an older tag: those are
		# skipped (and named). A file the caller listed, or one that
		# tools/check.R needs, must be there.
		optional <- if (isTRUE(vendor)) setdiff(absent, .CSO_VENDOR_REQUIRED) else character(0)
		missing <- setdiff(absent, optional)
		if (length(missing)) {
			stop(sprintf(
				"[cso_toolkit.%s] Not in r/R/ at %s (%s): %s\n Nothing was written.\n Fix: check the file names, or pass a `toolkit_version` that has them.",
				fn, rel$tag, substr(rel$sha, 1, 7), paste(missing, collapse = ", ")), call. = FALSE)
		}
		if (length(optional)) {
			.dw_msg(fn, sprintf("not in %s, so not vendored: %s (re-vendor from a later release to add them)",
			                    rel$tag, paste(optional, collapse = ", ")), v = v)
		}
		vendored <- list(files = blobs[setdiff(vendor_files, absent)], tag = rel$tag, sha = rel$sha)
	}
	if (isTRUE(git) && !nzchar(Sys.which("git"))) {
		stop(sprintf("[cso_toolkit.%s] git = TRUE, but git is not on the PATH.\n Fix: install git, or pass git = FALSE and run git init yourself.", fn),
		     call. = FALSE)
	}
	tpl <- .cso_templates_dir(src, fn)
	.dw_dbg(fn, "templates: ", tpl, "; toolkit source: ", src %||% "<none>",
	        if (!is.null(vendored$tag)) paste0(" at ", vendored$tag, " (", vendored$sha, ")"), d = d)

	files <- .cso_project_files(kind, project_name, title, collaboration, members,
	                            vendored, tpl, workflows, fn)

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
	if (!is.null(vendored$tag)) {
		.dw_msg(fn, sprintf("vendored %d helper(s) from cso-toolkit %s (commit %s)",
		                    length(vendored$files), vendored$tag, substr(vendored$sha, 1, 7)), v = v)
	}
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
#' .gitattributes           LF for the hook, vendored helpers and sidecars
#' profile_<project>.R      sourced first: user, dw_mode, vendored helpers
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
#' `profile_<project>.R` (`<project>` is the folder name) is the script
#' every session sources first, from the template `templates/profile/`:
#' it reads the user's block of `~/.config/user_config.yml` (top-level keys
#' as a fallback), resolves `dw_mode` as `dw_mode_by_project[[<project>]]`
#' then `dw_mode` and stops, showing the YAML to add, when neither is set;
#' sources the vendored helpers from `00_functions/` (`zzz.R` first); never
#' installs packages; and sets the sentinel `profile_<project> <- TRUE`.
#' [review_profile()] passes it. The official-statistics profile also
#' derives the deposit paths from `dw_mode` and checks the Z: mirror.
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
#'   names. `TRUE` copies the default helper set, as it is at the release
#'   tag `toolkit_version`, from a cso-toolkit clone's `r/R/` into
#'   `00_functions/` and writes `00_functions/.toolkit_manifest.yml`
#'   (`pulled_version` = the tag, `pulled_commit` = the commit it points
#'   to). Helpers of the default set that the tag does not have yet are
#'   skipped and named in a message. A character vector names the files,
#'   all of which must exist at the tag; `dw_io.R`, `cso_toolkit_sync.R`
#'   and `test_scripts.R` are always added, because `tools/check.R` needs
#'   them. With `FALSE`, `tools/check.R` leaves out the `contract-audit`
#'   and `vintage` checks until the helpers are vendored (a comment there
#'   says so).
#' @param toolkit_source Character or `NULL`. Root of a git clone of
#'   cso-toolkit, with its tags, to vendor from. Its working tree may be on
#'   any branch and carry local edits: the files are read from the tag's
#'   commit (`git cat-file`), never from the working tree. `NULL` uses the
#'   `CSO_TOOLKIT_ROOT` environment variable, else the source checkout the
#'   package was loaded from (`devtools::load_all()`). Only needed when
#'   vendoring.
#' @param toolkit_version Character or `NULL`. The release tag to vendor,
#'   e.g. `"v0.9.1"` (`"0.9.1"` is read as `"v0.9.1"`). `NULL` (default)
#'   takes the clone's latest release tag (`v` and numbers only, so
#'   pre-release tags such as `v1.0.0-rc1` are passed over). Only used when
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
#' vendoring has no git clone to copy from, the tag does not exist there or
#' a requested file is not in it, or when `git = TRUE` (or vendoring) and
#' git is not installed.
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
#'                         toolkit_version = "v0.9.1",
#'                         git = TRUE)
#' }
create_research_project <- function(path, collaboration, members = NULL,
                                    title = NULL, vendor = FALSE,
                                    toolkit_source = NULL, toolkit_version = NULL,
                                    workflows = FALSE, git = FALSE,
                                    overwrite = FALSE, verbose = NULL,
                                    debug = NULL) {
	if (missing(collaboration)) collaboration <- NULL
	.cso_create_project("research", path, collaboration, members, title, vendor,
	                    toolkit_source, toolkit_version, workflows, git, overwrite,
	                    verbose, debug)
}

#' Create a new official-statistics repository (production pipeline)
#'
#' Writes the skeleton of an official-statistics repository -- a DW sector
#' pipeline, an SDMX or data.unicef.org publication pipeline, a
#' survey-processing repository -- into `path`. Outputs live in the deposit
#' (Teams and Z:, then SDMX and data.unicef.org) and are **embargoed until
#' publication**, so the `.gitignore` ignores output folders outright and
#' `tools/check.R` is set to fail on anything tracked in `013_wrkdata/`,
#' `output/`, `outputs/`, `results/` or `wrk/` (`OUTPUT_DIRS`), and on data
#' tracked in `011_rawdata/` (`DATA_DIRS`). What the repository commits
#' instead, after publication, is a release record under
#' `releases/<vintage>/`. The layout follows DW-Production and the
#' deposit's stage numbering (`01_dw_prep/010_metadata`, `011_rawdata`,
#' `012_codes`, `013_wrkdata`), and the contract audit reads the code in
#' `01_dw_prep/012_codes/` (`AUDIT_PATHS`, blocking).
#'
#' The layout (handbook chapter "Starting a new repository"):
#' \preformatted{
#' .gitignore                templates/gitignore/official-stats.gitignore
#' .gitattributes            LF for the hook, vendored helpers and sidecars
#' profile_<project>.R       sourced first: user, dw_mode, deposit paths,
#'                           Z: mirror, vendored helpers
#' .githooks/pre-push        runs tools/check.R before every push
#' cso_project.yml           collaboration model (committed)
#' README.md, CONTRIBUTING.md
#' _config_template/user_config.yml   placeholder per-person configuration
#' 00_documentation/README.md
#' 00_functions/README.md    (+ helpers and .toolkit_manifest.yml if vendored)
#' 01_dw_prep/README.md      the stages: what each holds, what reaches git
#' 01_dw_prep/010_metadata/README.md   reference metadata, committed
#' 01_dw_prep/011_rawdata/README.md    local raw inputs: ignored, sidecars kept
#' 01_dw_prep/012_codes/README.md      pipeline code, one folder per sector
#'                           (013_wrkdata/ has no tracked file: embargoed)
#' inputs/README.md, inputs/input_manifest.csv
#' releases/README.md        release records, committed after publication
#' tests/testthat.R, tests/testthat/helper-project.R, test-project.R
#' tools/check.R             OUTPUT_DIRS, DATA_DIRS and AUDIT_PATHS set
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
#'                               toolkit_source = "C:/GitHub/cso-toolkit",
#'                               toolkit_version = "v0.9.1")
#' }
create_official_stats_project <- function(path, collaboration, members = NULL,
                                          title = NULL, vendor = FALSE,
                                          toolkit_source = NULL,
                                          toolkit_version = NULL,
                                          workflows = FALSE, git = FALSE,
                                          overwrite = FALSE, verbose = NULL,
                                          debug = NULL) {
	if (missing(collaboration)) collaboration <- NULL
	.cso_create_project("official-stats", path, collaboration, members, title, vendor,
	                    toolkit_source, toolkit_version, workflows, git, overwrite,
	                    verbose, debug)
}
