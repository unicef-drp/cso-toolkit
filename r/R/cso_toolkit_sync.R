#-------------------------------------------------------------------
# 00_functions/cso_toolkit_sync.R
# Purpose: Vintage-management helpers for the vendored copies of
#          unicef-drp/cso-toolkit functions in this folder.
#
# Design (see 00_documentation/toolkit_strategy.md):
#   - Helpers in 00_functions/ are VENDORED COPIES of cso-toolkit code,
#     not sourced live. This pins the vintage per consuming repo.
#   - .toolkit_manifest.yml records the upstream version + per-file
#     hashes at pull time.
#   - cso_toolkit_check()  -- checks the vendored copy against a target version
#                             (offline; warns when behind) and, in producer
#                             mode, against the latest upstream tag (the
#                             poll respects dw_apis_allowed)
#   - cso_toolkit_diff()   -- shows what changed in upstream vs vendored copy
#   - cso_toolkit_pull()   -- refreshes the vendored files to a target tag,
#                            updates the manifest, prints the diff
#
# Until cso-toolkit is created, these helpers gracefully no-op:
#   - cso_toolkit_check() returns NULL when the upstream repo doesn't exist
#   - cso_toolkit_pull() refuses (loudly) to pull from a missing source
# This lets the vendoring scaffolding land now without blocking on the
# downstream repo creation.
#
# Line-ending convention (fixes #52):
#   - Manifests written by cso_toolkit_pull() hash the working-tree content
#     directly. To keep those sha256 entries stable across Windows / Linux /
#     macOS, the source tree pins LF endings via r/.gitattributes for *.R,
#     *.Rd, *.yml/*.yaml, *.md, NAMESPACE, and DESCRIPTION. After checkout,
#     the working tree is LF on every platform, so the working-tree hash
#     matches the Git blob hash.
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
#'     envelope) carrying the exact `cso_toolkit_pull(target_version = ...)`
#'     command and, with `quiet = FALSE`, prints a boxed alert. Reviewer
#'     mode only warns: it never polls GitHub or changes any file.}
#'   \item{The latest upstream tag}{Producer mode only (the mode contract
#'     forbids API calls in reviewer mode). A newer tag is informational:
#'     with `quiet = FALSE` it prints a boxed notice with the same commands,
#'     but it does not warn.}
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
#' target version, with the `cso_toolkit_pull()` command in its `Fix:`.
#'
#' @examples
#' \dontrun{
#' # in a profile: fail loudly (warning) if this repo runs below its target
#' cso_toolkit_check(quiet = FALSE)                      # manifest target_version
#' cso_toolkit_check(quiet = FALSE, target_version = "v0.9.1")
#'
#' res <- cso_toolkit_check(quiet = FALSE)
#' if (!is.null(res) && isTRUE(res$updates_available)) {
#'   cso_toolkit_diff()
#' }
#' }
#' @seealso [cso_toolkit_diff()] for per-file diffs;
#'   [cso_toolkit_pull()] for the refresh workflow.
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
		updated_files     = NULL  # populated by cso_toolkit_diff()
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
				sprintf("  cso_toolkit_pull(target_version = \"%s\")", tag)
			)))
		}
		warning(sprintf(
			"[cso_toolkit.cso_toolkit_check] The vendored cso-toolkit (%s) is behind its target version %s (from the %s).\n %s\n Fix: in producer mode, run cso_toolkit_pull(target_version = \"%s\") (or re-vendor %s by hand) and update pulled_version in .toolkit_manifest.yml.",
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
			sprintf("  cso_toolkit_pull(target_version = \"%s\")", tag)
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

#' Show per-file diff between vendored copy and upstream version
#'
#' Stub for v0.0.0. The implementation will fetch upstream files at the
#' target tag and compare via `digest::digest` + a textual diff if
#' requested.
#'
#' @param target_version Character. Optional explicit tag to diff against.
#'   Defaults to the latest upstream tag.
#' @param verbose Logical or `NULL`. Show high-level progress and result
#'   messages. `NULL` (default) inherits `getOption("dw.verbose", TRUE)`;
#'   set `TRUE`/`FALSE` to override for this call. See [dw_verbosity()].
#' @param debug Logical or `NULL`. Show internal troubleshooting detail
#'   (resolved paths, dims, branch decisions). `NULL` (default) inherits
#'   `getOption("dw.debug", FALSE)`; implies `verbose`. See [dw_verbosity()].
#'
#' @return Invisibly, `NULL` for the stub.
#'
#' @seealso [cso_toolkit_check()] (which surfaces when a diff is worth
#'   inspecting); [cso_toolkit_pull()] (executes the upgrade).
#' @family sync
#' @export
cso_toolkit_diff <- function(target_version = NULL, verbose = NULL, debug = NULL) {
	m <- .cso_load_manifest()
	if (is.null(m)) return(invisible(NULL))
	vd <- .dw_vd(verbose, debug); v <- vd$v; d <- vd$d
	.dw_msg("cso_toolkit_diff", "diffing vendored copies against upstream '", m$source %||% "<unset>", "'", v = v)
	.dw_dbg("cso_toolkit_diff", "source=", m$source %||% "<unset>", " | target_version=", target_version %||% "<latest>", d = d)
	message("cso_toolkit_diff: not yet implemented.\n",
	        "  Upstream repo (", m$source %||% "<unset>",
	        ") needs to exist before diff is meaningful.\n",
	        "  Once it does, this will fetch each file at the target tag\n",
	        "  and compare sha256 against the vendored copy.")
	invisible(NULL)
}

#' Refresh the vendored copies to a specific cso-toolkit tag
#'
#' Stub for v0.0.0. Planned behaviour:
#' \enumerate{
#'   \item Read `.toolkit_manifest.yml`.
#'   \item For each file in `m$files`: fetch it from `m$source` at
#'         `target_version`; compute sha256 against the current vendored
#'         copy; if different, prompt the user (overwrite / skip / show
#'         diff).
#'   \item Update the manifest with the new version + hashes.
#'   \item Log a summary.
#' }
#'
#' @param target_version Character. Tag to pull (e.g. `"v0.2.0"`).
#' @param confirm Logical. Prompt per file. Default `TRUE`.
#' @param dry_run Logical. Show what would change without writing. Default
#'   `FALSE`.
#' @param verbose Logical or `NULL`. Show high-level progress and result
#'   messages. `NULL` (default) inherits `getOption("dw.verbose", TRUE)`;
#'   set `TRUE`/`FALSE` to override for this call. See [dw_verbosity()].
#' @param debug Logical or `NULL`. Show internal troubleshooting detail
#'   (resolved paths, dims, branch decisions). `NULL` (default) inherits
#'   `getOption("dw.debug", FALSE)`; implies `verbose`. See [dw_verbosity()].
#'
#' @return Invisibly, `NULL` for the stub.
#'
#' @seealso [cso_toolkit_check()] to first determine whether a pull is
#'   needed; [cso_toolkit_diff()] to inspect per-file changes before
#'   overwriting.
#' @family sync
#' @export
cso_toolkit_pull <- function(target_version,
                             confirm = TRUE,
                             dry_run = FALSE,
                             verbose = NULL,
                             debug = NULL) {
	if (!isTRUE(.try_get("dw_apis_allowed"))) {
		stop("[cso_toolkit.cso_toolkit_pull] Forbidden in reviewer mode.\n  Reason: pulling a new toolkit version requires hitting GitHub, which the reviewer-mode contract forbids.\n  Fix: switch the profile to producer mode (set dw_mode: producer in user_config.yml) before re-running.",
		     call. = FALSE)
	}
	m <- .cso_load_manifest()
	if (is.null(m)) {
		stop(sprintf(
			"[cso_toolkit.cso_toolkit_pull] No manifest; cannot refresh.\n  Looked under: %s\n  Fix: create a .toolkit_manifest.yml next to the vendored helpers. See templates/.toolkit_manifest.yml for the schema.",
			.cso_manifest_path()
		), call. = FALSE)
	}
	if (is.null(m$source)) {
		stop(sprintf(
			"[cso_toolkit.cso_toolkit_pull] Manifest has no `source:` key.\n  Manifest path: %s\n  Fix: add `source: \"owner/repo\"` to the manifest.",
			.cso_manifest_path()
		), call. = FALSE)
	}

	# Stub: refuse if the upstream isn't real yet
	upstream_check <- tryCatch(.cso_upstream_latest_tag(m$source),
	                           error = function(e) NULL)
	if (is.null(upstream_check)) {
		stop("[cso_toolkit.cso_toolkit_pull] Upstream '", m$source, "' not reachable or has no tags.\n",
		     "  Possible causes:\n    - The repo doesn't exist yet.\n    - The network is blocked (UNICEF corporate proxies sometimes block api.github.com).\n    - Neither `gh` CLI nor `httr` is available.\n",
		     "  Fix: verify the repo exists, then `gh auth status` or install.packages('httr').",
		     call. = FALSE)
	}

	vd <- .dw_vd(verbose, debug); v <- vd$v; d <- vd$d
	.dw_msg("cso_toolkit_pull", "refreshing vendored copies from '", m$source, "' to ", target_version, v = v)
	.dw_dbg("cso_toolkit_pull", "source=", m$source, " | target_version=", target_version, " | confirm=", confirm, " | dry_run=", dry_run, d = d)
	.dw_dbg("cso_toolkit_pull", "upstream latest tag resolved to ", upstream_check, d = d)
	message("cso_toolkit_pull: implementation TBD when cso-toolkit exists.\n",
	        "  Target version: ", target_version, "\n",
	        "  dry_run: ", dry_run, "\n",
	        "  This will fetch files, prompt per-file overwrite, update manifest.")
	invisible(NULL)
}

#' Look up the latest tag at the upstream repo
#'
#' Internal. Tries `gh api repos/<source>/releases/latest --jq .tag_name`
#' first (no auth flicker when `gh auth status` is good); falls back to
#' `httr::GET` on `api.github.com` when `gh` is missing. Returns `NULL`
#' when both paths fail (unreachable network, repo absent, no releases).
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
			return(body$tag_name)
		}
	}
	NULL
}
