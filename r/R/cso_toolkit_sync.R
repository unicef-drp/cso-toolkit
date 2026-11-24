#-------------------------------------------------------------------
# 00_functions/cso_toolkit_sync.R
# Purpose: Vintage-management helpers for the vendored copies of
#          unicef-drp/cso-toolkit functions in this folder.
#
# Design (handbook chapter "Vendoring and updates"):
#   - Helpers in 00_functions/ are VENDORED COPIES of cso-toolkit code,
#     not sourced live. This pins the vintage per consuming repo.
#   - .toolkit_manifest.yml records the upstream release tag the copies
#     came from (pulled_version, pulled_commit) and the vendored files.
#   - cso_toolkit_check()  -- checks the vendored copy against a target version
#                             (offline; warns when behind) and, in producer
#                             mode, against the latest upstream tag (the
#                             poll respects dw_apis_allowed)
#   - cso_toolkit_diff()   -- compares each vendored file with the file at a
#                             release tag (unchanged / changed / local_edit /
#                             missing_upstream / missing_local)
#   - cso_toolkit_pull()   -- refreshes the vendored files to a release tag
#                             and re-pins the manifest
#   - cso_toolkit_sync()   -- the one call: latest tag, its NEWS, diff, pull
#
# Where upstream files come from: a release tag, never a working tree or a
# branch. With `toolkit_source` (or CSO_TOOLKIT_ROOT) the tag is read from
# that local clone's git history (git cat-file; the clone is never fetched
# or changed). Otherwise the tag is cloned shallowly over HTTPS from
# https://github.com/<source>.git into a temporary folder, which works where
# corporate proxies block api.github.com.
#
# This file is self-contained apart from dw_io.R (`%||%`, .dw_vd(),
# .dw_msg(), .dw_dbg(), .try_get()): a consumer vendors it without
# create_project.R, which calls the git helpers defined here.
#
# Line endings: the toolkit pins LF (.gitattributes), so a vendored file
# has the same bytes on every platform as the blob at its tag. Comparisons
# here also ignore CRLF-only differences, so a consumer clone that checks
# files out with CRLF does not see every file as changed.
#-------------------------------------------------------------------

#' Locate the toolkit manifest next to vendored helpers
#'
#' Internal. Looks for `.toolkit_manifest.yml` in the same directory as the
#' vendored helpers -- typically `<repo>/00_functions/`. Resolves the
#' directory via the `dwFunct` global when set by the profile, otherwise
#' falls back to `<getwd()>/00_functions`.
#'
#' @return Character. Absolute or relative path to
#'   `.toolkit_manifest.yml` (may not exist).
#'
#' @keywords internal
#' @noRd
.cso_manifest_path <- function() {
	# Manifest lives next to the helpers it tracks.
	# Resolve `dwFunct` from .GlobalEnv ONLY (not the caller's frame) so a
	# local variable named `dwFunct` in some sector script can never hijack
	# the lookup.
	root <- if (exists("dwFunct", envir = .GlobalEnv, inherits = FALSE)) {
		get("dwFunct", envir = .GlobalEnv, inherits = FALSE)
	} else {
		file.path(getwd(), "00_functions")
	}
	file.path(root, ".toolkit_manifest.yml")
}

#' Read the toolkit manifest into a named list
#'
#' Internal. Returns `NULL` (with a message) when the `yaml` package is
#' missing or the manifest file does not exist.
#'
#' @return Named list (from `yaml::read_yaml`) or `NULL`.
#'
#' @keywords internal
#' @noRd
.cso_load_manifest <- function() {
	if (!requireNamespace("yaml", quietly = TRUE)) {
		warning("cso_toolkit_sync: yaml package not installed; skipping checks")
		return(NULL)
	}
	mpath <- .cso_manifest_path()
	if (!file.exists(mpath)) {
		message("cso_toolkit_sync: no manifest at ", mpath,
		        " -- helpers are not vendored from any upstream.")
		return(NULL)
	}
	yaml::read_yaml(mpath)
}

#' Normalise a toolkit tag for version comparison
#'
#' Internal. Strips a leading `v` and any pre-release / build suffix
#' (`-rc1`, `+meta`), so `"v0.9.1"` and `"0.9.1"` compare equal. Returns
#' `NA` for anything that is not a dotted version number (e.g. `"inrepo"`).
#'
#' @param x Character scalar or `NULL`.
#' @return Character scalar (e.g. `"0.9.1"`) or `NA_character_`.
#' @keywords internal
#' @noRd
.cso_version_norm <- function(x) {
	if (is.null(x) || length(x) != 1 || is.na(x)) return(NA_character_)
	x <- sub("^v", "", trimws(as.character(x)))
	x <- sub("[-+].*$", "", x)
	if (!grepl("^[0-9]+(\\.[0-9]+)*$", x)) return(NA_character_)
	x
}

#' Is one toolkit version behind another?
#'
#' Internal. Numeric comparison via [utils::compareVersion()], so
#' `0.10.0` is newer than `0.9.1` (a string comparison gets this wrong).
#'
#' @param pinned,target Character scalars (tags such as `"v0.9.0"`).
#' @return `TRUE` when `pinned` is older than `target`, `FALSE` when it is
#'   the same or newer, `NA` when either is not a version (e.g. `"inrepo"`).
#' @keywords internal
#' @noRd
.cso_version_behind <- function(pinned, target) {
	p <- .cso_version_norm(pinned)
	t <- .cso_version_norm(target)
	if (is.na(p) || is.na(t)) return(NA)
	utils::compareVersion(p, t) < 0
}

#' Format a tag with a single leading `v`
#'
#' @keywords internal
#' @noRd
.cso_tag <- function(x) paste0("v", sub("^v", "", as.character(x)))

#' Draw an ASCII box around lines of text
#'
#' Internal. ASCII only, so it renders the same in every console (no
#' box-drawing characters that a non-UTF-8 Windows console would mangle).
#'
#' @param lines Character vector.
#' @return Character scalar with embedded newlines.
#' @keywords internal
#' @noRd
.cso_box <- function(lines) {
	w <- max(nchar(lines)) + 2
	bar <- paste0("+", strrep("-", w), "+")
	body <- paste0("| ", formatC(lines, width = -(w - 2)), " |")
	paste(c(bar, body, bar), collapse = "\n")
}

# ---------------------------------------------------------------------------
# git and release-tag helpers (create_project.R uses them too)
# ---------------------------------------------------------------------------

#' Read a file as raw bytes
#' @keywords internal
#' @noRd
.cso_bytes <- function(f) readBin(f, "raw", n = file.info(f)$size)

#' Resolve a local cso-toolkit clone
#'
#' `toolkit_source`, else `CSO_TOOLKIT_ROOT`, else (with `checkout = TRUE`)
#' the source checkout the package was loaded from. Stops with an envelope
#' when there is no git clone of the toolkit or no git.
#' @param alt Text that ends each `Fix:` (the caller's way out).
#' @keywords internal
#' @noRd
.cso_toolkit_source <- function(toolkit_source, fn, checkout = TRUE,
                                alt = "or pass `vendor = FALSE` and vendor by hand later") {
	src <- toolkit_source
	if (is.null(src) || !nzchar(src)) src <- Sys.getenv("CSO_TOOLKIT_ROOT")
	if (!nzchar(src) && isTRUE(checkout)) {
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
	# A clone: the helpers are read from its git history (a release tag), so
	# the working tree only has to be a git repository of the toolkit.
	if (!nzchar(src) || !file.exists(file.path(src, ".git")) ||
	    !file.exists(file.path(src, "r", "DESCRIPTION"))) {
		stop(sprintf(
			"[cso_toolkit.%s] No cso-toolkit clone to vendor the helpers from%s.\n Why: vendoring copies the helper files of a release tag from a git clone of the toolkit (git history, r/R/); the installed package does not carry them as source.\n Fix: clone unicef-drp/cso-toolkit (with its tags) and pass `toolkit_source = \"<clone>\"` (or set CSO_TOOLKIT_ROOT); %s.",
			fn, if (nzchar(src)) paste0(" (", src, " is not a git clone of cso-toolkit)") else "", alt),
		     call. = FALSE)
	}
	if (!nzchar(Sys.which("git"))) {
		stop(sprintf(
			"[cso_toolkit.%s] Vendoring reads the helpers from the clone's git history, but git is not on the PATH.\n Fix: install git, %s.",
			fn, alt), call. = FALSE)
	}
	normalizePath(src, winslash = "/")
}

#' Run git in a clone; stdout lines, or NULL when git exits non-zero
#' @keywords internal
#' @noRd
.cso_git_out <- function(src, ...) {
	out <- suppressWarnings(system2("git", c("-C", shQuote(src), ...),
	                                stdout = TRUE, stderr = FALSE))
	if ((attr(out, "status") %||% 0L) != 0L) return(NULL)
	out
}

#' The release tag to vendor and the commit it points to
#'
#' `toolkit_version = NULL` takes the clone's latest release tag (`v` and
#' dot-separated numbers; pre-release tags such as `v1.0.0-rc1` are left
#' out). A version without the leading `v` gets one.
#' @param arg Name of the caller's argument, for the messages.
#' @keywords internal
#' @noRd
.cso_resolve_tag <- function(src, toolkit_version, fn, arg = "toolkit_version") {
	if (is.null(toolkit_version)) {
		tags <- .cso_git_out(src, "tag", "--list", shQuote("v*"), "--sort=-v:refname")
		tags <- tags[grepl("^v[0-9]+(\\.[0-9]+)*$", tags)]
		if (!length(tags)) {
			stop(sprintf(
				"[cso_toolkit.%s] The clone at %s has no release tag (v<major>.<minor>.<patch>).\n Why: vendored helpers come from a release tag, never from a working tree, so the manifest names a real release.\n Fix: fetch the tags (git -C \"%s\" fetch --tags), or pass `%s = \"vX.Y.Z\"`.",
				fn, src, src, arg), call. = FALSE)
		}
		tag <- tags[1]
	} else {
		if (!(is.character(toolkit_version) && length(toolkit_version) == 1 &&
		      !is.na(toolkit_version) && nzchar(toolkit_version))) {
			stop(sprintf("[cso_toolkit.%s] `%s` must be one tag name, e.g. \"v0.9.1\".\n Fix: pass a release tag of the clone, or NULL for its latest.", fn, arg),
			     call. = FALSE)
		}
		tag <- .cso_norm_tag(toolkit_version)
	}
	sha <- .cso_git_out(src, "rev-list", "-n", "1", paste0("refs/tags/", tag))
	if (is.null(sha) || !length(sha) || !grepl("^[0-9a-f]{40}$", sha[1])) {
		have <- .cso_git_out(src, "tag", "--list", shQuote("v*"), "--sort=-v:refname")
		stop(sprintf(
			"[cso_toolkit.%s] Tag %s does not exist in the clone at %s.\n Why: vendored helpers come from a release tag, never from a working tree or a branch.\n Fix: pass one of the clone's tags (latest: %s), or fetch the tags first (git -C \"%s\" fetch --tags).",
			fn, tag, src, if (length(have)) paste(utils::head(have, 5), collapse = ", ") else "none", src),
		     call. = FALSE)
	}
	list(tag = tag, sha = sha[1])
}

#' Bytes of a file at a commit (git cat-file blob), or NULL if absent
#' @keywords internal
#' @noRd
.cso_git_blob <- function(src, sha, path) {
	tmp <- tempfile("blob_")
	on.exit(unlink(tmp))
	st <- suppressWarnings(system2("git", c("-C", shQuote(src), "cat-file", "blob",
	                                        paste0(sha, ":", path)),
	                               stdout = tmp, stderr = FALSE))
	if (!identical(as.integer(st), 0L) || !file.exists(tmp)) return(NULL)
	.cso_bytes(tmp)
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

#' A version written as a tag: `0.9.1` -> `v0.9.1`; other names unchanged
#' @keywords internal
#' @noRd
.cso_norm_tag <- function(x) if (grepl("^[0-9]", x)) paste0("v", x) else x

#' The highest release tag (`vX.Y.Z`, no pre-releases), compared numerically
#' @keywords internal
#' @noRd
.cso_latest_version_tag <- function(tags) {
	tags <- unique(tags[grepl("^v[0-9]+(\\.[0-9]+)*$", tags)])
	if (!length(tags)) return(NULL)
	tags[order(numeric_version(sub("^v", "", tags)), decreasing = TRUE)][1]
}

#' Run a git command that reaches the network
#'
#' No credential prompt (`GIT_TERMINAL_PROMPT=0`), a timeout, stderr kept
#' for the error message. Returns the output with a `status` attribute.
#' @keywords internal
#' @noRd
.cso_git_net <- function(args, timeout = 300) {
	old <- Sys.getenv("GIT_TERMINAL_PROMPT", unset = NA)
	Sys.setenv(GIT_TERMINAL_PROMPT = "0")
	on.exit(if (is.na(old)) Sys.unsetenv("GIT_TERMINAL_PROMPT") else Sys.setenv(GIT_TERMINAL_PROMPT = old))
	out <- tryCatch(suppressWarnings(system2("git", args, stdout = TRUE, stderr = TRUE,
	                                         timeout = timeout)),
	                error = function(e) structure(conditionMessage(e), status = 1L))
	if (is.null(attr(out, "status"))) attr(out, "status") <- 0L
	out
}

#' HTTPS URL of a GitHub `owner/repo`
#' @keywords internal
#' @noRd
.cso_remote_url <- function(source_repo) sprintf("https://github.com/%s.git", source_repo)

#' Latest release tag via `git ls-remote` (no API), or NULL
#' @keywords internal
#' @noRd
.cso_ls_remote_latest <- function(source_repo) {
	if (!nzchar(Sys.which("git"))) return(NULL)
	out <- .cso_git_net(c("ls-remote", "--tags", "--refs", .cso_remote_url(source_repo)), 60)
	if (!identical(as.integer(attr(out, "status")), 0L)) return(NULL)
	tags <- sub("^.*\trefs/tags/", "", out[grepl("\trefs/tags/", out, fixed = TRUE)])
	.cso_latest_version_tag(tags)
}

#' Look up the latest tag at the upstream repo
#'
#' Internal. Tries `gh api repos/<source>/releases/latest --jq .tag_name`
#' first (no auth flicker when `gh auth status` is good); falls back to
#' `httr::GET` on `api.github.com` when `gh` is missing; then to
#' `git ls-remote --tags` over HTTPS (the highest `vX.Y.Z` tag), which
#' works where proxies block api.github.com. Returns `NULL` when every path
#' fails (unreachable network, repo absent, no releases).
#'
#' @param source_repo Character. `"owner/repo"` slug.
#'
#' @return Character tag (e.g. `"v0.2.0"`), or `NULL`.
#'
#' @keywords internal
#' @noRd
.cso_upstream_latest_tag <- function(source_repo) {
	# Use gh CLI when available; otherwise raw GitHub API via httr
	if (Sys.which("gh") != "") {
		out <- tryCatch(
			system2("gh",
			        args = c("api",
			                 sprintf("repos/%s/releases/latest", source_repo),
			                 "--jq", ".tag_name"),
			        stdout = TRUE, stderr = FALSE),
			error = function(e) character(0),
			warning = function(w) character(0)
		)
		if (length(out) > 0 && nzchar(out[1])) return(out[1])
	}
	# Fallback: httr GET
	if (requireNamespace("httr", quietly = TRUE) &&
	    requireNamespace("jsonlite", quietly = TRUE)) {
		url <- sprintf("https://api.github.com/repos/%s/releases/latest", source_repo)
		resp <- tryCatch(httr::GET(url), error = function(e) NULL)
		if (!is.null(resp) && httr::status_code(resp) == 200) {
			body <- httr::content(resp, as = "parsed", type = "application/json")
			if (!is.null(body$tag_name)) return(body$tag_name)
		}
	}
	# Fallback: git over HTTPS (no API)
	.cso_ls_remote_latest(source_repo)
}

#' `toolkit_source`, else `CSO_TOOLKIT_ROOT`, else NULL (= read from GitHub)
#' @keywords internal
#' @noRd
.cso_local_source <- function(toolkit_source) {
	if (!is.null(toolkit_source) && length(toolkit_source) == 1 && !is.na(toolkit_source) &&
	    nzchar(toolkit_source)) return(as.character(toolkit_source))
	env <- Sys.getenv("CSO_TOOLKIT_ROOT")
	if (nzchar(env)) env else NULL
}

#' Where a vendored file lives in the toolkit repository
#'
#' `*.R` maps to `r/R/`, `*.py` to `python/src/`. `README.md` maps to the
#' folder of the other vendored files (`files`): `r/R/README.md` when they
#' are all R, `python/src/README.md` when they are all Python. A README is
#' synced only when the manifest lists it: a scaffolded repository's
#' `00_functions/README.md` comes from the project template instead.
#' @keywords internal
#' @noRd
.cso_upstream_path <- function(f, fn, files = f) {
	if (grepl("\\.[Rr]$", f)) return(paste0("r/R/", f))
	if (grepl("\\.py$", f)) return(paste0("python/src/", f))
	if (identical(f, "README.md")) {
		has_r <- any(grepl("\\.[Rr]$", files))
		has_py <- any(grepl("\\.py$", files))
		if (has_r && !has_py) return("r/R/README.md")
		if (has_py && !has_r) return("python/src/README.md")
		stop(sprintf(
			"[cso_toolkit.%s] Cannot tell which README.md the vendored copy follows.\n Why: README.md maps to the folder of the other vendored files, r/R/ when they are all *.R and python/src/ when they are all *.py; `vendored:` lists %s.\n Fix: remove README.md from `vendored:` in .toolkit_manifest.yml and update it by hand.",
			fn, if (has_r) "both" else "neither"), call. = FALSE)
	}
	stop(sprintf(
		"[cso_toolkit.%s] Cannot tell where the vendored file %s lives in cso-toolkit.\n Why: vendored files are mapped by extension: *.R to r/R/, *.py to python/src/ (and README.md to the folder of the others).\n Fix: remove %s from `vendored:` in .toolkit_manifest.yml (vendor it by hand), or fix the file name.",
		fn, f, f), call. = FALSE)
}

#' The release tag a call works on: the argument, or the latest
#' @keywords internal
#' @noRd
.cso_target_tag <- function(m, target_version, local, fn) {
	if (!is.null(target_version)) {
		if (!(is.character(target_version) && length(target_version) == 1 &&
		      !is.na(target_version) && grepl("^[A-Za-z0-9._-]+$", target_version))) {
			stop(sprintf("[cso_toolkit.%s] `target_version` must be one tag name, e.g. \"v0.9.1\".\n Fix: pass a release tag of cso-toolkit, or NULL for the latest.", fn),
			     call. = FALSE)
		}
		return(.cso_norm_tag(target_version))
	}
	if (!is.null(local)) {
		src <- .cso_toolkit_source(local, fn, checkout = FALSE, alt = .CSO_ALT_GITHUB)
		return(.cso_resolve_tag(src, NULL, fn, arg = "target_version")$tag)
	}
	tag <- .cso_upstream_latest_tag(m$source)
	if (is.null(tag)) {
		stop(sprintf(
			"[cso_toolkit.%s] Could not find the latest release of %s.\n Why: neither the gh CLI, the GitHub API nor `git ls-remote` over HTTPS reached GitHub.\n Fix: check the network, or pass `target_version = \"vX.Y.Z\"`, or `toolkit_source = \"<a local cso-toolkit clone>\"`.",
			fn, m$source), call. = FALSE)
	}
	.cso_norm_tag(tag)
}

.CSO_ALT_GITHUB <- "or leave `toolkit_source` unset (and CSO_TOOLKIT_ROOT empty) to read the tag from GitHub"

#' The upstream files at a release tag: a git dir to read blobs from
#'
#' With a local clone (`toolkit_source` / `CSO_TOOLKIT_ROOT`) its history is
#' read as is: no fetch, no checkout. Otherwise the tag is cloned shallowly
#' (`--depth 1 --no-checkout`) from GitHub over HTTPS into a temporary
#' folder; call `$cleanup()` when done. `base` (the manifest's
#' `pulled_version`) is resolved too when it can be, so local edits can be
#' told apart from upstream changes; `base_commit` (`pulled_commit`) is the
#' fallback.
#'
#' @return List: `dir`, `tag`, `sha`, `local`, `base_sha` (or NULL),
#'   `cleanup`.
#' @keywords internal
#' @noRd
.cso_upstream_tree <- function(source_repo, tag, toolkit_source, fn,
                               base = NULL, base_commit = NULL, d = FALSE) {
	local <- .cso_local_source(toolkit_source)
	if (!is.null(local)) {
		src <- .cso_toolkit_source(local, fn, checkout = FALSE, alt = .CSO_ALT_GITHUB)
		rel <- .cso_resolve_tag(src, tag, fn, arg = "target_version")
		tree <- list(dir = src, tag = rel$tag, sha = rel$sha, local = TRUE,
		             cleanup = function() invisible(NULL))
		.dw_dbg(fn, "reading ", rel$tag, " (", rel$sha, ") from the local clone ", src, d = d)
	} else {
		if (!nzchar(Sys.which("git"))) {
			stop(sprintf("[cso_toolkit.%s] Reading a cso-toolkit release needs git, which is not on the PATH.\n Fix: install git.", fn),
			     call. = FALSE)
		}
		if (!grepl("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", source_repo %||% "")) {
			stop(sprintf("[cso_toolkit.%s] The manifest's `source:` (%s) is not a GitHub owner/repo.\n Fix: set `source: \"unicef-drp/cso-toolkit\"` in .toolkit_manifest.yml.",
			             fn, source_repo %||% "<unset>"), call. = FALSE)
		}
		dir <- tempfile("cso_upstream_")
		url <- .cso_remote_url(source_repo)
		.dw_dbg(fn, "git clone --depth 1 --branch ", tag, " --no-checkout ", url, d = d)
		out <- .cso_git_net(c("clone", "--quiet", "--depth", "1", "--branch", tag,
		                      "--no-checkout", url, shQuote(dir)), 300)
		if (!identical(as.integer(attr(out, "status")), 0L)) {
			unlink(dir, recursive = TRUE, force = TRUE)
			stop(sprintf(
				"[cso_toolkit.%s] Could not read tag %s from %s.\n   git: %s\n Why: the tag does not exist there, or GitHub is not reachable over HTTPS from this machine.\n Fix: check the tag name (cso_toolkit_check(quiet = FALSE) shows the latest) and the network; or pass `toolkit_source = \"<a local cso-toolkit clone>\"` after `git -C <clone> fetch --tags`.",
				fn, tag, url, paste(utils::tail(out, 3), collapse = " | ")), call. = FALSE)
		}
		sha <- .cso_git_out(dir, "rev-parse", "HEAD")
		tree <- list(dir = normalizePath(dir, winslash = "/"), tag = tag, sha = sha[1], local = FALSE,
		             cleanup = function() unlink(dir, recursive = TRUE, force = TRUE))
		.dw_dbg(fn, "cloned ", tag, " (", sha[1], ") into ", dir, d = d)
	}

	tree$base_sha <- NULL
	if (!is.null(base) && !is.na(.cso_version_norm(base))) {
		btag <- .cso_norm_tag(base)
		if (identical(btag, tree$tag)) {
			tree$base_sha <- tree$sha
		} else {
			if (!tree$local) {
				.cso_git_net(c("-C", shQuote(tree$dir), "fetch", "--quiet", "--depth", "1",
				               "origin", "tag", btag), 120)
			}
			bsha <- .cso_git_out(tree$dir, "rev-list", "-n", "1", paste0("refs/tags/", btag))
			if (length(bsha) && grepl("^[0-9a-f]{40}$", bsha[1])) tree$base_sha <- bsha[1]
		}
	}
	if (is.null(tree$base_sha) && is.character(base_commit) && length(base_commit) == 1 &&
	    grepl("^[0-9a-f]{40}$", base_commit)) {
		if (identical(.cso_git_out(tree$dir, "cat-file", "-t", base_commit), "commit")) {
			tree$base_sha <- base_commit
		}
	}
	.dw_dbg(fn, "base (pulled_version ", base %||% "<none>", "): ",
	        tree$base_sha %||% "not available; local edits cannot be told from upstream changes", d = d)
	tree
}

#' Bytes equal, ignoring CRLF vs LF
#' @keywords internal
#' @noRd
.cso_same <- function(a, b) {
	if (identical(a, b)) return(TRUE)
	lf <- function(x) {
		n <- length(x)
		if (n < 2) return(x)
		x[!(x == as.raw(13L) & c(x[-1], as.raw(0L)) == as.raw(10L))]
	}
	identical(lf(a), lf(b))
}

#' sha256 of raw bytes (hex), or NA when digest is not installed
#' @keywords internal
#' @noRd
.cso_sha256 <- function(x) {
	if (is.null(x) || !requireNamespace("digest", quietly = TRUE)) return(NA_character_)
	digest::digest(x, algo = "sha256", serialize = FALSE)
}

#' Compare every vendored file with the release tag
#'
#' @return List: `frame` (file, status, sha256_local, sha256_target) and
#'   `target` (named list of the tag's bytes, NULL where absent).
#' @keywords internal
#' @noRd
.cso_diff_core <- function(m, mdir, tree, fn) {
	files <- as.character(unlist(m$vendored))
	up <- vapply(files, .cso_upstream_path, character(1), fn = fn, files = files,
	             USE.NAMES = FALSE)
	edits <- as.character(unlist(m$local_edits))
	edits <- unique(c(edits, basename(edits)))
	target <- stats::setNames(vector("list", length(files)), files)
	status <- character(length(files))
	sl <- st <- rep(NA_character_, length(files))
	for (i in seq_along(files)) {
		f <- files[i]
		lp <- file.path(mdir, f)
		loc <- if (file.exists(lp)) .cso_bytes(lp) else NULL
		tgt <- .cso_git_blob(tree$dir, tree$sha, up[i])
		if (!is.null(tgt)) target[[i]] <- tgt
		sl[i] <- .cso_sha256(loc)
		st[i] <- .cso_sha256(tgt)
		status[i] <- if (is.null(tgt)) {
			"missing_upstream"
		} else if (is.null(loc)) {
			"missing_local"
		} else if (.cso_same(loc, tgt)) {
			"unchanged"
		} else if (f %in% edits) {
			"local_edit"
		} else if (!is.null(tree$base_sha) && {
			base <- .cso_git_blob(tree$dir, tree$base_sha, up[i])
			is.null(base) || !.cso_same(loc, base)
		}) {
			# The vendored copy is not what pulled_version shipped: edited here.
			"local_edit"
		} else {
			"changed"
		}
	}
	frame <- data.frame(file = files, status = status, sha256_local = sl, sha256_target = st,
	                    stringsAsFactors = FALSE)
	list(frame = frame, target = target)
}

#' Attach the release details to a diff frame
#' @keywords internal
#' @noRd
.cso_diff_attrs <- function(df, m, tree) {
	attr(df, "source") <- m$source
	attr(df, "pulled_version") <- m$pulled_version %||% NA_character_
	attr(df, "target_version") <- tree$tag
	attr(df, "target_commit") <- tree$sha
	df
}

.CSO_STATUSES <- c("changed", "local_edit", "missing_local", "missing_upstream", "unchanged")

#' One-paragraph summary of a diff
#' @keywords internal
#' @noRd
.cso_diff_report <- function(df, m, tree, mdir, fn, v) {
	if (!isTRUE(v)) return(invisible(NULL))
	n <- vapply(.CSO_STATUSES, function(s) sum(df$status == s), integer(1))
	head <- sprintf("[cso_toolkit.%s] %s %s (%s) vs vendored %s in %s: %d changed, %d local edit(s), %d missing locally, %d missing upstream, %d unchanged",
	                fn, m$source, tree$tag, substr(tree$sha, 1, 7), .cso_tag(m$pulled_version %||% "?"),
	                mdir, n[["changed"]], n[["local_edit"]], n[["missing_local"]],
	                n[["missing_upstream"]], n[["unchanged"]])
	rows <- df[df$status != "unchanged", , drop = FALSE]
	body <- if (nrow(rows)) sprintf("   %-17s %s", rows$status, rows$file) else character(0)
	message(paste(c(head, body), collapse = "\n"))
	invisible(NULL)
}

#' Show the differences between a vendored file and the tag's
#' @keywords internal
#' @noRd
.cso_show_diff <- function(local, target, f, tag) {
	d <- tempfile("cso_diff_")
	on.exit(unlink(d, recursive = TRUE, force = TRUE))
	dir.create(file.path(d, "vendored"), recursive = TRUE)
	dir.create(file.path(d, tag), recursive = TRUE)
	writeBin(local %||% raw(0), file.path(d, "vendored", f))
	writeBin(target %||% raw(0), file.path(d, tag, f))
	out <- suppressWarnings(system2("git", c("-C", shQuote(d), "diff", "--no-index", "--no-color",
	                                         "--", paste0("vendored/", f), paste0(tag, "/", f)),
	                                stdout = TRUE, stderr = TRUE))
	message(paste(out, collapse = "\n"))
	invisible(NULL)
}

#' Prompt and interactivity, separate so tests can replace them
#' @keywords internal
#' @noRd
.cso_ask <- function(prompt) readline(prompt)

#' @keywords internal
#' @noRd
.cso_interactive <- function() interactive()

#' Ask overwrite / skip / show diff for one file; TRUE = overwrite
#' @keywords internal
#' @noRd
.cso_confirm_file <- function(f, status, local, target, from, to) {
	what <- if (status == "missing_local") "is missing here" else "changed upstream"
	for (i in 1:10) {
		a <- tolower(trimws(.cso_ask(sprintf("%s %s (%s -> %s). [o]verwrite, [s]kip, show [d]iff? ",
		                                      f, what, from, to))))
		if (a %in% c("o", "overwrite", "y", "yes")) return(TRUE)
		if (a %in% c("s", "skip", "n", "no")) return(FALSE)
		if (a %in% c("d", "diff")) .cso_show_diff(local, target, f, to)
	}
	FALSE
}

#' Write bytes atomically: a temporary file in the same folder, then rename
#' @keywords internal
#' @noRd
.cso_write_atomic <- function(bytes, dest) {
	tmp <- file.path(dirname(dest), paste0(".", basename(dest), ".cso_tmp"))
	writeBin(bytes, tmp)
	if (!file.rename(tmp, dest)) {
		unlink(tmp)
		stop(sprintf("[cso_toolkit.cso_toolkit_pull] Could not replace %s.\n Fix: close any program holding the file open and run the pull again.", dest),
		     call. = FALSE)
	}
	invisible(dest)
}

#' Re-pin the manifest by editing its lines in place
#'
#' Sets `pulled_version`, `pulled_commit` (added after `pulled_version`),
#' the date key that exists (`pulled_date` or `pulled_at`; `pulled_date` is
#' added if neither), `pulled_by`, and the sha256 values of an existing
#' `files:` block. Every other line -- comments, `vendored`, `local_edits`,
#' `target_version`, unknown keys -- is left as it is, and so are the line
#' endings.
#' @param hashes Named character: file -> sha256 of the vendored bytes now.
#' @keywords internal
#' @noRd
.cso_manifest_update <- function(path, tag, sha, date, user, hashes = character(0)) {
	s <- rawToChar(.cso_bytes(path))
	eol <- if (grepl("\r\n", s, fixed = TRUE)) "\r\n" else "\n"
	ends <- grepl("\n$", s)
	lines <- strsplit(s, "\r?\n")[[1]]
	if (!length(lines)) lines <- character(0)

	set_key <- function(lines, key, value, after) {
		i <- grep(paste0("^", key, ":"), lines)
		new <- sprintf('%s: "%s"', key, value)
		if (length(i)) {
			i <- i[1]
			rest <- sub(paste0("^", key, ":[ \t]*"), "", lines[i])
			cm <- regmatches(rest, regexpr("[ \t]+#.*$", rest))
			lines[i] <- paste0(new, if (length(cm)) cm else "")
			return(list(lines = lines, at = i))
		}
		at <- if (length(after) && !is.na(after)) after else length(lines)
		list(lines = append(lines, new, after = at), at = at + 1L)
	}
	src_line <- grep("^source:", lines)[1]
	r <- set_key(lines, "pulled_version", tag, if (is.na(src_line)) 0L else src_line)
	r <- set_key(r$lines, "pulled_commit", sha, r$at)
	date_key <- if (length(grep("^pulled_date:", r$lines))) "pulled_date" else
		if (length(grep("^pulled_at:", r$lines))) "pulled_at" else "pulled_date"
	r <- set_key(r$lines, date_key, date, r$at)
	r <- set_key(r$lines, "pulled_by", user, r$at)
	lines <- r$lines

	# An existing `files:` block of per-file hashes (DW-Production keeps one).
	fb <- grep("^files:[ \t]*(#.*)?$", lines)
	if (length(fb) && length(hashes)) {
		i <- fb[1] + 1L
		while (i <= length(lines) && (grepl("^[ \t]", lines[i]) || !nzchar(trimws(lines[i])))) {
			key <- sub("^[ \t]+([^:]+?)[ \t]*:.*$", "\\1", lines[i], perl = TRUE)
			h <- hashes[key]
			if (!is.na(h) && grepl("[0-9a-f]{64}", lines[i])) {
				lines[i] <- sub("\"?[0-9a-f]{64}\"?", paste0("\"", h, "\""), lines[i])
			}
			i <- i + 1L
		}
	}
	out <- paste0(paste(lines, collapse = eol), if (ends) eol else "")
	.cso_write_atomic(charToRaw(out), path)
}

#' The NEWS.md sections after `from`, up to and including `to`
#'
#' Sections are `## vX.Y.Z ...` headings. Lines under a `###` heading that
#' names Breaking or Changed, and lines that say BREAKING, are flagged with
#' `!! `. `from` that is not a version (e.g. `inrepo`) gives `to`'s section
#' only.
#' @return List: `lines` (character, ready to print) and `flagged`
#'   (character, e.g. `"v0.10.0: ### Changed"`).
#' @keywords internal
#' @noRd
.cso_news_between <- function(text, from, to) {
	lines <- strsplit(text, "\r?\n")[[1]]
	h <- grep("^##[ \t]+v?[0-9]", lines)
	out <- character(0)
	flagged <- character(0)
	t <- .cso_version_norm(to)
	f <- .cso_version_norm(from)
	for (k in seq_along(h)) {
		ver <- .cso_version_norm(sub("^##[ \t]+(v?[0-9][^ \t(]*).*$", "\\1", lines[h[k]]))
		if (is.na(ver) || is.na(t)) next
		keep <- utils::compareVersion(ver, t) <= 0 &&
			(if (is.na(f)) utils::compareVersion(ver, t) == 0 else utils::compareVersion(ver, f) > 0)
		if (!keep) next
		end <- if (k < length(h)) h[k + 1] - 1L else length(lines)
		sec <- lines[h[k]:end]
		while (length(sec) && !nzchar(trimws(sec[length(sec)]))) sec <- sec[-length(sec)]
		flag <- FALSE
		for (j in seq_along(sec)) {
			ln <- sec[j]
			if (grepl("^#{1,3}[ \t]", ln) && !grepl("^###", ln)) {
				flag <- FALSE
			} else if (grepl("^###", ln)) {
				flag <- grepl("breaking|changed", ln, ignore.case = TRUE)
				if (flag) flagged <- c(flagged, sprintf("v%s: %s", ver, ln))
			}
			hit <- flag || grepl("BREAKING", ln, fixed = TRUE)
			if (!flag && grepl("BREAKING", ln, fixed = TRUE)) {
				flagged <- c(flagged, sprintf("v%s: %s", ver, substr(trimws(ln), 1, 70)))
			}
			sec[j] <- if (!nzchar(trimws(ln))) "" else paste0(if (hit) "!! " else "   ", ln)
		}
		out <- c(out, sec, "")
	}
	list(lines = out, flagged = flagged)
}

#' Is `dir` inside a git work tree with uncommitted changes under it?
#'
#' @return `NA` when `dir` is not in a git repository (or git is missing),
#'   else a character vector of `git status --porcelain` lines (empty when
#'   clean).
#' @keywords internal
#' @noRd
.cso_dirty <- function(dir) {
	if (!nzchar(Sys.which("git"))) return(NA)
	inside <- .cso_git_out(dir, "rev-parse", "--is-inside-work-tree")
	if (!identical(inside, "true")) return(NA)
	.cso_git_out(dir, "status", "--porcelain", "--", ".") %||% character(0)
}

#' Guards shared by diff, pull and sync: manifest and source
#' @keywords internal
#' @noRd
.cso_require_manifest <- function(fn) {
	m <- .cso_load_manifest()
	if (is.null(m)) {
		stop(sprintf(
			"[cso_toolkit.%s] No manifest; cannot refresh.\n Why: the manifest names the upstream and the vendored files.\n Looked under: %s\n Fix: create a .toolkit_manifest.yml next to the vendored helpers. See templates/.toolkit_manifest.yml for the schema.",
			fn, .cso_manifest_path()), call. = FALSE)
	}
	if (is.null(m$source) || !nzchar(m$source)) {
		stop(sprintf(
			"[cso_toolkit.%s] Manifest has no `source:` key.\n Why: the source names the repository to read the release from.\n Manifest path: %s\n Fix: add `source: \"owner/repo\"` to the manifest.",
			fn, .cso_manifest_path()), call. = FALSE)
	}
	m
}

#' Show per-file differences between the vendored copy and a release
#'
#' Compares every file listed under `vendored:` in `.toolkit_manifest.yml`
#' with the same file at a cso-toolkit release tag (`*.R` from `r/R/`,
#' `*.py` from `python/src/`) and prints a short summary. Nothing is
#' written.
#'
#' The tag is read from git history, never from a working tree: from the
#' local clone named by `toolkit_source` (or the `CSO_TOOLKIT_ROOT`
#' environment variable) with `git cat-file`, without fetching or changing
#' that clone; otherwise from a shallow clone of the tag from
#' `https://github.com/<source>.git` into a temporary folder, deleted on
#' exit (git over HTTPS works where proxies block api.github.com).
#'
#' Each file gets a status:
#' \describe{
#'   \item{`unchanged`}{The vendored bytes are the tag's (line endings
#'     aside).}
#'   \item{`changed`}{The tag has a different version and the vendored copy
#'     is what `pulled_version` shipped: [cso_toolkit_pull()] updates it.}
#'   \item{`local_edit`}{The file is listed under `local_edits:`, or it
#'     differs from what `pulled_version` shipped (edited here): the pull
#'     skips it.}
#'   \item{`missing_upstream`}{The tag has no such file: the pull keeps the
#'     vendored copy and warns.}
#'   \item{`missing_local`}{Listed under `vendored:` but not in the folder:
#'     the pull adds it.}
#' }
#' When the `pulled_version` tag cannot be read, a file that differs from
#' the target is reported as `changed` (a local edit cannot be detected).
#'
#' Reading from GitHub needs producer mode (`dw_apis_allowed`); with a
#' local `toolkit_source` the diff runs in reviewer mode too (no network).
#'
#' @param target_version Character or `NULL`. Release tag to compare with
#'   (e.g. `"v0.10.0"`; `"0.10.0"` gets a `v`). `NULL` (default) takes the
#'   latest release: of the local clone, or of GitHub (gh CLI, the API,
#'   then `git ls-remote`).
#' @param toolkit_source Character or `NULL`. A local git clone of
#'   cso-toolkit to read the tag from; `NULL` uses `CSO_TOOLKIT_ROOT`, and
#'   GitHub when that is unset too.
#' @param verbose Logical or `NULL`. Show high-level progress and result
#'   messages. `NULL` (default) inherits `getOption("dw.verbose", TRUE)`;
#'   set `TRUE`/`FALSE` to override for this call. See [dw_verbosity()].
#' @param debug Logical or `NULL`. Show internal troubleshooting detail
#'   (resolved paths, dims, branch decisions). `NULL` (default) inherits
#'   `getOption("dw.debug", FALSE)`; implies `verbose`. See [dw_verbosity()].
#'
#' @return Invisibly, a data frame with one row per vendored file: `file`,
#'   `status`, `sha256_local`, `sha256_target` (`NA` where the file is
#'   absent). Attributes `source`, `pulled_version`, `target_version` (the
#'   tag) and `target_commit` (its 40-hex commit). `NULL` when there is no
#'   manifest.
#'
#' @section Errors:
#' `[cso_toolkit.cso_toolkit_diff]` in reviewer mode without a local
#' `toolkit_source`; when the manifest has no `source:`; when the tag does
#' not exist or GitHub cannot be reached; for a vendored file that is
#' neither `.R` nor `.py`.
#'
#' @examples
#' \dontrun{
#' d <- cso_toolkit_diff()                          # latest release
#' d <- cso_toolkit_diff(target_version = "v0.10.0")
#' d[d$status != "unchanged", ]
#' cso_toolkit_diff(toolkit_source = "C:/GitHub/cso-toolkit")  # offline
#' }
#' @seealso [cso_toolkit_sync()], the one call that shows the release
#'   notes, this diff and then pulls; [cso_toolkit_pull()];
#'   [cso_toolkit_check()].
#' @family sync
#' @export
cso_toolkit_diff <- function(target_version = NULL, toolkit_source = NULL,
                             verbose = NULL, debug = NULL) {
	fn <- "cso_toolkit_diff"
	vd <- .dw_vd(verbose, debug); v <- vd$v; d <- vd$d
	m <- .cso_load_manifest()
	if (is.null(m)) return(invisible(NULL))
	local <- .cso_local_source(toolkit_source)
	if (is.null(local) && !isTRUE(.try_get("dw_apis_allowed"))) {
		stop(sprintf(
			"[cso_toolkit.%s] Forbidden in reviewer mode without a local clone.\n Why: reading a release from GitHub is a network call, which the reviewer-mode contract forbids.\n Fix: pass `toolkit_source = \"<a local cso-toolkit clone>\"` (read offline), or switch the profile to producer mode (dw_mode: producer in user_config.yml).",
			fn), call. = FALSE)
	}
	m <- .cso_require_manifest(fn)
	mdir <- dirname(.cso_manifest_path())
	tag <- .cso_target_tag(m, target_version, local, fn)
	.dw_msg(fn, "comparing ", mdir, " with ", m$source, " ", tag, v = v)
	tree <- .cso_upstream_tree(m$source, tag, local, fn, base = m$pulled_version,
	                           base_commit = m$pulled_commit, d = d)
	on.exit(tree$cleanup(), add = TRUE)
	res <- .cso_diff_core(m, mdir, tree, fn)
	df <- .cso_diff_attrs(res$frame, m, tree)
	.cso_diff_report(df, m, tree, mdir, fn, v)
	invisible(df)
}

#' Refresh the vendored copies to a cso-toolkit release
#'
#' Updates the files listed under `vendored:` in `.toolkit_manifest.yml` to
#' their versions at the release tag `target_version`, and re-pins the
#' manifest. [cso_toolkit_sync()] is the usual way in: it picks the latest
#' tag and shows its release notes first.
#'
#' In order:
#' \enumerate{
#'   \item Refuses in reviewer mode, without a manifest, or without a
#'     `source:` key.
#'   \item Refuses when the vendored folder has uncommitted changes (`git
#'     status --porcelain`, when it is inside a git repository): an update
#'     must be one reviewable commit. `dry_run = TRUE` skips this.
#'   \item Refuses a downgrade (a tag older than `pulled_version`) unless
#'     `allow_downgrade = TRUE`. The same tag reports "already at" and
#'     writes nothing; if the manifest's `pulled_commit` differs from the
#'     tag's commit it warns that the tag moved.
#'   \item Compares every file as [cso_toolkit_diff()] does (same sources:
#'     a local clone, or a shallow clone of the tag from GitHub).
#'     `local_edit` files are skipped and listed; `missing_upstream` files
#'     are kept, with a warning; `changed` and `missing_local` files are
#'     written atomically (a temporary file, then a rename).
#'   \item With `confirm = TRUE` it asks, per file, overwrite / skip / show
#'     diff. In a non-interactive session `confirm = TRUE` stops before
#'     writing anything; pass `confirm = FALSE` there.
#'   \item Re-pins the manifest by editing its lines in place (comments and
#'     unknown keys survive): `pulled_version`, `pulled_commit` (added after
#'     `pulled_version` if absent), the date key it already has
#'     (`pulled_date` or `pulled_at`; `pulled_date` if neither), `pulled_by`,
#'     and the hashes of an existing `files:` block. `vendored`,
#'     `local_edits` and `target_version` are never touched.
#' }
#'
#' @param target_version Character. Release tag to pull (e.g. `"v0.10.0"`;
#'   `"0.10.0"` gets a `v`).
#' @param confirm Logical. Ask per file (overwrite / skip / show diff).
#'   Default `TRUE`; needs an interactive session.
#' @param dry_run Logical. Report what would change; write nothing. Default
#'   `FALSE`.
#' @param toolkit_source Character or `NULL`. A local git clone of
#'   cso-toolkit to read the tag from (offline); `NULL` uses
#'   `CSO_TOOLKIT_ROOT`, and GitHub when that is unset too.
#' @param allow_downgrade Logical. Allow a tag older than `pulled_version`.
#'   Default `FALSE`.
#' @param verbose Logical or `NULL`. Show high-level progress and result
#'   messages. `NULL` (default) inherits `getOption("dw.verbose", TRUE)`;
#'   set `TRUE`/`FALSE` to override for this call. See [dw_verbosity()].
#' @param debug Logical or `NULL`. Show internal troubleshooting detail
#'   (resolved paths, dims, branch decisions). `NULL` (default) inherits
#'   `getOption("dw.debug", FALSE)`; implies `verbose`. See [dw_verbosity()].
#'
#' @return Invisibly, the [cso_toolkit_diff()] data frame with an `action`
#'   column: `updated`, `added`, `skipped` (declined at the prompt),
#'   `skipped_local_edit`, `kept` (missing upstream), `none` (unchanged or
#'   already at the tag), or, with `dry_run = TRUE`, `would_update` /
#'   `would_add`.
#'
#' @section Errors:
#' `[cso_toolkit.cso_toolkit_pull]` in reviewer mode; without a manifest
#' or `source:`; with uncommitted changes in the vendored folder; for a
#' downgrade without `allow_downgrade = TRUE`; for a tag that does not
#' exist (Fix: `git -C <clone> fetch --tags`, for a local clone); with
#' `confirm = TRUE` in a non-interactive session.
#'
#' @examples
#' \dontrun{
#' cso_toolkit_pull("v0.10.0", dry_run = TRUE)    # what would change
#' cso_toolkit_pull("v0.10.0")                    # asks per file
#' cso_toolkit_pull("v0.10.0", confirm = FALSE)   # scripts, Rscript
#' }
#' @seealso [cso_toolkit_sync()] (latest tag, release notes, diff, pull);
#'   [cso_toolkit_diff()]; [cso_toolkit_check()].
#' @family sync
#' @export
cso_toolkit_pull <- function(target_version,
                             confirm = TRUE,
                             dry_run = FALSE,
                             toolkit_source = NULL,
                             allow_downgrade = FALSE,
                             verbose = NULL,
                             debug = NULL) {
	if (missing(target_version)) target_version <- NULL
	.cso_pull_impl("cso_toolkit_pull", target_version, confirm, dry_run, toolkit_source,
	               allow_downgrade, verbose, debug, sync = FALSE)
}

#' Update the vendored cso-toolkit in one call
#'
#' The one call to keep a repository's vendored helpers current. It
#' \enumerate{
#'   \item resolves the target: `target_version`, or the latest release
#'     (of the local clone, or of GitHub);
#'   \item stops there, saying so, when `pulled_version` is already at (or
#'     past) it;
#'   \item prints the upstream `NEWS.md` (read from the target tag) for
#'     every version after `pulled_version` up to the target, marking with
#'     `!!` the entries under Breaking or Changed headings, which may need
#'     changes in your code;
#'   \item compares and pulls exactly as [cso_toolkit_pull()] does (the
#'     same guards, prompts, `dry_run` and manifest update), then prints
#'     the next steps.
#' }
#'
#' @inheritParams cso_toolkit_pull
#' @param target_version Character or `NULL`. Release tag to update to;
#'   `NULL` (default) takes the latest release.
#'
#' @return Invisibly, `NULL` when already up to date; otherwise the
#'   [cso_toolkit_pull()] data frame, with attribute `news` (the printed
#'   release-note lines).
#'
#' @section Errors:
#' `[cso_toolkit.cso_toolkit_sync]` in the same cases as
#' [cso_toolkit_pull()] (reviewer mode, no manifest, uncommitted changes,
#' a downgrade, a missing tag, `confirm = TRUE` in a non-interactive
#' session), and when the latest release cannot be found.
#'
#' @examples
#' \dontrun{
#' cso_toolkit_sync(dry_run = TRUE)   # release notes and diff, no writes
#' cso_toolkit_sync()                 # then update, asking per file
#' }
#' @seealso [cso_toolkit_check()] (am I behind?), [cso_toolkit_diff()],
#'   [cso_toolkit_pull()].
#' @family sync
#' @export
cso_toolkit_sync <- function(target_version = NULL,
                             confirm = TRUE,
                             dry_run = FALSE,
                             toolkit_source = NULL,
                             verbose = NULL,
                             debug = NULL) {
	.cso_pull_impl("cso_toolkit_sync", target_version, confirm, dry_run, toolkit_source,
	               allow_downgrade = FALSE, verbose, debug, sync = TRUE)
}

#' Shared body of cso_toolkit_pull() and cso_toolkit_sync()
#' @keywords internal
#' @noRd
.cso_pull_impl <- function(fn, target_version, confirm, dry_run, toolkit_source,
                           allow_downgrade, verbose, debug, sync) {
	vd <- .dw_vd(verbose, debug); v <- vd$v; d <- vd$d
	if (!isTRUE(.try_get("dw_apis_allowed"))) {
		stop(sprintf(
			"[cso_toolkit.%s] Forbidden in reviewer mode.\n Why: an update changes the vendored helpers and re-pins the manifest, a producer's decision (and reading a release from GitHub is a network call, which reviewer mode forbids).\n Fix: switch the profile to producer mode (set dw_mode: producer in user_config.yml) before re-running; to inspect only, use cso_toolkit_diff(toolkit_source = \"<a local clone>\").",
			fn), call. = FALSE)
	}
	m <- .cso_require_manifest(fn)
	mpath <- .cso_manifest_path()
	mdir <- dirname(mpath)
	local <- .cso_local_source(toolkit_source)
	if (!sync && is.null(target_version)) {
		stop(sprintf(
			"[cso_toolkit.%s] `target_version` is required.\n Why: a pull names the release it moves to.\n Fix: pass a tag, e.g. cso_toolkit_pull(\"v0.10.0\"), or run cso_toolkit_sync() to update to the latest release.",
			fn), call. = FALSE)
	}
	tag <- .cso_target_tag(m, target_version, local, fn)
	pinned <- m$pulled_version %||% NA_character_
	same <- !is.na(pinned) && identical(.cso_norm_tag(pinned), tag)
	.dw_dbg(fn, "manifest ", mpath, " | pulled_version=", pinned, " | target=", tag,
	        " | source=", if (is.null(local)) paste0("GitHub ", m$source) else local,
	        " | confirm=", confirm, " | dry_run=", dry_run, d = d)

	if (sync && (same || isFALSE(.cso_version_behind(pinned, tag)) && is.null(target_version))) {
		.dw_msg(fn, sprintf("up to date: vendored %s, %s %s", .cso_tag(pinned),
		                    if (is.null(target_version)) "latest release" else "target", tag), v = v)
		return(invisible(NULL))
	}
	if (isTRUE(.cso_version_behind(tag, pinned)) && !isTRUE(allow_downgrade)) {
		stop(sprintf(
			"[cso_toolkit.%s] %s is older than the vendored %s (pulled_version).\n Why: moving back to an older release is a downgrade, which is refused unless asked for.\n Fix: pass a tag at or after %s, or cso_toolkit_pull(\"%s\", allow_downgrade = TRUE) if you mean to go back.",
			fn, tag, .cso_tag(pinned), .cso_tag(pinned), tag), call. = FALSE)
	}
	if (!isTRUE(dry_run)) {
		dirty <- .cso_dirty(mdir)
		if (length(dirty) && !all(is.na(dirty))) {
			stop(sprintf(
				"[cso_toolkit.%s] %s has uncommitted changes:\n   %s\n Why: an update must be one reviewable commit, so it starts from a clean folder.\n Fix: commit or stash those changes first, then run it again (or use dry_run = TRUE to look).",
				fn, mdir, paste(utils::head(dirty, 10), collapse = "\n   ")), call. = FALSE)
		}
		if (isTRUE(is.na(dirty))) .dw_dbg(fn, mdir, " is not in a git repository: no uncommitted-change check", d = d)
	}

	tree <- .cso_upstream_tree(m$source, tag, local, fn, base = pinned,
	                           base_commit = m$pulled_commit, d = d)
	on.exit(tree$cleanup(), add = TRUE)

	news <- character(0)
	if (sync) {
		nb <- .cso_git_blob(tree$dir, tree$sha, "NEWS.md")
		if (is.null(nb)) {
			.dw_msg(fn, "no NEWS.md at ", tag, v = v)
		} else {
			nw <- .cso_news_between(rawToChar(nb), pinned, tag)
			news <- nw$lines
			if (isTRUE(v)) {
				head <- sprintf("[cso_toolkit.%s] release notes %s -> %s (NEWS.md at %s; !! = Breaking or Changed: read before updating)",
				                fn, .cso_tag(pinned), tag, tag)
				tail <- if (length(nw$flagged)) c("flagged:", paste0("   ", nw$flagged)) else "flagged: none"
				message(paste(c(head, "", news, tail), collapse = "\n"))
			}
		}
	}

	res <- .cso_diff_core(m, mdir, tree, fn)
	df <- .cso_diff_attrs(res$frame, m, tree)
	.cso_diff_report(df, m, tree, mdir, fn, v)
	df$action <- ifelse(df$status == "local_edit", "skipped_local_edit",
	             ifelse(df$status == "missing_upstream", "kept", "none"))

	if (same) {
		if (!is.null(m$pulled_commit) && !identical(m$pulled_commit, tree$sha)) {
			warning(sprintf(
				"[cso_toolkit.%s] Tag %s now points to %s, but the manifest records pulled_commit %s.\n Why: the tag was moved or re-created upstream after this repository vendored it.\n Fix: compare with cso_toolkit_diff(target_version = \"%s\") and ask the toolkit maintainers which commit is the release.",
				fn, tag, substr(tree$sha, 1, 7), substr(m$pulled_commit, 1, 7), tag), call. = FALSE)
		}
		.dw_msg(fn, "already at ", tag, ": nothing written", v = v)
		return(invisible(df))
	}

	todo <- which(df$status %in% c("changed", "missing_local"))
	if (length(todo) && !isTRUE(dry_run) && isTRUE(confirm) && !.cso_interactive()) {
		stop(sprintf(
			"[cso_toolkit.%s] confirm = TRUE needs an interactive session to ask per file, and this one is not.\n Why: %d file(s) would be overwritten without anyone choosing.\n Fix: run it again with confirm = FALSE (after cso_toolkit_diff() or dry_run = TRUE), or run it in an interactive R session.",
			fn, length(todo)), call. = FALSE)
	}
	for (i in todo) {
		f <- df$file[i]
		add <- df$status[i] == "missing_local"
		if (isTRUE(dry_run)) {
			df$action[i] <- if (add) "would_add" else "would_update"
			next
		}
		lp <- file.path(mdir, f)
		if (isTRUE(confirm)) {
			ok <- .cso_confirm_file(f, df$status[i], if (file.exists(lp)) .cso_bytes(lp) else NULL,
			                        res$target[[f]], .cso_tag(pinned), tag)
			if (!ok) {
				df$action[i] <- "skipped"
				next
			}
		}
		.cso_write_atomic(res$target[[f]], lp)
		df$action[i] <- if (add) "added" else "updated"
	}

	kept <- df$file[df$status == "missing_upstream"]
	if (length(kept)) {
		warning(sprintf(
			"[cso_toolkit.%s] Not in cso-toolkit %s, kept as vendored: %s\n Why: the release no longer has these files (removed or renamed upstream).\n Fix: read NEWS.md for %s; delete them and their `vendored:` entries if nothing uses them.",
			fn, tag, paste(kept, collapse = ", "), tag), call. = FALSE)
	}
	declined <- df$file[df$action == "skipped"]

	if (!isTRUE(dry_run)) {
		hashes <- vapply(df$file, function(f) {
			lp <- file.path(mdir, f)
			if (file.exists(lp)) .cso_sha256(.cso_bytes(lp)) else NA_character_
		}, character(1))
		hashes <- hashes[!is.na(hashes)]
		.cso_manifest_update(mpath, tag, tree$sha, format(Sys.Date(), "%Y-%m-%d"),
		                     .cso_user(), hashes)
	}

	if (isTRUE(v)) {
		lst <- function(a) {
			f <- df$file[df$action %in% a]
			sprintf("%d%s", length(f), if (length(f)) paste0(" (", paste(f, collapse = ", "), ")") else "")
		}
		if (isTRUE(dry_run)) {
			message(sprintf("[cso_toolkit.%s] dry run %s -> %s: would update %s, would add %s; skip %s local edit(s); keep %s missing upstream. Nothing written.",
			                fn, .cso_tag(pinned), tag, lst("would_update"), lst("would_add"),
			                lst("skipped_local_edit"), lst("kept")))
		} else {
			message(sprintf("[cso_toolkit.%s] %s -> %s (%s): updated %s, added %s; skipped %s local edit(s)%s; kept %s missing upstream; manifest re-pinned.",
			                fn, .cso_tag(pinned), tag, substr(tree$sha, 1, 7), lst("updated"), lst("added"),
			                lst("skipped_local_edit"),
			                if (length(declined)) paste0(", declined ", lst("skipped")) else "",
			                lst("kept")))
			if (length(declined)) {
				message(sprintf("[cso_toolkit.%s] declined files now differ from %s: list them under local_edits: in the manifest, or pull again.",
				                fn, tag))
			}
			message(sprintf("[cso_toolkit.%s] next: read NEWS, run tools/check.R and the tests, commit %s/ in one commit naming old and new tags (\"Update cso-toolkit %s -> %s\").",
			                fn, basename(mdir), .cso_tag(pinned), tag))
		}
	}
	if (sync) attr(df, "news") <- news
	invisible(df)
}

#' Check whether the vendored toolkit is behind a target or upstream
#'
#' Compares the version recorded in the consumer's
#' `.toolkit_manifest.yml` (`pulled_version`) with two references:
#'
#' \describe{
#'   \item{A target version}{The `target_version` argument, or else the
#'     manifest's optional `target_version:` key: the version a project
#'     has decided it must run on. The comparison is offline, so it runs in
#'     **both** producer and reviewer mode. When the vendored copy is
#'     behind the target, the check is loud: it raises a warning (error
#'     envelope) carrying the exact `cso_toolkit_sync(target_version = ...)`
#'     command and, with `quiet = FALSE`, prints a boxed alert. Reviewer
#'     mode only warns: it never polls GitHub or changes any file.}
#'   \item{The latest upstream tag}{Producer mode only (the mode contract
#'     forbids API calls in reviewer mode). The lookup tries the gh CLI,
#'     the GitHub API, then `git ls-remote --tags` over HTTPS (for networks
#'     that block api.github.com). A newer tag is informational: with
#'     `quiet = FALSE` it prints a boxed notice with the same commands, but
#'     it does not warn.}
#' }
#'
#' Versions are compared numerically (`0.10.0` is newer than `0.9.1`); a
#' `pulled_version` of `"inrepo"` is never reported as behind.
#'
#' Returns `NULL` (invisibly) when the manifest is missing, and in reviewer
#' mode when no target version is set (nothing can be checked offline).
#'
#' @param quiet Logical. If `TRUE` (default), print no messages and return
#'   the result invisibly. Being behind a target version still raises a
#'   warning, so a required re-vendor is never silent.
#' @param target_version Character or `NULL`. Tag the vendored copy must be
#'   at or above (e.g. `"v0.9.1"`). Overrides the manifest's
#'   `target_version:` key. `NULL` (default) uses the manifest key, if any.
#' @param verbose Logical or `NULL`. Show high-level progress and result
#'   messages. `NULL` (default) inherits `getOption("dw.verbose", TRUE)`;
#'   set `TRUE`/`FALSE` to override for this call. See [dw_verbosity()].
#' @param debug Logical or `NULL`. Show internal troubleshooting detail
#'   (resolved paths, dims, branch decisions). `NULL` (default) inherits
#'   `getOption("dw.debug", FALSE)`; implies `verbose`. See [dw_verbosity()].
#'
#' @return Invisibly, a named list with `source`, `pinned_version`,
#'   `upstream_version` (`NA` when not polled), `updates_available`
#'   (`NA` when not polled), `target_version`, `target_source`
#'   (`"argument"`, `"manifest"` or `NA`), `behind_target` (`NA` when there
#'   is no target), and `updated_files`; or `NULL` (see above).
#'
#' @section Warnings:
#' `[cso_toolkit.cso_toolkit_check]` when the vendored copy is behind the
#' target version, with the `cso_toolkit_sync()` command in its `Fix:`.
#'
#' @examples
#' \dontrun{
#' # in a profile: fail loudly (warning) if this repo runs below its target
#' cso_toolkit_check(quiet = FALSE)                      # manifest target_version
#' cso_toolkit_check(quiet = FALSE, target_version = "v0.9.1")
#'
#' res <- cso_toolkit_check(quiet = FALSE)
#' if (!is.null(res) && isTRUE(res$updates_available)) {
#'   cso_toolkit_sync()
#' }
#' }
#' @seealso [cso_toolkit_sync()] to update (release notes, diff, pull);
#'   [cso_toolkit_diff()] for per-file differences.
#' @family sync
#' @export
cso_toolkit_check <- function(quiet = TRUE, target_version = NULL,
                              verbose = NULL, debug = NULL) {
	vd <- .dw_vd(verbose, debug); v <- vd$v; d <- vd$d
	if (isTRUE(quiet)) { v <- FALSE; d <- FALSE }  # honour the quiet contract
	reviewer <- !isTRUE(.try_get("dw_apis_allowed"))

	m <- if (isTRUE(quiet)) suppressMessages(.cso_load_manifest()) else .cso_load_manifest()
	if (is.null(m)) return(invisible(NULL))

	pinned <- m$pulled_version %||% "0.0.0"
	target <- target_version %||% m$target_version
	target_source <- if (!is.null(target_version)) "argument" else
		if (!is.null(m$target_version)) "manifest" else NA_character_
	behind_target <- if (is.null(target)) NA else .cso_version_behind(pinned, target)
	.dw_dbg("cso_toolkit_check", "pinned=", pinned, " | target=", target %||% "<none>",
	        " (", target_source, ") | reviewer=", reviewer, d = d)

	res <- list(
		source            = m$source %||% NA_character_,
		pinned_version    = pinned,
		upstream_version  = NA_character_,
		updates_available = NA,
		target_version    = target %||% NA_character_,
		target_source     = target_source,
		behind_target     = behind_target,
		updated_files     = NULL  # see cso_toolkit_diff()
	)

	# --- Upstream poll (producer mode only) ----------------------------------
	if (reviewer) {
		if (!quiet) message("cso_toolkit_check: upstream poll skipped (reviewer mode forbids API calls)")
	} else if (is.null(m$source) || !nzchar(m$source)) {
		if (!quiet) message("cso_toolkit_check: manifest has no upstream source")
	} else {
		.dw_msg("cso_toolkit_check", "checking upstream '", m$source, "' for a newer tag", v = v)
		upstream <- tryCatch(.cso_upstream_latest_tag(m$source), error = function(e) NULL)
		if (is.null(upstream)) {
			if (!quiet) message(sprintf(
				"cso_toolkit_check: upstream '%s' not reachable or has no tags.", m$source))
		} else {
			res$upstream_version <- upstream
			res$updates_available <- isTRUE(.cso_version_behind(pinned, upstream))
		}
	}

	# --- Target: loud when behind (both modes; offline) ----------------------
	if (isTRUE(behind_target)) {
		tag <- .cso_tag(target)
		if (!quiet) {
			message(.cso_box(c(
				"cso-toolkit is BEHIND its target version",
				sprintf("  vendored : %s", .cso_tag(pinned)),
				sprintf("  target   : %s  (%s)", tag,
				        if (identical(target_source, "argument")) "target_version argument" else "manifest target_version"),
				if (!is.na(res$upstream_version)) sprintf("  latest   : %s  (upstream)", .cso_tag(res$upstream_version)),
				"",
				if (reviewer) "Producer mode is needed to update (reviewer mode only warns):" else "To update:",
				sprintf("  cso_toolkit_diff(target_version = \"%s\")", tag),
				sprintf("  cso_toolkit_sync(target_version = \"%s\")", tag)
			)))
		}
		warning(sprintf(
			"[cso_toolkit.cso_toolkit_check] The vendored cso-toolkit (%s) is behind its target version %s (from the %s).\n %s\n Fix: in producer mode, run cso_toolkit_sync(target_version = \"%s\"): it prints the release notes, then updates the vendored copy and re-pins the manifest. (Re-vendoring %s by hand also means updating pulled_version in .toolkit_manifest.yml.)",
			.cso_tag(pinned), tag,
			if (identical(target_source, "argument")) "target_version argument" else "manifest's target_version key",
			if (reviewer) "Reviewer mode: no network call was made and nothing was changed; ask the producer to re-vendor." else "Pipelines run on the older helpers until the re-vendor.",
			tag, tag), call. = FALSE)
	} else if (isTRUE(res$updates_available) && !quiet) {
		tag <- .cso_tag(res$upstream_version)
		message(.cso_box(c(
			"A newer cso-toolkit release is available",
			sprintf("  vendored : %s", .cso_tag(pinned)),
			sprintf("  latest   : %s  (%s)", tag, res$source),
			"",
			"To see the changes and update:",
			sprintf("  cso_toolkit_diff(target_version = \"%s\")", tag),
			sprintf("  cso_toolkit_sync(target_version = \"%s\")", tag)
		)))
	} else if (!quiet && !is.na(res$upstream_version)) {
		message(sprintf("[cso-toolkit] %s: vendored %s, latest upstream %s (up to date)",
		                res$source, .cso_tag(pinned), .cso_tag(res$upstream_version)))
	}

	# Reviewer mode with no target: nothing could be checked (as before).
	if (reviewer && is.null(target)) return(invisible(NULL))
	# Producer mode, upstream unreachable and no target: nothing to report (as before).
	if (!reviewer && is.na(res$upstream_version) && is.null(target)) return(invisible(NULL))
	invisible(res)
}
