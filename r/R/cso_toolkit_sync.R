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
#   - cso_toolkit_check()  — quietly checks if upstream has a newer tag
#                            (producer mode only; respects dw_apis_allowed)
#   - cso_toolkit_diff()   — shows what changed in upstream vs vendored copy
#   - cso_toolkit_pull()   — refreshes the vendored files to a target tag,
#                            updates the manifest, prints the diff
#
# Until cso-toolkit is created, these helpers gracefully no-op:
#   - cso_toolkit_check() returns NULL when the upstream repo doesn't exist
#   - cso_toolkit_pull() refuses (loudly) to pull from a missing source
# This lets the vendoring scaffolding land now without blocking on the
# downstream repo creation.
#-------------------------------------------------------------------

.cso_manifest_path <- function() {
	# Manifest lives next to the helpers it tracks.
	root <- if (exists("dwFunct")) dwFunct else file.path(getwd(), "00_functions")
	file.path(root, ".toolkit_manifest.yml")
}

.cso_load_manifest <- function() {
	if (!requireNamespace("yaml", quietly = TRUE)) {
		warning("cso_toolkit_sync: yaml package not installed; skipping checks")
		return(NULL)
	}
	mpath <- .cso_manifest_path()
	if (!file.exists(mpath)) {
		message("cso_toolkit_sync: no manifest at ", mpath,
		        " — helpers are not vendored from any upstream.")
		return(NULL)
	}
	yaml::read_yaml(mpath)
}

#' Check if a newer cso-toolkit version is available upstream.
#'
#' Quiet by default: returns a list describing the state, prints nothing.
#' Pass `quiet = FALSE` to log the result.
#'
#' Returns NULL when:
#'   - manifest missing
#'   - upstream repo doesn't exist (e.g., cso-toolkit hasn't been created yet)
#'   - network not available
#'   - we're in reviewer mode (the mode contract forbids API calls)
cso_toolkit_check <- function(quiet = TRUE) {
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

#' Show per-file diff between vendored copy and upstream version.
#' Stub for v0.0.0; the implementation will fetch upstream files and
#' compare via digest::digest + a textual diff if requested.
cso_toolkit_diff <- function(target_version = NULL) {
	m <- .cso_load_manifest()
	if (is.null(m)) return(invisible(NULL))
	message("cso_toolkit_diff: not yet implemented.\n",
	        "  Upstream repo (", m$source %||% "<unset>",
	        ") needs to exist before diff is meaningful.\n",
	        "  Once it does, this will fetch each file at the target tag\n",
	        "  and compare sha256 against the vendored copy.")
	invisible(NULL)
}

#' Refresh the vendored copies to a specific cso-toolkit tag.
#' Stub for v0.0.0. Behaviour (when implemented):
#'   1. Read .toolkit_manifest.yml
#'   2. For each file in `m$files`:
#'      a. Fetch the file from `m$source` at `target_version`
#'      b. Compute sha256 of new vs current vendored copy
#'      c. If different, prompt user (overwrite | skip | show-diff)
#'   3. Update manifest with new version + hashes
#'   4. Log a summary
cso_toolkit_pull <- function(target_version,
                             confirm = TRUE,
                             dry_run = FALSE) {
	if (!isTRUE(.try_get("dw_apis_allowed"))) {
		stop("cso_toolkit_pull: forbidden in reviewer mode. Switch to producer mode.")
	}
	m <- .cso_load_manifest()
	if (is.null(m)) stop("cso_toolkit_pull: no manifest; cannot refresh")
	if (is.null(m$source)) stop("cso_toolkit_pull: manifest has no upstream source")

	# Stub: refuse if the upstream isn't real yet
	upstream_check <- tryCatch(.cso_upstream_latest_tag(m$source),
	                           error = function(e) NULL)
	if (is.null(upstream_check)) {
		stop("cso_toolkit_pull: upstream '", m$source, "' not reachable or has no tags.\n",
		     "  Likely cause: cso-toolkit repo doesn't exist yet.\n",
		     "  Phase-2 work: create the repo + tag v0.1.0, then re-run.")
	}

	message("cso_toolkit_pull: implementation TBD when cso-toolkit exists.\n",
	        "  Target version: ", target_version, "\n",
	        "  dry_run: ", dry_run, "\n",
	        "  This will fetch files, prompt per-file overwrite, update manifest.")
	invisible(NULL)
}

#' Internal: look up the latest tag at the upstream repo via gh CLI.
#' Returns the tag string (e.g., "v0.1.0") or NULL if unreachable.
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
