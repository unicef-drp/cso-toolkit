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
#   - cso_toolkit_check()  -- quietly checks if upstream has a newer tag
#                            (producer mode only; respects dw_apis_allowed)
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

#' Check if a newer cso-toolkit version is available upstream
#'
#' Quiet by default: returns a list describing the state and prints nothing.
#' Pass `quiet = FALSE` to log the result.
#'
#' Returns `NULL` (invisibly) when any of the following apply:
#' \itemize{
#'   \item Manifest is missing.
#'   \item Upstream repo does not exist (e.g., the toolkit has not been
#'         created yet).
#'   \item Network is unavailable.
#'   \item We're in reviewer mode (the mode contract forbids API calls).
#' }
#'
#' @param quiet Logical. If `TRUE` (default), suppress all `message()`
#'   output and just return the result list invisibly.
#' @param verbose Logical or `NULL`. Show high-level progress and result
#'   messages. `NULL` (default) inherits `getOption("dw.verbose", TRUE)`;
#'   set `TRUE`/`FALSE` to override for this call. See [dw_verbosity()].
#' @param debug Logical or `NULL`. Show internal troubleshooting detail
#'   (resolved paths, dims, branch decisions). `NULL` (default) inherits
#'   `getOption("dw.debug", FALSE)`; implies `verbose`. See [dw_verbosity()].
#'
#' @return Invisibly, a named list with `source`, `pinned_version`,
#'   `upstream_version`, `updates_available`, `updated_files`, or `NULL`.
#'
#' @examples
#' \dontrun{
#' res <- cso_toolkit_check(quiet = FALSE)
#' if (!is.null(res) && isTRUE(res$updates_available)) {
#'   cso_toolkit_diff()
#' }
#' }
#' @seealso [cso_toolkit_diff()] for per-file diffs;
#'   [cso_toolkit_pull()] for the refresh workflow.
#' @family sync
#' @param verbose Logical or `NULL`. Show high-level progress and result
#'   messages. `NULL` (default) inherits `getOption("dw.verbose", TRUE)`;
#'   set `TRUE`/`FALSE` to override for this call. See [dw_verbosity()].
#' @param debug Logical or `NULL`. Show internal troubleshooting detail.
#'   `NULL` (default) inherits `getOption("dw.debug", FALSE)`; implies
#'   `verbose`. See [dw_verbosity()].
#' @export
cso_toolkit_check <- function(quiet = TRUE, verbose = NULL, debug = NULL) {
	# Mode contract: reviewers don't poll GitHub
	if (!isTRUE(.try_get("dw_apis_allowed"))) {
		if (!quiet) message("cso_toolkit_check: skipped (reviewer mode forbids API calls)")
		return(invisible(NULL))
	}

	m <- .cso_load_manifest()
	if (is.null(m)) return(invisible(NULL))

	if (is.null(m$source) || !nzchar(m$source)) {
		if (!quiet) message("cso_toolkit_check: manifest has no upstream source")
		return(invisible(NULL))
	}

	vd <- .dw_vd(verbose, debug); v <- vd$v; d <- vd$d
	.dw_msg("cso_toolkit_check", "checking upstream '", m$source, "' for a newer tag", v = v)
	.dw_dbg("cso_toolkit_check", "manifest source=", m$source, " | pinned=", m$pulled_version %||% "0.0.0", d = d)

	.dw_dbg("cso_toolkit_check", "querying upstream latest tag via .cso_upstream_latest_tag()", d = d)
	upstream <- tryCatch(.cso_upstream_latest_tag(m$source),
	                     error = function(e) NULL)
	if (is.null(upstream)) {
		if (!quiet) message(sprintf(
			"cso_toolkit_check: upstream '%s' not reachable or has no tags.\n",
			m$source))
		return(invisible(NULL))
	}

	pinned <- m$pulled_version %||% "0.0.0"
	# Crude version compare: just lexical on tag strings stripped of leading "v"
	pinned_norm <- sub("^v", "", pinned)
	upstream_norm <- sub("^v", "", upstream)

	res <- list(
		source            = m$source,
		pinned_version    = pinned,
		upstream_version  = upstream,
		updates_available = !identical(pinned_norm, upstream_norm) &&
		                    !grepl("inrepo", pinned, fixed = TRUE),
		updated_files     = NULL  # populated by cso_toolkit_diff()
	)

	if (!quiet) {
		if (res$updates_available) {
			message(sprintf(
				"\033[33m[cso-toolkit] %s: pinned v%s -> upstream %s (newer tag available)\033[0m",
				m$source, pinned, upstream))
			message("              Run cso_toolkit_diff() to see what changed.")
			message("              Run cso_toolkit_pull('", upstream, "') to refresh.")
		} else {
			message(sprintf(
				"[cso-toolkit] %s: pinned %s == upstream %s (up to date)",
				m$source, pinned, upstream))
		}
	}
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
#' @param verbose Logical or `NULL`. Show high-level progress and result
#'   messages. `NULL` (default) inherits `getOption("dw.verbose", TRUE)`;
#'   set `TRUE`/`FALSE` to override for this call. See [dw_verbosity()].
#' @param debug Logical or `NULL`. Show internal troubleshooting detail.
#'   `NULL` (default) inherits `getOption("dw.debug", FALSE)`; implies
#'   `verbose`. See [dw_verbosity()].
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
#' @param verbose Logical or `NULL`. Show high-level progress and result
#'   messages. `NULL` (default) inherits `getOption("dw.verbose", TRUE)`;
#'   set `TRUE`/`FALSE` to override for this call. See [dw_verbosity()].
#' @param debug Logical or `NULL`. Show internal troubleshooting detail.
#'   `NULL` (default) inherits `getOption("dw.debug", FALSE)`; implies
#'   `verbose`. See [dw_verbosity()].
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
