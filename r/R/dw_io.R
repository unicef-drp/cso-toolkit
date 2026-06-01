#-------------------------------------------------------------------
# 00_functions/dw_io.R
# Toolkit version: 0.4.7
# Purpose: Uniform read/write helpers for DW-Production R scripts.
# Auto-dispatch by file extension; supports every IO form the
# sector scripts currently use; enforces the reviewer/producer
# contract for writes; mirrors canonical writes to Z: AND
# Teams ( >= 1 required in producer mode); reviewer reads are
# network-first to prevent stale-local-cache provenance gaps.
#
# Mode is a SESSION property only -- set by `dw_mode` in
# ~/.config/user_config.yml and read by profile_DW-Production.R. It is
# NOT a per-call argument on dw_save/dw_use. Path globals (teamsWrkData,
# teamsRawData, dwWrkData, etc.) are already mode-aware in the profile;
# the helpers below resolve through them.
#
# Public entry points:
# dw_save(x, path|name, ..., isid = NULL, metadata = NULL,
# overwrite = FALSE) # <- default flipped in v0.4.0
# dw_use(path|name, ..., as = "tibble")
# dw_compare(current, reference, by, value_cols, ...)
# dw_resolve_path(name, sector, kind, vintage)
# dw_is_canonical(path)
# dw_verify_z(path, compare = "size" | "sha256")
# dw_merge(x, using, by, how)
# dw_toolkit_version() # <- new in v0.4.0
#
# Added: 2026-05-23 (reviewer-mode audit).
# v0.4.0 (2026-05-26): mode-contract tightening per issue #14 -- 
# producer dw_save writes to Z: + Teams ( >= 1 required); reviewer
# dw_use reads network-first; overwrite default flipped to FALSE.
#
# Auto-sourced by the profile via `dwFunct`; no per-script source()
# needed.
#-------------------------------------------------------------------

# ============================================================================
# Helpers
# ============================================================================

#' Null/NA coalescing operator
#'
#' Returns `b` when `a` is `NULL` or a length-1 `NA`; otherwise returns `a`.
#'
#' @param a Value to test.
#' @param b Fallback returned when `a` is `NULL` or scalar `NA`.
#'
#' @return Either `a` or `b`.
#'
#' @keywords internal
#' @noRd
`%||%` <- function(a, b) if (is.null(a) || (length(a) == 1 && is.na(a))) b else a

#' Ensure an optional package is installed
#'
#' Wrapper around `requireNamespace()` that emits a uniform install hint when
#' the package is missing. Internal helper used by every format-specific
#' branch of [dw_save()] / [dw_use()].
#'
#' @param pkg Character. Package name.
#'
#' @return Invisibly, `TRUE`. Stops if the package is not installed.
#'
#' @keywords internal
#' @noRd
.require <- function(pkg) {
	if (!requireNamespace(pkg, quietly = TRUE)) {
		stop(sprintf(
			"[cso_toolkit.dw_io] Package '%s' is required for this file format but is not installed.\n Fix: install.packages('%s')",
			pkg, pkg
		), call. = FALSE)
	}
	invisible(TRUE)
}

#' Look up a global variable, falling back to `NA_character_`
#'
#' Safe accessor for session-level globals set by `profile_DW-Production.R`
#' (e.g. `teamsWrkData`, `dw_mode`, `dwZDrive`). Returns `NA_character_`
#' when the global is not defined, so downstream code can branch on
#' `is.na(...)` without wrapping every read in `tryCatch`.
#'
#' @param name Character. Name of the global to read from `.GlobalEnv`.
#'
#' @return The value bound to `name` in `.GlobalEnv`, or `NA_character_`
#' if it is not bound.
#'
#' @keywords internal
#' @noRd
.try_get <- function(name) tryCatch(get(name, envir = .GlobalEnv),
 error = function(e) NA_character_)

#' Filesystem root for a given data kind
#'
#' Reads the session-level globals that `profile_DW-Production.R` exports
#' (already mode-aware). Internal -- callers should use [dw_resolve_path()].
#'
#' @param kind Character. One of `"wrk"`, `"raw"`, or `"meta"`.
#'
#' @return Character path to the root directory, or `NA_character_` if the
#' relevant global is not defined.
#'
#' @keywords internal
#' @noRd
.dw_root_for <- function(kind = c("wrk", "raw", "meta")) {
	kind <- match.arg(kind)
	switch(kind,
		wrk = .try_get("teamsWrkData"),
		raw = .try_get("teamsRawData"),
		meta = .try_get("dwMetaData")
	)
}

#' Resolve the mode-aware repo / canonical root for a vendored kind
#'
#' Public wrapper around the internal `.dw_root_for()`. Sector scripts use
#' this to build paths like `file.path(dw_root("wrk"), "<sector>", "<vintage>")`
#' without needing to know whether the session is producer or reviewer mode.
#'
#' @param kind One of "wrk", "raw", "meta" — selects which of the three
#'   vendored data roots to return.
#' @return Character. Absolute path to the resolved root.
#' @seealso `.dw_root_for()` (internal helper, not exported);
#'   [dw_resolve_path()] for the full sector/vintage/name path.
#' @family io
#' @export
dw_root <- function(kind = c("wrk", "raw", "meta")) .dw_root_for(kind)

# ============================================================================
# Path resolution
# ============================================================================

#' Resolve a logical DW path to a filesystem path
#'
#' Two call styles are supported:
#' \itemize{
#' \item Path-string: `dw_resolve_path(path = "ed/dw_ed_edu.csv", kind = "wrk")`
#' \item Structured: `dw_resolve_path(name = "dw_ed_edu.csv", sector = "ed", kind = "wrk")`
#' }
#'
#' @param path Character. Literal subpath to append to the kind's root.
#' Mutually exclusive with `name` / `sector` / `vintage`.
#' @param name Character. File basename. Used together with `sector` and
#' optionally `vintage` to build the subpath.
#' @param sector Character. Sector folder name (e.g. `"ed"`, `"nt"`). Only
#' used when `name` is supplied.
#' @param kind Character. One of `"wrk"`, `"raw"`, `"meta"`. Selects which
#' profile-defined root to resolve against.
#' @param vintage Character. Optional subfolder (e.g. `"2026-05"` or
#' `"2026-05-23"`) inserted between `sector` and `name`.
#'
#' @return Character. Absolute filesystem path.
#'
#' @examples
#' \dontrun{
#' dw_resolve_path(name = "dw_ed_edu.csv", sector = "ed", kind = "wrk")
#' dw_resolve_path(path = "ed/dw_ed_edu.csv", kind = "wrk")
#' }
#' @seealso [dw_is_canonical()] to test whether a resolved path lies under
#' a canonical root; [dw_save()] and [dw_use()] which call this helper
#' internally.
#' @family io
#' @export
dw_resolve_path <- function(path = NULL, name = NULL, sector = NULL,
 kind = c("wrk", "raw", "meta"),
 vintage = NULL) {
	kind <- match.arg(kind)
	root <- .dw_root_for(kind = kind)
	if (is.na(root) || !nzchar(root)) {
		global_name <- switch(kind, wrk = "teamsWrkData",
		 raw = "teamsRawData",
		 meta = "dwMetaData")
		stop(sprintf(
			"[cso_toolkit.dw_resolve_path] %s global is not set.\n This usually means profile_<repo>.R has not been sourced yet.\n Fix: source('profile_<repo>.R') before calling dw_resolve_path(), or set %s <- '/path/to/%s' explicitly.",
			global_name, global_name, kind
		), call. = FALSE)
	}
	subpath <- if (!is.null(name)) {
		file.path(sector %||% "", if (!is.null(vintage)) vintage else "", name)
	} else if (!is.null(path)) {
		path
	} else {
		stop("[cso_toolkit.dw_resolve_path] Neither `path` nor `name` supplied.\n At least one is required to build a filesystem path.\n Fix: pass path = 'sector/file.csv' OR name = 'file.csv' + sector = '...'.",
		 call. = FALSE)
	}
	subpath <- gsub("/+", "/", subpath)
	subpath <- sub("^/", "", subpath)
	file.path(root, subpath)
}

#' Normalise a path for descendant comparison
#'
#' Internal. Resolves short 8.3 names to long names by normalising the
#' nearest *existing* parent directory and reattaching the missing
#' suffix. Without this, on Windows `normalizePath("/tmp/JPAZEV~1/file.csv")`
#' returns the SHORT name when `file.csv` doesn't exist but the LONG
#' name (e.g. `jpazevedo`) when it does -- making prefix comparisons
#' silently wrong.
#'
#' @keywords internal
#' @noRd
.normalize_for_comparison <- function(p) {
	if (length(p) == 0 || is.na(p) || !nzchar(p)) return(NA_character_)
	if (file.exists(p)) {
		return(normalizePath(p, winslash = "/", mustWork = FALSE))
	}
	# Walk up to the first existing ancestor.
	parent <- dirname(p)
	tail <- basename(p)
	while (!file.exists(parent) && parent != dirname(parent)) {
		tail <- file.path(basename(parent), tail)
		parent <- dirname(parent)
	}
	parent_n <- normalizePath(parent, winslash = "/", mustWork = FALSE)
	file.path(parent_n, tail)
}

#' Test whether a path lives under a canonical deposit root
#'
#' Checks whether `path` is a descendant of any of the profile-defined
#' canonical roots (`teamsWrkDataCanonical`, `teamsRawDataCanonical`,
#' `teamsFolderCanonical`). Used by [dw_save()] to gate reviewer-mode writes
#' and by [dw_use()] to decide whether to run a Z: integrity check.
#'
#' @param path Character. Filesystem path to test (need not exist).
#'
#' @return Logical. `TRUE` if `path` lies under a canonical root, otherwise
#' `FALSE`.
#'
#' @seealso [dw_resolve_path()], [dw_verify_z()].
#' @family io
#' @export
dw_is_canonical <- function(path) {
	path_n <- .normalize_for_comparison(path)

	# OneDrive-mounted Teams Documents pattern: catches the per-user OneDrive
	# path that mirrors the Teams "060.DW-MASTER" Documents library. Pattern:
	#   <user-profile>/<org>/<library> - Documents/060.DW-MASTER/...
	# The earlier teamsFolder-prefix check misses this when the consumer's
	# profile sets teamsFolder via a different path (e.g., a Z: mirror).
	# Backslash variants (raw Windows paths) are normalised to forward
	# slashes first so the same regex catches both forms. Triggered #54:
	# HVA + ED reviewer-mode runs overwrote canonical Teams artifacts
	# because mode-lock missed this UNC pattern.
	onedrive_pattern <- "/UNICEF/[^/]+ - Documents/060\\.DW-MASTER/"
	if (!is.na(path_n) &&
	    grepl(onedrive_pattern, gsub("\\\\", "/", path_n), perl = TRUE)) {
		return(TRUE)
	}

	canon_roots <- c(
		.try_get("teamsWrkDataCanonical"),
		.try_get("teamsRawDataCanonical"),
		.try_get("teamsFolderCanonical")
	)
	canon_roots <- canon_roots[!is.na(canon_roots) & nzchar(canon_roots)]
	if (length(canon_roots) == 0) return(FALSE)
	canon_n <- vapply(canon_roots, .normalize_for_comparison, character(1))
	# Path-aware descendant check: a plain `startsWith` would match
	# `/data/wrk-canary/...` against root `/data/wrk-can` (Copilot
	# finding on Python PR #7; same bug existed here). Strip any
	# trailing slash from each root and require equality OR
	# `root + "/"` prefix so siblings cannot spoof a match.
	canon_n <- sub("/+$", "", canon_n)
	for (root in canon_n) {
		if (identical(path_n, root) || startsWith(path_n, paste0(root, "/"))) {
			return(TRUE)
		}
	}
	FALSE
}

# ============================================================================
# Toolkit version stamp
# ============================================================================

#' Toolkit version that this `dw_io.R` was vendored from
#'
#' Returns the upstream `cso-toolkit` tag the current `dw_io.R` /
#' `dw_api.R` / `cso_toolkit_sync.R` triplet was lifted from. Sector
#' scripts use this to assert a minimum vendored version before they
#' rely on a v0.4.0+ contract (e.g. network-first reviewer reads,
#' mirror-to-both producer writes).
#'
#' @return Character. Currently `"0.4.7"`.
#'
#' @examples
#' if (utils::compareVersion(dw_toolkit_version(), "0.4.0") < 0) {
#' stop("This script requires cso-toolkit >= 0.4.0; ",
#' "found ", dw_toolkit_version(), ". Run cso_toolkit_pull('v0.4.0').")
#' }
#'
#' @seealso [cso_toolkit_check()] for upstream drift detection.
#' @family io
#' @export
dw_toolkit_version <- function() {
	"0.4.7"
}

# ============================================================================
# Z: drive + Teams remote mirrors (producer-mode redundant writes,
# integrity check on reads)
# ============================================================================

#' Map a primary (repo-local sandbox) write path to its Teams + Z: equivalents
#'
#' Internal. Walks `teamsWrkData` / `teamsRawData` prefix matches to
#' derive the Teams canonical equivalent. The Z: equivalent is
#' derived from the Teams canonical via [.dw_z_mirror_path()] so the
#' Z: drive layout mirrors the Teams canonical layout (as it does in
#' DW-Production).
#'
#' Returns a named list with `teams` (Teams canonical path or
#' `NA_character_`) and `z` (Z: drive path or `NA_character_`). Any
#' destination not configured in the profile (or unavailable, in the
#' Z: case) resolves to NA.
#'
#' @keywords internal
#' @noRd
.dw_remote_mirrors <- function(primary_path) {
	pn <- .normalize_for_comparison(primary_path)

	# Canonical primary -> primary write IS the canonical Teams artifact;
	# only Z: needs a separate mirror (matches Python `_dw_remote_mirrors`).
	# This is the DBM-bootstrap path: when a producer writes directly
	# under `teamsFolderCanonical`, the v0.4.0 redundant-write contract
	# still applies via the Z: mirror.
	#
	# teams is returned as NA (not the primary path itself) so the
	# producer-mode mirror code in dw_save() does NOT try to file.copy()
	# the primary onto itself. The pre-#26 implementation returned
	# `teams = pn`, which on Windows produced a "file.copy() onto self"
	# warning that .dw_mirror_to_teams caught and re-emitted as
	# "[cso_toolkit.dw_save] Teams mirror FAILED" — false alarm on every
	# canonical-direct write.
	if (dw_is_canonical(pn)) {
		z_mirror <- .dw_z_mirror_path(pn)
		if (is.null(z_mirror)) z_mirror <- NA_character_
		return(list(teams = NA_character_, z = z_mirror))
	}

	candidates <- list(
		list(local = .try_get("teamsWrkData"),
		 canonical = .try_get("teamsWrkDataCanonical")),
		list(local = .try_get("teamsRawData"),
		 canonical = .try_get("teamsRawDataCanonical"))
	)

	teams_mirror <- NA_character_
	for (c in candidates) {
		if (is.na(c$local) || !nzchar(c$local) ||
		 is.na(c$canonical) || !nzchar(c$canonical)) next
		ln <- .normalize_for_comparison(c$local)
		cn <- .normalize_for_comparison(c$canonical)
		if (identical(ln, cn)) next # already canonical; no separate mirror
		ln <- sub("/+$", "", ln)
		cn <- sub("/+$", "", cn)
		if (identical(pn, ln) || startsWith(pn, paste0(ln, "/"))) {
			rel <- substring(pn, nchar(ln) + 1L)
			rel <- sub("^/", "", rel)
			teams_mirror <- if (nzchar(rel)) file.path(cn, rel) else cn
			break
		}
	}

	# Z: mirror is derived from the Teams canonical equivalent (which is
	# what the existing .dw_z_mirror_path expects as input).
	z_mirror <- NA_character_
	if (!is.na(teams_mirror)) {
		z_mirror <- .dw_z_mirror_path(teams_mirror)
		if (is.null(z_mirror)) z_mirror <- NA_character_
	}

	list(teams = teams_mirror, z = z_mirror)
}

#' Carbon-copy a primary write to the Teams canonical equivalent
#'
#' Internal. Companion to [.dw_mirror_to_z()]. Non-blocking: warns
#' on copy failure, doesn't stop the primary write.
#'
#' @keywords internal
#' @noRd
.dw_mirror_to_teams <- function(primary_path, teams_path, verbose = TRUE) {
	if (is.na(teams_path) || !nzchar(teams_path)) {
		return(invisible(NA_character_))
	}
	tryCatch(
		dir.create(dirname(teams_path), recursive = TRUE, showWarnings = FALSE),
		error = function(e) NULL
	)
	ok <- tryCatch(
		file.copy(primary_path, teams_path, overwrite = TRUE, copy.date = TRUE),
		warning = function(w) FALSE,
		error = function(e) FALSE
	)
	if (isTRUE(ok)) {
		if (verbose) message("[dw_save] Teams mirror -> ", teams_path)
		return(invisible(teams_path))
	}
	warning(sprintf(
		"[cso_toolkit.dw_save] Teams mirror FAILED for: %s\n (primary write succeeded; Teams is now out of sync; investigate filesystem permissions or Teams sync state).",
		teams_path
	), call. = FALSE)
	invisible(NA_character_)
}

#' Carbon-copy a primary write to a specific Z: drive path
#'
#' Internal.  Sibling of [.dw_mirror_to_teams()].  Used by `dw_save()`
#' for the producer-mode Z: half of the v0.4.0 redundant-write
#' contract, where the Z: destination has already been derived (via
#' [.dw_remote_mirrors()]) -- this helper carbon-copies and emits "Z:
#' mirror -> ..." log + warning lines, distinct from the Teams mirror
#' label.
#'
#' Non-blocking: warns on copy failure, doesn't stop the primary
#' write.  [.dw_mirror_to_z()] (no second argument) is the older
#' helper used by the DBM-bootstrap canonical path; the two should
#' converge once that path is reworked.
#'
#' @keywords internal
#' @noRd
.dw_copy_to_z <- function(primary_path, z_path, verbose = TRUE) {
	if (is.na(z_path) || !nzchar(z_path)) {
		return(invisible(NA_character_))
	}
	tryCatch(
		dir.create(dirname(z_path), recursive = TRUE, showWarnings = FALSE),
		error = function(e) NULL
	)
	ok <- tryCatch(
		file.copy(primary_path, z_path, overwrite = TRUE, copy.date = TRUE),
		warning = function(w) FALSE,
		error = function(e) FALSE
	)
	if (isTRUE(ok)) {
		if (verbose) message("[dw_save] Z: mirror -> ", z_path)
		return(invisible(z_path))
	}
	warning(sprintf(
		"[cso_toolkit.dw_save] Z: mirror FAILED for: %s\n (primary write succeeded; Z: is now out of sync; investigate Z: drive mount state or filesystem permissions).",
		z_path
	), call. = FALSE)
	invisible(NA_character_)
}


#' Test whether a path lies under the configured Z: drive root
#'
#' Internal helper used by the v0.4.0 reviewer-mode guard in
#' [dw_save()] to refuse writes that target Z: directly (in addition
#' to the canonical Teams test in [dw_is_canonical()]).
#'
#' @keywords internal
#' @noRd
.dw_path_is_under_z <- function(path) {
	z_root <- .try_get("dwZDrive")
	if (is.na(z_root) || !nzchar(z_root)) return(FALSE)
	pn <- .normalize_for_comparison(path)
	zn <- .normalize_for_comparison(z_root)
	zn <- sub("/+$", "", zn)
	identical(pn, zn) || startsWith(pn, paste0(zn, "/"))
}

#' Translate a Teams-canonical path to its Z: drive equivalent
#'
#' Internal helper. Returns `NA_character_` when Z: is not available or
#' `path` does not lie under canonical.
#'
#' @param path Character. Filesystem path under `teamsFolderCanonical`.
#'
#' @return Character path on Z:, or `NA_character_`.
#'
#' @keywords internal
#' @noRd
.dw_z_mirror_path <- function(path) {
	if (!isTRUE(.try_get("dw_z_available"))) return(NA_character_)
	teams_canon <- .try_get("teamsFolderCanonical")
	z_root <- .try_get("dwZDrive")
	if (is.na(teams_canon) || is.na(z_root)) return(NA_character_)
	tn <- normalizePath(teams_canon, winslash = "/", mustWork = FALSE)
	zn <- normalizePath(z_root, winslash = "/", mustWork = FALSE)
	pn <- normalizePath(path, winslash = "/", mustWork = FALSE)
	if (!startsWith(pn, tn)) return(NA_character_)
	rel <- sub(paste0("^", tn), "", pn)
	rel <- sub("^/", "", rel)
	file.path(zn, rel)
}

#' Carbon-copy a canonical write to the Z: drive
#'
#' Internal helper called by [dw_save()] after a successful primary write.
#' Silent when Z: is not mapped; warns when the copy itself fails.
#'
#' @param primary_path Character. Path that was just written under canonical.
#' @param verbose Logical. Whether to emit a `[dw_save] Z: mirror ->` message
#' on success. Default `TRUE`.
#'
#' @return Invisibly, the Z: path on success, or `NA_character_` otherwise.
#'
#' @keywords internal
#' @noRd
.dw_mirror_to_z <- function(primary_path, verbose = TRUE) {
	z_path <- .dw_z_mirror_path(primary_path)
	if (is.na(z_path)) return(invisible(NA_character_))
	dir.create(dirname(z_path), recursive = TRUE, showWarnings = FALSE)
	ok <- file.copy(primary_path, z_path, overwrite = TRUE, copy.date = TRUE)
	if (isTRUE(ok)) {
		if (verbose) message("[dw_save] Z: mirror -> ", z_path)
		return(invisible(z_path))
	}
	warning("[dw_save] Z: mirror FAILED for: ", z_path,
	 " (write to Teams primary succeeded; Z: is now out of sync)")
	invisible(NA_character_)
}

#' Verify a canonical Teams file matches its Z: drive mirror
#'
#' Compares the file at `path` against the corresponding Z: mirror via
#' either a fast file-size check or a deep sha256 hash. Non-blocking by
#' design: callers act on the returned `status` rather than seeing an
#' immediate `stop()`.
#'
#' @param path Character. Path to a file under `teamsFolderCanonical`.
#' @param compare Character. `"size"` (default, fast) or `"sha256"` (deep,
#' requires the `digest` package).
#'
#' @return A list with `status` and supporting fields. `status` is one of:
#' `"no_z_mirror"`, `"z_missing"`, `"match_size"`, `"size_mismatch"`,
#' `"match_sha256"`, `"sha256_mismatch"`, or `"verify_unavailable"`.
#'
#' @seealso [dw_save()] (carbon-copies on canonical writes) and [dw_use()]
#' (runs an automatic size check on canonical reads).
#' @family io
#' @export
dw_verify_z <- function(path, compare = c("size", "sha256")) {
	compare <- match.arg(compare)
	z_path <- .dw_z_mirror_path(path)
	if (is.na(z_path)) {
		return(list(status = "no_z_mirror", path = path, z_path = NA_character_))
	}
	if (!file.exists(z_path)) {
		return(list(status = "z_missing", path = path, z_path = z_path))
	}
	if (compare == "size") {
		ps <- file.info(path)$size
		zs <- file.info(z_path)$size
		list(status = if (identical(ps, zs)) "match_size" else "size_mismatch",
		 path = path, z_path = z_path,
		 primary_size = ps, z_size = zs)
	} else if (compare == "sha256") {
		if (!requireNamespace("digest", quietly = TRUE)) {
			return(list(status = "verify_unavailable",
			 reason = "digest package not installed"))
		}
		psha <- digest::digest(file = path, algo = "sha256")
		zsha <- digest::digest(file = z_path, algo = "sha256")
		list(status = if (identical(psha, zsha)) "match_sha256" else "sha256_mismatch",
		 path = path, z_path = z_path,
		 primary_sha = psha, z_sha = zsha)
	}
}

# ============================================================================
# isid uniqueness check (Stata-style; inspired by edukit_save)
# ============================================================================

#' Stata-style uniqueness check on a key tuple
#'
#' Raises an informative error if `df` has duplicate rows on the supplied
#' key columns. Inspired by Stata's `isid` (and World Bank's `edukit_save`).
#' Used by [dw_save()] when an `isid =` argument is supplied.
#'
#' @param df Data frame to check.
#' @param keys Character vector of column names that should uniquely
#' identify rows.
#' @param where Character. Context label included in the error message
#' (typically the resolved output path).
#'
#' @return Invisibly, `TRUE` when the check passes. Stops with a sample
#' of duplicates when it fails.
#'
#' @examples
#' \dontrun{
#' library(dplyr)
#' df <- data.frame(REF_AREA = c("AGO", "BFA"), value = c(1, 2))
#' dw_isid(df, keys = "REF_AREA")
#' }
#'
#' @seealso [dw_save()] (auto-invokes `dw_isid` when an `isid =` argument
#' is passed).
#' @family io
#' @export
dw_isid <- function(df, keys, where = "<unknown>") {
	missing_keys <- setdiff(keys, names(df))
	if (length(missing_keys) > 0) {
		present <- paste(utils::head(names(df), 10), collapse = ", ")
		if (length(names(df)) > 10) present <- paste0(present, "...")
		stop(sprintf(
			"[cso_toolkit.dw_isid] (%s) keys not in data: %s\n Data columns are: %s\n Fix: check spelling / casing on the key columns, or drop non-existent keys from your isid= argument.",
			where, paste(missing_keys, collapse = ", "), present
		), call. = FALSE)
	}
	if (nrow(df) == 0) return(invisible(TRUE))
	.require("dplyr")
	dup <- df |>
		dplyr::group_by(dplyr::across(dplyr::all_of(keys))) |>
		dplyr::filter(dplyr::n() > 1) |>
		dplyr::ungroup()
	n_dup <- nrow(dup)
	if (n_dup > 0) {
		sample_show <- utils::head(dup, 5)
		stop(sprintf(
			"[cso_toolkit.dw_isid] (%s) %d duplicate row(s) on key (%s).\n First duplicates:\n%s\n Fix: deduplicate before saving (`df <- dplyr::distinct(df, %s, .keep_all = TRUE)`) or extend the key set so the rows become unique.",
			where, n_dup, paste(keys, collapse = ", "),
			paste(utils::capture.output(print(sample_show)), collapse = "\n"),
			paste(keys, collapse = ", ")
		), call. = FALSE)
	}
	invisible(TRUE)
}

# ============================================================================
# dw_save -- uniform write with auto-dispatch + Z: mirror
# ============================================================================

#' Save an object to disk, dispatching on the file extension
#'
#' Uniform writer for the DW-Production warehouse. Supported extensions:
#' \tabular{ll}{
#' `.csv`, `.tsv`, `.txt` \tab `data.table::fwrite` (default `na=""`,
#' `row.names=FALSE`) \cr
#' `.csv.gz` / `.tsv.gz` \tab `fwrite` with `compress = "gzip"` \cr
#' `.xlsx` \tab `writexl::write_xlsx` (data frame or
#' named list); `openxlsx::saveWorkbook`
#' for `Workbook` objects \cr
#' `.rds` \tab `saveRDS` \cr
#' `.RData` / `.Rdata` / `.rda` \tab `save()` with named-list expansion \cr
#' `.dta` \tab `haven::write_dta` \cr
#' `.parquet` \tab `arrow::write_parquet` \cr
#' `.json` \tab `jsonlite::write_json` \cr
#' `.yml` / `.yaml` \tab `yaml::write_yaml`
#' }
#'
#' **Path resolution** -- pick one:
#' \itemize{
#' \item `path = "..."` -- used as-is (absolute or relative).
#' \item `name = "..."` + optional `sector` / `kind` / `vintage` -- resolved
#' via [dw_resolve_path()] using session-default mode
#' (`teamsWrkData` / `teamsRawData` / `dwMetaData`; these are
#' mode-aware in the profile).
#' }
#'
#' **Mode contract (v0.4.0)** -- enforced at call site.
#' \itemize{
#' \item **Reviewer mode** -- writes resolving under the canonical Teams
#' deposit OR under the configured Z: drive root stop unless
#' `allow_canonical_write = TRUE` (Database Manager bootstrap).
#' The Z: branch is new in v0.4.0; v0.3.0 only refused canonical writes.
#' \item **Producer mode** -- at least one of Teams (preferred) or Z:
#' drive must be available, otherwise `dw_save()` stops. Every
#' successful producer write fans out redundantly to BOTH mirrors when
#' both are configured.
#' }
#'
#' **Overwrite gate (v0.4.0 strict, v0.4.1 mode-aware)** -- `overwrite =
#' NULL` is the new default sentinel: it resolves to `TRUE` in reviewer
#' mode (scratch writes are safe to re-run; the local repo sandbox under
#' `013_wrkdata/_local/` is gitignored) and `FALSE` in producer mode
#' (must be explicit; re-runs against the canonical deposit require
#' deliberate overwrite confirmation). When explicitly set to `FALSE`,
#' the check examines ALL destinations that will actually be written
#' (primary, Teams mirror, Z: mirror); `dw_save()` stops if any of them
#' already exists. Pass `overwrite = TRUE` to restore the unconditional
#' v0.3.0 behaviour.
#'
#' **Mirror behaviour (v0.4.0)** -- automatic and paired. In producer
#' mode, each successful primary write is carbon-copied to its derived
#' Teams canonical equivalent AND its Z: drive equivalent (whichever are
#' available), along with the `.provenance.json` sidecar. Each mirror is
#' non-blocking: failures emit envelope-shaped `warning()` lines tagged
#' "Teams mirror" or "Z: mirror" but do NOT roll back the primary
#' write. (The DBM bootstrap path, where the primary IS canonical, keeps
#' the v0.3.0 Z:-only mirror semantics.)
#'
#' **Quality contract** -- `isid = c("col1","col2",...)` runs [dw_isid()]
#' before writing.
#'
#' **Provenance sidecar** -- `provenance = TRUE` writes
#' `<path>.provenance.json` with timestamp, user, dw_mode, sha256, schema,
#' and the user-supplied `metadata = list(...)` (title, abstract, producer,
#' sources, contact, vintage, ...).
#'
#' @param x Object to write (data frame for tabular formats; `Workbook` or
#' named list of data frames for `.xlsx`; any R object for `.rds`).
#' @param path Character. Literal output path. Mutually exclusive with
#' `name`.
#' @param name Character. File basename, resolved via [dw_resolve_path()]
#' together with `sector` / `kind` / `vintage`.
#' @param sector Character. Sector folder (e.g. `"ed"`, `"nt"`).
#' @param kind Character. One of `"wrk"`, `"raw"`, `"meta"`. Default
#' `"wrk"`.
#' @param isid Character vector of key columns. If supplied, [dw_isid()] is
#' run before the write.
#' @param metadata Named list merged into the `.provenance.json` sidecar
#' (title, abstract, producer, sources, contact, vintage, ...).
#' @param compress Logical. For `.csv` / `.tsv` / `.txt`, when `TRUE` the
#' path is suffixed with `.gz` and `fwrite(compress = "gzip")` is used.
#' @param dialect Character. Writer dialect for `.csv` / `.tsv` / `.txt`:
#'   - `"fwrite"` (default) -- `data.table::fwrite` path: fast,
#'     `row.names = FALSE`, configurable separator/na.
#'   - `"base"` -- `utils::write.table(..., col.names = NA, qmethod =
#'     "double")` with the dispatched separator. For `.csv` this is
#'     byte-identical to `utils::write.csv(x, file = path)` (which is
#'     itself a wrapper around `write.table` with the same args);
#'     restored in v0.4.1 for backward compatibility with sector
#'     scripts that rely on legacy CSV byte output. For `.tsv` /
#'     `.txt`, produces correct tab-separated output with the same
#'     row.names / quoted-string defaults (rather than silent
#'     CSV-formatted content with a TSV extension; the v0.4.1
#'     implementation called `write.csv()` directly and so hardcoded
#'     comma -- fixed in v0.4.2). Incompatible with `compress = TRUE`
#'     (gzip is fwrite-only; raises an explanatory error).
#' @param overwrite Logical or `NULL` (sentinel). When `NULL` (the
#' v0.4.1 default), the value resolves to `TRUE` in reviewer mode
#' (scratch writes under the local sandbox are safe to re-run) and
#' `FALSE` in producer mode (must be explicit; re-runs against the
#' canonical deposit require deliberate overwrite confirmation). When
#' explicitly set, the check examines ALL destinations that will
#' actually be written (primary, Teams mirror, Z: mirror); `dw_save()`
#' stops if any of them already exists. Pass `TRUE` to replace existing
#' deposits.
#' @param provenance Logical. Whether to write the `.provenance.json`
#' sidecar. Default `TRUE` (skipped for `.RData` / `.rda`).
#' @param vintage Character. Optional vintage tag (e.g. `"2026-05"`)
#' recorded in the sidecar and used by [dw_resolve_path()].
#' @param allow_canonical_write Logical. Bypass the reviewer-mode guard
#' that forbids writes to canonical / Z: roots. Default `FALSE`.
#' @param ... Format-specific arguments passed through to the underlying
#' writer (`fwrite`, `write_xlsx`, `saveRDS`, ...). The legacy
#' `mirror_to_z` keyword (v0.3.0) is silently dropped with a
#' deprecation warning -- Z: mirror is now automatic and paired with
#' the Teams mirror.
#'
#' @return Invisibly, the resolved output `path`.
#'
#' @examples
#' \dontrun{
#' dw_save(edu_sdg_uis,
#' name = "dw_ed_edu.csv", sector = "ed", kind = "wrk",
#' isid = c("DATAFLOW", "REF_AREA", "INDICATOR", "TIME_PERIOD"),
#' metadata = list(
#' title = "Education indicators -- UNICEF DW format",
#' producer = "01_dw_prep/012_codes/ed/02_aggregate_uis_sdg.R",
#' sources = c("UIS bulk SDG_092025", "WPP 2024"),
#' vintage = "2026-05"
#' ))
#' }
#' @seealso [dw_use()] for the read counterpart; [dw_isid()] for the
#' uniqueness check; [dw_verify_z()] for the Z: mirror integrity check;
#' [dw_resolve_path()] for the path-resolution rules.
#' @family io
#' @export
dw_save <- function(x,
 path = NULL,
 name = NULL, sector = NULL,
 kind = c("wrk", "raw", "meta"),
 isid = NULL,
 metadata = NULL,
 compress = FALSE,
 dialect = c("fwrite", "base"),
 overwrite = NULL,
 provenance = TRUE,
 vintage = NULL,
 allow_canonical_write = FALSE,
 ...) {

	kind <- match.arg(kind)
	dialect <- match.arg(dialect)
	dots <- list(...)

	# v0.4.0 deprecation: `mirror_to_z` is no longer a per-call flag.
	# Producer-mode mirroring to BOTH Z: and Teams is now automatic,
	# controlled by which remote roots the profile makes available.
	if ("mirror_to_z" %in% names(dots)) {
		warning(
			"[cso_toolkit.dw_save] `mirror_to_z` argument is deprecated in v0.4.0; ",
			"producer-mode mirroring is now automatic (controlled by which ",
			"remote roots the profile makes available). The argument is ",
			"ignored; will be removed in v0.5.0.",
			call. = FALSE
		)
		dots$mirror_to_z <- NULL
	}

	if (is.null(path)) {
		path <- dw_resolve_path(name = name, sector = sector, kind = kind,
		 vintage = vintage)
	}

	# Optional compression: append .gz for CSV/TSV/TXT, and auto-enable
	# compression when the path ALREADY ends in .gz (no caller foot-gun).
	# Applied BEFORE mirror destinations are computed so teams_mirror /
	# z_mirror carry the same `.gz` suffix as the primary write (fixes
	# #25: compressed bytes were previously copied to mirror filenames
	# without the .gz extension, and the overwrite check looked for the
	# uncompressed mirror name and missed any existing .gz mirror).
	# (Backported from DW-Production 00_functions/dw_io.R; see B2 in
	# docs/dw-production-alignment-2026-05-25.md.)
	fmt <- tolower(tools::file_ext(path))
	path_ends_in_gz <- grepl("\\.gz$", path, ignore.case = TRUE)
	if (isTRUE(compress) && fmt %in% c("csv", "tsv", "txt") && !path_ends_in_gz) {
		path <- paste0(path, ".gz")
	} else if (!isTRUE(compress) && path_ends_in_gz) {
		compress <- TRUE
	}

	# Compute remote mirror destinations once (NA if not applicable).
	mirrors <- .dw_remote_mirrors(path)
	teams_mirror <- mirrors$teams
	z_mirror <- mirrors$z

	is_canon <- dw_is_canonical(path)
	is_reviewer <- isTRUE(.try_get("dw_mode") == "reviewer")
	is_producer <- isTRUE(.try_get("dw_mode") == "producer")

	# === Lenient overwrite default (v0.4.1) ===
	# Resolve the `overwrite = NULL` sentinel based on mode:
	#   reviewer mode -> TRUE  (scratch writes are safe to re-run; the local
	#                          repo sandbox under <wrk>/_local/ is gitignored
	#                          and easy to nuke + re-run by design)
	#   producer mode -> FALSE (must be explicit; re-runs against the canonical
	#                          deposit require deliberate overwrite confirmation)
	#   mode unset    -> FALSE (safe default; matches v0.4.0 strict for
	#                          backward compat when dw_mode is not set)
	#
	# Background: v0.4.0 shipped with `overwrite = FALSE` uniform across both
	# modes (strict). Reviewer-mode pipelines hit this on every re-run of
	# scratch outputs, which is friction without safety benefit. v0.4.1
	# relaxes only the reviewer side.
	if (is.null(overwrite)) {
		overwrite <- isTRUE(is_reviewer)
	}

	# === Reviewer-mode write guard (v0.4.0: broadened) ===
	# Refuse any write whose primary path lands under a canonical root OR
	# under the Z: drive root. Local sandbox writes still allowed.
	if (is_reviewer && !isTRUE(allow_canonical_write)) {
		under_z <- .dw_path_is_under_z(path)
		if (is_canon || under_z) {
			where <- if (under_z) "Z: drive" else "canonical (Teams) deposit"
			stop(sprintf(
				"[cso_toolkit.dw_save] Reviewer mode forbids writes to %s: %s\n Reviewer sessions must keep canonical / Z: deposits read-only to preserve vintage permanence; writes go to the local repo sandbox.\n Fix:\n 1. Resolve a sandbox path instead (the profile's `teamsWrkData` should point there in reviewer mode), OR\n 2. If this is a deliberate Database Manager bootstrap, pass `allow_canonical_write = TRUE`.",
				where, path
			), call. = FALSE)
		}
	}

	# === Producer-mode pre-flight (v0.4.0: at least one remote required) ===
	# When primary is a repo-local sandbox write (i.e. NOT itself the
	# canonical artifact), at least one of Teams or Z: must be reachable
	# so the deposit is recoverable. Skip when allow_canonical_write
	# bypasses the contract (rare DBM bootstrap path).
	if (is_producer && !isTRUE(allow_canonical_write) && !is_canon) {
		if (is.na(teams_mirror) && is.na(z_mirror)) {
			stop(
				"[cso_toolkit.dw_save] Producer-mode write requires at least ",
				"one of Teams (preferred) or Z: drive to be mounted and ",
				"writable; currently neither is available on this machine.\n",
				" Primary path: ", path, "\n",
				" Fix: map at least one -- preferably both. See the profile's ",
				"Z: mount + Teams sync instructions. Set `teamsWrkDataCanonical` ",
				"/ `teamsRawDataCanonical` (Teams roots) and `dwZDrive` + ",
				"`dw_z_available <- TRUE` (Z: drive) in the profile.",
				call. = FALSE
			)
		}
	}

	# === Overwrite check (v0.4.0: destinations that will actually be written) ===
	# Refuse if primary OR (when the write will fan out) Teams/Z: mirror
	# already exists, unless caller passed `overwrite = TRUE`. Default
	# flipped from TRUE to FALSE in v0.4.0 (breaking change).
	will_fan_out <- is_producer || (is_canon && isTRUE(allow_canonical_write))
	if (!isTRUE(overwrite)) {
		existing <- character(0)
		if (file.exists(path)) existing <- c(existing, path)
		if (will_fan_out) {
			if (!is.na(teams_mirror) && file.exists(teams_mirror)) {
				existing <- c(existing, teams_mirror)
			}
			if (!is.na(z_mirror) && file.exists(z_mirror)) {
				existing <- c(existing, z_mirror)
			}
		}
		if (length(existing) > 0) {
			stop(
				"[cso_toolkit.dw_save] File exists at the following ",
				"destination(s) and `overwrite = FALSE`:\n ",
				paste(existing, collapse = "\n "),
				"\n Fix: pass `overwrite = TRUE` to confirm intentional ",
				"replacement, or write to a different path. ",
				"(Default flipped from TRUE to FALSE in v0.4.0; see NEWS.md ",
				"migration notes.)",
				call. = FALSE
			)
		}
	}

	# Quality contract -- isid before write
	if (!is.null(isid) && is.data.frame(x)) {
		dw_isid(x, keys = isid, where = path)
	}

	dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
	tmp_path <- paste0(path, ".tmp")
	if (file.exists(tmp_path)) file.remove(tmp_path)

	fmt_for_dispatch <- tolower(tools::file_ext(sub("\\.gz$", "", path,
	 ignore.case = TRUE)))
	switch(fmt_for_dispatch,
		csv = .write_csv(x, tmp_path, sep = ",",  compress = compress,
		                 dialect = dialect, ...),
		tsv = .write_csv(x, tmp_path, sep = "\t", compress = compress,
		                 dialect = dialect, ...),
		txt = .write_csv(x, tmp_path, sep = "\t", compress = compress,
		                 dialect = dialect, ...),
		xlsx = .write_xlsx(x, tmp_path, ...),
		rds = saveRDS(x, file = tmp_path, ...),
		rdata = .write_rdata(x, tmp_path, ...),
		"rda" = .write_rdata(x, tmp_path, ...),
		dta = { .require("haven"); haven::write_dta(x, path = tmp_path, ...) },
		parquet = { .require("arrow"); arrow::write_parquet(x, sink = tmp_path, ...) },
		json = { .require("jsonlite"); jsonlite::write_json(x, path = tmp_path,
		 auto_unbox = TRUE,
		 pretty = TRUE, ...) },
		yml = { .require("yaml"); yaml::write_yaml(x, file = tmp_path, ...) },
		yaml = { .require("yaml"); yaml::write_yaml(x, file = tmp_path, ...) },
		stop(sprintf(
			"[cso_toolkit.dw_save] Unsupported file extension '%s' (path: %s).\n Supported extensions: csv, tsv, txt, xlsx, rds, RData, rda, dta, parquet, json, yml, yaml\n Fix: rename the output so it has one of the supported extensions.",
			fmt_for_dispatch, path
		), call. = FALSE)
	)

	# Primary atomic rename (overwrite gate already enforced above
	# across primary + Teams + Z: destinations).
	ok_rename <- tryCatch(file.rename(tmp_path, path),
	 warning = function(w) FALSE,
	 error = function(e) FALSE)
	if (!isTRUE(ok_rename)) {
		file.remove(tmp_path)
		stop(sprintf(
			"[cso_toolkit.dw_save] Atomic rename %s -> %s failed.\n Fix: make sure the destination is not open in another process (Excel locks .xlsx files), then retry.",
			tmp_path, path
		), call. = FALSE)
	}

	# Provenance sidecar
	if (isTRUE(provenance) && !fmt_for_dispatch %in% c("rdata", "rda")) {
		.write_provenance(path, x, fmt = fmt_for_dispatch,
		 vintage = vintage, metadata = metadata, isid = isid)
	}

	# === Producer-mode redundant mirror writes (v0.4.0) ===
	# Mirror to Teams + Z: whenever the profile makes either available.
	# Single-mount scenarios (only Teams OR only Z:) succeed for that
	# one mirror; double-mount writes to both.  Reviewer-mode never
	# reaches here (guarded above).
	#
	# Copy semantics: Teams uses `.dw_mirror_to_teams()` (envelope-shaped
	# "Teams mirror -> ..." log + warning); Z: uses `.dw_copy_to_z()`
	# so a Z: copy failure is labelled "Z: mirror -> ..." in logs and
	# warnings.  Both helpers carbon-copy non-blocking.
	if (is_producer) {
		sidecar <- paste0(path, ".provenance.json")
		if (!is.na(teams_mirror)) {
			.dw_mirror_to_teams(path, teams_mirror)
			if (file.exists(sidecar)) {
				.dw_mirror_to_teams(sidecar,
				 paste0(teams_mirror, ".provenance.json"),
				 verbose = FALSE)
			}
		}
		if (!is.na(z_mirror)) {
			.dw_copy_to_z(path, z_mirror)
			if (file.exists(sidecar)) {
				.dw_copy_to_z(sidecar,
				 paste0(z_mirror, ".provenance.json"),
				 verbose = FALSE)
			}
		}
	}

	# === DBM bootstrap path: primary IS canonical ===
	# When `allow_canonical_write = TRUE` and `is_canon`, the primary
	# IS the canonical artifact; only Z: needs a separate mirror.
	if (is_canon && isTRUE(allow_canonical_write)) {
		.dw_mirror_to_z(path)
	}

	invisible(path)
}

# ---- internal writers ------------------------------------------------------

#' CSV/TSV/TXT writer (data.table::fwrite wrapper)
#'
#' Internal. Defaults match the warehouse convention (`na = ""`,
#' `row.names = FALSE`).
#'
#' @param x Data frame.
#' @param path Character. Output path.
#' @param sep Character. Field separator. Default `","`.
#' @param na Character. NA representation. Default `""`.
#' @param row.names Logical. Include row names. Default `FALSE`.
#' @param compress Logical. If `TRUE`, gzip output (passes
#' `compress = "gzip"` to `fwrite`).
#' @param ... Passed to `data.table::fwrite`.
#'
#' @return Invisibly, the result of `fwrite`.
#'
#' @keywords internal
#' @noRd
.write_csv <- function(x, path, sep = ",", na = "",
 compress = FALSE, dialect = "fwrite", ...) {
	# Note: `row.names` is intentionally NOT a named parameter here, so
	# that callers passing it via dw_save(..., row.names = TRUE) flow it
	# through `...` to data.table::fwrite (which honours it). Prior to
	# v0.4.2 row.names = FALSE was declared in the signature but never
	# plumbed to either writer, so the argument was silently ignored
	# (Copilot finding on PR #29). For the "base" dialect the call uses
	# the underlying write.table default (row.names = TRUE) which
	# preserves byte-parity with utils::write.csv().
	# v0.4.1 restore + v0.4.2 separator fix.
	#
	# v0.4.1 restored the `dialect` parameter that v0.4.0 silently dropped,
	# so callers depending on byte-parity with legacy utils::write.csv()
	# could keep that contract.
	#
	# v0.4.2 fixes a Copilot-flagged silent-CSV bug: v0.4.1's dialect="base"
	# branch called `utils::write.csv(x, file = path)`, which hardcodes a
	# comma separator. That meant `dw_save(x, "out.tsv", dialect = "base")`
	# silently produced CSV-formatted content with a .tsv extension.
	#
	# Fix: dispatch dialect="base" through utils::write.table() with the
	# caller's `sep`. write.csv is itself a wrapper around
	# write.table(..., sep = ",", col.names = NA, qmethod = "double"), so:
	#   - For .csv (sep = ",") the byte output is identical to write.csv()
	#     -- byte-parity guarantee preserved for callers that rely on it.
	#   - For .tsv / .txt (sep = "\t") the file contains correct tab
	#     separators with the same row.names / quoted-string defaults.
	if (identical(dialect, "base")) {
		if (isTRUE(compress)) {
			stop(
				"[cso_toolkit.dw_save] dialect = 'base' is incompatible ",
				"with compress = TRUE: utils::write.table() cannot gzip its ",
				"output, only data.table::fwrite() can.\n",
				" Fix:\n",
				"   1. Drop `compress = TRUE` to keep the base / write.csv ",
				"byte-parity contract, OR\n",
				"   2. Drop `dialect = \"base\"` (or set it to \"fwrite\") ",
				"to use the data.table::fwrite path with gzip support.",
				call. = FALSE
			)
		}
		return(utils::write.table(x, file = path,
		                          sep = sep,
		                          col.names = NA,
		                          qmethod = "double"))
	}
	if (!identical(dialect, "fwrite")) {
		stop(
			"[cso_toolkit.dw_save] dialect = '", dialect, "' is not ",
			"recognised.\n",
			" Fix: pass `dialect = \"fwrite\"` (default; data.table::fwrite) ",
			"or `dialect = \"base\"` (utils::write.table with col.names = NA + ",
			"qmethod = \"double\"; byte-parity with utils::write.csv() for ",
			".csv, correct tab-separated output for .tsv / .txt).",
			call. = FALSE
		)
	}
	.require("data.table")
	args <- list(x = x, file = path, sep = sep, na = na, ...)
	if (isTRUE(compress)) args$compress <- "gzip"
	do.call(data.table::fwrite, args)
}

#' XLSX writer (writexl or openxlsx)
#'
#' Internal. Dispatches on the class of `x`: `Workbook` objects go through
#' `openxlsx::saveWorkbook`; data frames and named lists of data frames go
#' through `writexl::write_xlsx`.
#'
#' @param x Data frame, named list of data frames, or `openxlsx::Workbook`.
#' @param path Character. Output path.
#' @param sheet Character. Sheet name when `x` is a bare data frame.
#' Default `"Sheet1"`.
#' @param ... Passed to the underlying writer.
#'
#' @return Invisibly, the result of the underlying writer.
#'
#' @keywords internal
#' @noRd
.write_xlsx <- function(x, path, sheet = "Sheet1", ...) {
	if (inherits(x, "Workbook")) {
		.require("openxlsx")
		openxlsx::saveWorkbook(x, file = path, overwrite = TRUE)
	} else if (is.list(x) && !is.data.frame(x) && length(x) > 0 &&
	 all(vapply(x, is.data.frame, logical(1)))) {
		.require("writexl")
		writexl::write_xlsx(x, path = path, ...)
	} else {
		.require("writexl")
		if (is.data.frame(x)) {
			writexl::write_xlsx(setNames(list(x), sheet), path = path, ...)
		} else {
			stop("dw_save (xlsx): `x` must be a data.frame, named list of data.frames, ",
			 "or an openxlsx Workbook object.")
		}
	}
}

#' .RData / .rda writer
#'
#' Internal. Handles two shapes:
#' \itemize{
#' \item Named list -- each element saved under its own name.
#' \item Single object -- saved under the file's basename
#' (`tools::file_path_sans_ext`).
#' }
#'
#' @param x Object to save.
#' @param path Character. Output path.
#' @param name Character. Optional override for the in-file object name
#' when `x` is a single object.
#' @param ... Passed to `base::save`.
#'
#' @return Invisibly, `NULL`.
#'
#' @keywords internal
#' @noRd
.write_rdata <- function(x, path, name = NULL, ...) {
	env <- new.env(parent = emptyenv())
	if (is.list(x) && !is.null(names(x)) && length(x) > 0) {
		for (nm in names(x)) assign(nm, x[[nm]], envir = env)
		save(list = names(x), file = path, envir = env, ...)
	} else {
		nm <- name %||% tools::file_path_sans_ext(basename(path))
		assign(nm, x, envir = env)
		save(list = nm, file = path, envir = env, ...)
	}
}

#' Emit a `.provenance.json` sidecar alongside a saved file
#'
#' Internal. Writes a JSON sidecar at `<path>.provenance.json` containing
#' format, timestamp, user, `dw_mode`, sha256 (when `digest` is available),
#' schema (rows, cols, columns) for data frames, and any caller-supplied
#' metadata.
#'
#' @param path Character. Path of the file just written.
#' @param x The object that was written.
#' @param fmt Character. Format key (`"csv"`, `"rds"`, `"parquet"`, ...).
#' @param vintage Character. Optional vintage tag.
#' @param metadata Named list of user-supplied metadata.
#' @param isid Character vector of key columns used (if any).
#'
#' @return Invisibly, `NULL`.
#'
#' @keywords internal
#' @noRd
.write_provenance <- function(path, x, fmt, vintage = NULL,
 metadata = NULL, isid = NULL) {
	if (!requireNamespace("jsonlite", quietly = TRUE)) return(invisible(NULL))
	sha <- if (requireNamespace("digest", quietly = TRUE)) {
		digest::digest(file = path, algo = "sha256")
	} else NA_character_
	schema <- if (is.data.frame(x)) {
		list(rows = nrow(x), cols = ncol(x), columns = names(x))
	} else list()
	prov <- c(
		list(
			path = path,
			format = fmt,
			written_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z", tz = "UTC"),
			user = Sys.getenv("USERNAME"),
			dw_mode = .try_get("dw_mode"),
			vintage = vintage,
			sha256 = sha,
			isid = isid,
			schema = schema
		),
		if (!is.null(metadata)) list(metadata = metadata) else list()
	)
	# Wrap the sidecar write so a non-JSON-serialisable metadata value
	# (rare but possible -- e.g. a Date class) emits a warning rather
	# than rolling back the primary file write. Sidecar is metadata;
	# the asset is what matters. Backported from DW-Production; see B3
	# in docs/dw-production-alignment-2026-05-25.md.
	tryCatch(
		jsonlite::write_json(prov, path = paste0(path, ".provenance.json"),
		 auto_unbox = TRUE, pretty = TRUE),
		error = function(e) {
			warning(sprintf(
				"[cso_toolkit.dw_save] Provenance sidecar write failed for %s: %s\n Primary file unaffected; metadata may contain non-serialisable objects.\n Fix: ensure all metadata values are JSON-serialisable (atomic types, lists of atomics, or named lists thereof).",
				path, conditionMessage(e)
			), call. = FALSE)
		}
	)
}

# ============================================================================
# dw_use -- uniform read with auto-dispatch + Z: integrity check
# ============================================================================

#' Read a file from disk, dispatching on the file extension
#'
#' Companion to [dw_save()] with the same extension matrix and path
#' resolution. Adds a non-blocking Z: integrity check for canonical reads.
#'
#' **Z: integrity** -- automatic. When the resolved path is under canonical
#' AND `dw_z_available == TRUE`, a size-check (default; cheap) compares
#' Teams vs Z:. Mismatch emits a warning; the read still proceeds (with
#' the Teams data). Skip via `verify_z = FALSE`. Use
#' `verify_z = "sha256"` for a deep check.
#'
#' **Resolution order (v0.4.0)** -- mode-branched.
#' \itemize{
#' \item **Producer / unknown mode** (v0.3.0 preserved). Local-first:
#' try the literal path; if missing and `fallback_canonical = TRUE`,
#' walk the `teams*Data -> teams*DataCanonical` prefix map.
#' \item **Reviewer mode** (network-first; new in v0.4.0). Tries the
#' Teams canonical equivalent first, then the Z: drive mirror, then
#' falls back to the repo-local copy with an envelope-shaped
#' `warning()` flagging the provenance gap. If the file is missing in
#' all three locations, the helper raises an envelope-shaped `stop()`
#' pointing the reviewer to the sector producer. Disable the local
#' fallback with `fallback_canonical = FALSE`.
#' }
#'
#' @param path Character. Literal input path. Mutually exclusive with `name`.
#' @param name Character. File basename, resolved via [dw_resolve_path()].
#' @param sector Character. Sector folder (e.g. `"ed"`, `"nt"`).
#' @param kind Character. One of `"wrk"`, `"raw"`, `"meta"`. Default `"wrk"`.
#' @param cols Character vector. Optional column subset (for `.csv`, `.tsv`,
#' `.xlsx`, `.dta`, `.parquet`).
#' @param cols_lenient Logical. Default `FALSE`. When `TRUE` and `cols` is a
#' non-NULL character vector, dw_use introspects the file schema cheaply
#' (parquet metadata, dta header, csv / tsv / xlsx zero-row read) and
#' intersects `cols` with the file's actual columns before the data read.
#' Use this to replicate the `dplyr::any_of()` "only-if-present" intent
#' without calling `any_of()` outside a tidyselect context (which errors
#' fatally in tidyselect >= 1.2.0). When the intersection is empty, dw_use
#' falls back to reading all columns and emits a warning. Supported
#' formats: `csv`, `tsv`, `txt`, `xlsx`, `dta`, `parquet`.
#' @param as Character. Return type: `"tibble"` (default), `"data.frame"`,
#' or `"data.table"`.
#' @param fallback_canonical Logical. Default `TRUE`.
#' In **producer / unknown mode**, when the literal path is missing
#' the helper retries under the canonical root by substituting
#' `teamsRawData -> teamsRawDataCanonical`,
#' `teamsWrkData -> teamsWrkDataCanonical`, etc.
#' In **reviewer mode** (v0.4.0), this flag controls whether the
#' repo-local fallback is allowed when Teams + Z: are both missing
#' (with a provenance warning); set `FALSE` to fail fast instead.
#' @param verify_z `TRUE`, `FALSE`, or `"sha256"`. Controls the Z: integrity
#' check for canonical reads. Default `TRUE` (size compare).
#' @param ... Format-specific arguments passed through to the underlying
#' reader.
#'
#' @return The loaded object. Tabular formats are coerced to the requested
#' `as` shape.
#'
#' @examples
#' \dontrun{
#' # Default: read everything
#' warehouse <- dw_use(name = "dw_ed_edu.csv", sector = "ed", kind = "wrk")
#'
#' # Strict column subset (v0.4.3+: parquet / dta now correctly pass through
#' # to all columns when `cols` is NULL; explicit `cols` still errors if a
#' # requested name is missing from the file's schema).
#' df <- dw_use(name = "dw_ed_edu.csv", sector = "ed", kind = "wrk",
#'              cols = c("REF_AREA", "OBS_VALUE"))
#'
#' # Lenient column subset (v0.4.3+): intersect the request with the file's
#' # actual schema before the read. Use this instead of
#' # `cols = dplyr::any_of(c(...))` -- `any_of()` errors at the top level
#' # under tidyselect >= 1.2.0.
#' df <- dw_use(name = "dw_nut_country_series.parquet", sector = "nt",
#'              cols = c("REF_AREA", "INDICATOR", "MAYBE_PRESENT_COL"),
#'              cols_lenient = TRUE)
#' }
#' @seealso [dw_save()] for the write counterpart; [dw_verify_z()] for
#' the underlying integrity check.
#' @family io
#' @export
dw_use <- function(path = NULL,
 name = NULL, sector = NULL,
 kind = c("wrk", "raw", "meta"),
 cols = NULL,
 cols_lenient = FALSE,
 as = c("tibble", "data.frame", "data.table"),
 fallback_canonical = TRUE,
 verify_z = TRUE,
 ...) {
	kind <- match.arg(kind)
	as <- match.arg(as)

	if (is.null(path)) {
		path <- dw_resolve_path(name = name, sector = sector, kind = kind)
	}

	resolved <- .resolve_for_read(path, fallback_canonical = fallback_canonical)

	# Z: integrity check for canonical reads (non-blocking)
	if (isTRUE(verify_z) || identical(verify_z, "sha256")) {
		if (dw_is_canonical(resolved) && isTRUE(.try_get("dw_z_available"))) {
			cmp <- if (identical(verify_z, "sha256")) "sha256" else "size"
			res <- dw_verify_z(resolved, compare = cmp)
			if (!is.null(res) && !res$status %in% c("match_size", "match_sha256", "no_z_mirror")) {
				warning("[dw_use] Z: integrity check failed: ", res$status,
				 "\n Teams: ", res$path,
				 "\n Z: ", res$z_path %||% "<no z path>")
			}
		}
	}

	fmt <- tolower(tools::file_ext(sub("\\.gz$", "", resolved, ignore.case = TRUE)))

	# v0.4.3+ lenient-cols: pre-intersect cols with the actual file schema so
	# callers can replicate the `dplyr::any_of()` "only-if-present" intent
	# without invoking tidyselect helpers outside a selecting context (which
	# error fatally under tidyselect >= 1.2.0). Schema introspection is
	# format-specific and reads metadata only -- not the data payload.
	if (isTRUE(cols_lenient) && !is.null(cols) && length(cols) > 0) {
		schema_names <- .dw_schema_cols(resolved, fmt)
		if (!is.null(schema_names)) {
			kept <- intersect(cols, schema_names)
			if (length(kept) == 0) {
				warning(sprintf(
					"[cso_toolkit.dw_use] cols_lenient = TRUE: none of the requested cols matched the file schema for %s (requested %d; schema has %d). Reading all columns.",
					basename(resolved), length(cols), length(schema_names)
				), call. = FALSE)
				cols <- NULL
			} else {
				cols <- kept
			}
		}
	}

	x <- switch(fmt,
		csv = .read_csv(resolved, sep = ",", cols = cols, ...),
		tsv = .read_csv(resolved, sep = "\t", cols = cols, ...),
		txt = .read_csv(resolved, sep = "\t", cols = cols, ...),
		xlsx = .read_xlsx(resolved, cols = cols, ...),
		rds = readRDS(resolved, ...),
		rdata = .read_rdata(resolved, ...),
		"rda" = .read_rdata(resolved, ...),
		dta = {
			.require("haven")
			if (is.null(cols)) haven::read_dta(resolved, ...)
			else                haven::read_dta(resolved, col_select = cols, ...)
		},
		parquet = {
			.require("arrow")
			if (is.null(cols)) arrow::read_parquet(resolved, ...)
			else                arrow::read_parquet(resolved, col_select = cols, ...)
		},
		json = { .require("jsonlite"); jsonlite::read_json(resolved, ...) },
		yml = { .require("yaml"); yaml::read_yaml(resolved, ...) },
		yaml = { .require("yaml"); yaml::read_yaml(resolved, ...) },
		stop(sprintf(
			"[cso_toolkit.dw_use] Unsupported file extension '%s' (path: %s).\n Supported extensions: csv, tsv, txt, xlsx, rds, RData, rda, dta, parquet, json, yml, yaml\n Fix: ensure the file has one of the supported extensions.",
			fmt, resolved
		), call. = FALSE)
	)

	if (fmt %in% c("csv", "tsv", "txt", "xlsx", "dta", "parquet")) {
		x <- switch(as,
			"tibble" = { .require("tibble"); tibble::as_tibble(x) },
			"data.frame" = as.data.frame(x),
			"data.table" = { .require("data.table"); data.table::as.data.table(x) }
		)
	}
	x
}

#' CSV/TSV/TXT reader (data.table::fread wrapper)
#'
#' @param path Character. Input path.
#' @param sep Character. Field separator.
#' @param cols Character vector. Optional column subset.
#' @param ... Passed to `data.table::fread`.
#'
#' @return A `data.table`.
#'
#' @keywords internal
#' @noRd
.read_csv <- function(path, sep, cols = NULL, ...) {
	.require("data.table")
	data.table::fread(input = path, sep = sep,
	 select = cols, showProgress = FALSE, ...)
}

#' Cheap schema-only introspection for the `cols_lenient` path in dw_use
#'
#' Returns a character vector of column names by reading only the file
#' metadata / header -- never the data payload. Returns `NULL` when the
#' format does not support cheap schema introspection (the caller then
#' skips lenient intersection and passes cols through unchanged).
#'
#' Format dispatch:
#' \itemize{
#'   \item `parquet`: `arrow::open_dataset(path)$schema$names` (metadata-only; avoids loading the data payload)
#'   \item `csv` / `tsv` / `txt`: `data.table::fread(path, nrows = 0)` header read
#'   \item `dta`: `haven::read_dta(path, n_max = 0)` header read
#'   \item `xlsx`: `readxl::read_xlsx(path, n_max = 0)` header read
#'   \item other: `NULL` (no introspection)
#' }
#'
#' @keywords internal
#' @noRd
.dw_schema_cols <- function(path, fmt) {
	tryCatch(
		switch(fmt,
			parquet = {
				.require("arrow")
				# Metadata-only read; avoids loading the data payload for
				# large parquet files (594K-row CMRS series, etc.).
				arrow::open_dataset(path)$schema$names
			},
			csv = ,
			tsv = ,
			txt = {
				.require("data.table")
				sep <- if (identical(fmt, "csv")) "," else "\t"
				names(data.table::fread(input = path, sep = sep,
				                        nrows = 0, showProgress = FALSE))
			},
			dta = {
				.require("haven")
				names(haven::read_dta(path, n_max = 0))
			},
			xlsx = {
				.require("readxl")
				names(readxl::read_xlsx(path, n_max = 0))
			},
			NULL
		),
		error = function(e) {
			warning(sprintf(
				"[cso_toolkit.dw_use] cols_lenient schema introspect failed for %s (%s): %s. Skipping lenient intersection.",
				basename(path), fmt, conditionMessage(e)
			), call. = FALSE)
			NULL
		}
	)
}

#' XLSX reader (readxl::read_xlsx wrapper)
#'
#' @param path Character. Input path.
#' @param sheet Sheet name or index. Default `1`.
#' @param cols Character vector. Optional column subset (applied post-read).
#' @param ... Passed to `readxl::read_xlsx`.
#'
#' @return A tibble.
#'
#' @keywords internal
#' @noRd
.read_xlsx <- function(path, sheet = 1, cols = NULL, ...) {
	.require("readxl")
	x <- readxl::read_xlsx(path, sheet = sheet, ...)
	if (!is.null(cols)) x <- x[, intersect(names(x), cols), drop = FALSE]
	x
}

#' .RData / .rda reader (load() into a fresh env, returned as a list)
#'
#' @param path Character. Input path.
#' @param ... Passed to `base::load`.
#'
#' @return Named list of the loaded objects.
#'
#' @keywords internal
#' @noRd
.read_rdata <- function(path, ...) {
	env <- new.env(parent = emptyenv())
	load(path, envir = env)
	as.list(env)
}

# Note: the canonical-fallback resolver group (`.resolve_for_read*`)
# is documented inline at each function's own block below (lines 1700+).
# An older orphan docstring used to sit here for a now-merged helper;
# removed in v0.4.4 (PR #41) because roxygenise() was attaching it to
# the next exported function in source order
# (`dw_default_unicef_allowlist`).

# ============================================================================
# Remote-URL freeze (B1 from DW-Production alignment audit, 2026-05-25)
#
# `dw_use("https://...")` is a first-class call site. The URL must be
# in `dw_url_allowlist` (set by the consumer's profile; empty by
# default so the toolkit ships consumer-neutral); the response is
# downloaded once into the frozen-cache root and read from that
# frozen path on every subsequent call. Reviewer mode rejects calls
# that haven't been frozen by a producer yet, mirroring the existing
# no-API contract.
# ============================================================================

#' Standard URL-allowlist patterns for UNICEF-owned reference data
#'
#' Returns a character vector of `^...`-anchored regex patterns covering
#' UNICEF DRP GitHub-raw and repository URLs. Consumers seed
#' `dw_url_allowlist` from this constant instead of re-deriving the
#' patterns per project. Extend with project-specific patterns via
#' `c(dw_default_unicef_allowlist(), ...)`.
#'
#' Surfaced empirically by the DW-Production reviewer-mode audit on
#' 2026-05-28 (IM `01_immunization.R`): every URL-using sector script
#' was hand-writing the same `^https://raw\\.githubusercontent\\.com/unicef-drp/`
#' pattern. The helper consolidates the duplication and lets future
#' UNICEF-DRP additions land in one place upstream rather than in each
#' consumer's profile.
#'
#' The helper is purely additive: consumers must opt in by composing
#' it into their `dw_url_allowlist` (the URL-freeze safety contract is
#' unchanged — no URL is fetchable without explicit ratification).
#'
#' @return Character vector of regex patterns.
#'
#' @examples
#' \dontrun{
#' # In profile_<consumer>.R, seed the allowlist from the helper:
#' dw_url_allowlist <- c(
#'   dw_default_unicef_allowlist(),
#'   # Project-specific extras (org-controlled raw / SDMX endpoints, ...):
#'   "^https://yourorg\\.github\\.io/"
#' )
#' }
#'
#' @seealso [dw_use()] for the consumer that reads `dw_url_allowlist`.
#' @family io
#' @export
dw_default_unicef_allowlist <- function() {
	c(
		"^https://raw\\.githubusercontent\\.com/unicef-drp/",
		"^https://github\\.com/unicef-drp/"
	)
}

#' Is the URL allowlisted for remote-URL freeze?
#'
#' Internal. Reads `dw_url_allowlist` from `.GlobalEnv` (set by the
#' consumer's profile). Each entry is a PCRE; the URL matches if any
#' pattern matches. Empty / unset allowlist => no remote URLs allowed.
#'
#' @keywords internal
#' @noRd
.is_allowlisted_url <- function(url) {
	allow <- .try_get("dw_url_allowlist")
	# Check length FIRST so a zero-length allowlist doesn't trip
	# `allow[[1]]` with a subscript-out-of-bounds error.
	if (length(allow) == 0 || (is.atomic(allow) && all(is.na(allow)))) {
		return(FALSE)
	}
	any(vapply(allow, function(p) grepl(p, url), logical(1)))
}

#' Frozen-cache root for remote-URL freezes
#'
#' Internal. Resolution order:
#' 1. `dw_frozen_root` global if set;
#' 2. `<githubFolder>/_frozen` if `githubFolder` is set;
#' 3. `<getwd()>/_frozen`.
#'
#' @return Character path to the frozen-cache root.
#' @keywords internal
#' @noRd
.dw_frozen_root <- function() {
	.dw_frozen_root_resolved()$path
}

#' Frozen-cache root with resolution-source tag (v0.4.4+)
#'
#' Same logic as `.dw_frozen_root()` but returns a 2-element list:
#' \itemize{
#'   \item `$path` - the resolved filesystem path
#'   \item `$source` - which tier of the resolution chain fired:
#'     `"dw_frozen_root"` (#1, opt-in), `"githubFolder"` (#2, fallback),
#'     `"getwd"` (#3, last-resort fallback)
#' }
#' Used by `.resolve_remote_url()` to surface the chosen tier in the
#' missing-frozen-copy error envelope, so consumers can diagnose
#' resolution mismatches without grepping the toolkit source.
#'
#' @keywords internal
#' @noRd
.dw_frozen_root_resolved <- function() {
	root <- .try_get("dw_frozen_root")
	if (!is.na(root) && nzchar(root)) {
		return(list(path = root, source = "dw_frozen_root"))
	}
	gh <- .try_get("githubFolder")
	if (!is.na(gh) && nzchar(gh)) {
		return(list(path = file.path(gh, "_frozen"),
		            source = "githubFolder"))
	}
	list(path = file.path(getwd(), "_frozen"), source = "getwd")
}

#' Warn once per session when `.dw_frozen_root()` falls back beyond tier #1
#'
#' Emits a `message()` on the first remote-URL resolution when the
#' `dw_frozen_root` global is unset and the helper falls back to
#' `<githubFolder>/_frozen` (tier #2). Emits a `warning()` on fall-
#' back to `<getwd()>/_frozen` (tier #3) since that path is much less
#' stable across consumer configurations. The notice is gated by a
#' session-local sentinel so it fires only once per R session.
#'
#' Consumers that explicitly set `dw_frozen_root` (tier #1) get no
#' notice (they've opted in).
#'
#' @keywords internal
#' @noRd
.dw_frozen_root_notify_once <- function(resolved) {
	if (identical(resolved$source, "dw_frozen_root")) return(invisible(NULL))
	sentinel <- ".__cso_toolkit_frozen_root_notified__"
	if (isTRUE(.try_get(sentinel))) return(invisible(NULL))
	assign(sentinel, TRUE, envir = .GlobalEnv)
	msg <- sprintf(
		"[dw_use:remote] `dw_frozen_root` global not set; falling back to %s ('%s' tier). %s",
		resolved$path,
		resolved$source,
		"Set `dw_frozen_root <- '<path>'` in your profile if this is not the canonical location."
	)
	if (identical(resolved$source, "getwd")) warning(msg, call. = FALSE)
	else                                      message(msg)
	invisible(NULL)
}

#' Map a remote URL to its frozen-cache filesystem path
#'
#' @keywords internal
#' @noRd
.url_to_frozen_path <- function(url) {
	rel <- sub("^https?://", "", url)
	file.path(.dw_frozen_root(), rel)
}

#' Write a `.provenance.json` sidecar for a frozen remote file
#'
#' @keywords internal
#' @noRd
.write_remote_provenance <- function(url, frozen_path) {
	.require("digest")
	.require("jsonlite")
	prov <- list(
		url = url,
		sha256 = digest::digest(file = frozen_path, algo = "sha256"),
		bytes = unname(file.size(frozen_path)),
		fetched_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
		fetched_by = unname(Sys.info()[["user"]]),
		dw_mode = .try_get("dw_mode") %||% "unknown"
	)
	sidecar <- paste0(frozen_path, ".provenance.json")
	tryCatch(
		jsonlite::write_json(prov, sidecar, auto_unbox = TRUE, pretty = TRUE),
		error = function(e) {
			warning(sprintf(
				"[cso_toolkit.dw_use] Remote-freeze sidecar write failed for %s: %s",
				frozen_path, conditionMessage(e)
			), call. = FALSE)
		}
	)
	invisible(sidecar)
}

#' Download a URL once and freeze it to the local cache
#'
#' @keywords internal
#' @noRd
.download_and_freeze <- function(url, frozen_path) {
	dir.create(dirname(frozen_path), recursive = TRUE, showWarnings = FALSE)
	message("[dw_use:remote] Downloading: ", url)
	utils::download.file(url, destfile = frozen_path, mode = "wb", quiet = TRUE)
	sidecar <- .write_remote_provenance(url, frozen_path)
	message("[dw_use:remote] Frozen to: ", frozen_path)
	message("[dw_use:remote] COMMIT the frozen file + ", basename(sidecar),
	 " so subsequent runs are deterministic.")
	invisible(frozen_path)
}

#' Resolve a remote URL -- freeze on first download, error in reviewer
#' mode if not yet frozen
#'
#' @keywords internal
#' @noRd
.resolve_remote_url <- function(url) {
	if (!.is_allowlisted_url(url)) {
		allow <- .try_get("dw_url_allowlist")
		allow_str <- if (length(allow) == 0 ||
		 (is.atomic(allow) && all(is.na(allow)))) {
			"<empty>"
		} else {
			paste(allow, collapse = ", ")
		}
		stop(sprintf(
			"[cso_toolkit.dw_use] URL not in `dw_url_allowlist`: %s\n Configured allowlist: %s\n Fix: extend dw_url_allowlist in the consumer's profile, e.g.\n dw_url_allowlist <- c(dw_url_allowlist, '^https://raw\\\\.githubusercontent\\\\.com/your-org/')",
			url, allow_str
		), call. = FALSE)
	}
	resolved <- .dw_frozen_root_resolved()
	.dw_frozen_root_notify_once(resolved)
	frozen_path <- file.path(resolved$path, sub("^https?://", "", url))
	if (file.exists(frozen_path)) {
		message("[dw_use:remote] Reading frozen: ",
		 sub(resolved$path, "<dw_frozen_root>", frozen_path, fixed = TRUE))
		return(frozen_path)
	}
	is_reviewer <- isTRUE(.try_get("dw_mode") == "reviewer")
	if (is_reviewer) {
		# v0.4.4+: surface the frozen-root resolution tier in the error
		# envelope so consumers can diagnose path mismatches without
		# grepping the toolkit source.
		root_hint <- switch(resolved$source,
			dw_frozen_root = "explicit `dw_frozen_root` global",
			githubFolder   = "fallback via `<githubFolder>/_frozen`",
			getwd          = "fallback via `<getwd()>/_frozen` (least reliable)"
		)
		stop(sprintf(
			"[cso_toolkit.dw_use:remote] Reviewer mode forbids fetching from the network.\n Missing frozen copy: %s\n URL: %s\n Frozen-root resolution: %s (%s)\n Fix:\n   1. If the path above is wrong, set `dw_frozen_root <- '<your-canonical-frozen-path>'` in your profile.\n   2. Otherwise, a producer must call dw_use('%s') once and commit the frozen file + sidecar before the reviewer pipeline can read it.",
			frozen_path, url, resolved$path, root_hint, url
		), call. = FALSE)
	}
	.download_and_freeze(url, frozen_path)
	frozen_path
}

# ============================================================================

#' @keywords internal
#' @noRd
.resolve_for_read <- function(path, fallback_canonical) {
	# Remote URL? Hand off to the freeze resolver.
	if (grepl("^https?://", path)) {
		return(.resolve_remote_url(path))
	}

	# v0.4.0: branch by mode.
	is_reviewer <- isTRUE(.try_get("dw_mode") == "reviewer")
	if (is_reviewer) {
		return(.resolve_for_read_reviewer(path, fallback_canonical))
	}
	.resolve_for_read_producer(path, fallback_canonical)
}

#' Resolve a read path with NETWORK-FIRST order (reviewer mode)
#'
#' v0.4.0 (issue #14): for reviewer-mode reads we try canonical
#' destinations (Teams, then Z:) BEFORE falling back to the repo-local
#' copy. Rationale: reviewers must test against the producer-deposited
#' artifact, not a stale local cache that has drifted.
#'
#' Order:
#' 1. Canonical Teams path (substitute sandbox root -> canonical root).
#' 2. Z: drive mirror of the canonical Teams path.
#' 3. Repo-local literal path (with `warning()` flagging provenance gap).
#' 4. `stop()` with "contact the sector producer" message.
#'
#' @keywords internal
#' @noRd
.resolve_for_read_reviewer <- function(path, fallback_canonical) {
	# Normalise the literal path once so equality / startsWith below
	# behave on Windows mixed-separator + 8.3 short-name inputs.
	path_n <- .normalize_for_comparison(path)

	# If the literal path IS canonical AND it exists, prefer it directly.
	if (dw_is_canonical(path_n) && file.exists(path_n)) {
		return(path_n)
	}

	mirrors <- .dw_remote_mirrors(path_n)
	teams_alt <- mirrors$teams
	z_alt <- mirrors$z
	attempted <- character(0)

	# 1. Teams canonical
	if (!is.na(teams_alt) && nzchar(teams_alt)) {
		attempted <- c(attempted, teams_alt)
		if (file.exists(teams_alt)) {
			message("[dw_use:reviewer] Reading canonical (Teams): ", teams_alt)
			return(teams_alt)
		}
	}

	# 2. Z: drive mirror (derived from Teams canonical)
	if (!is.na(z_alt) && nzchar(z_alt)) {
		attempted <- c(attempted, z_alt)
		if (file.exists(z_alt)) {
			message("[dw_use:reviewer] Reading Z: mirror: ", z_alt)
			return(z_alt)
		}
	}

	# 3. Repo-local fallback (with provenance warning)
	attempted <- c(attempted, path)
	if (isTRUE(fallback_canonical) && file.exists(path)) {
		warning(sprintf(
			"[cso_toolkit.dw_use] Reviewer-mode canonical paths unavailable; falling back to repo-local copy at %s. This breaks provenance -- re-mount Teams / Z: before relying on this output.",
			path
		), call. = FALSE)
		return(path)
	}

	# 4. Hard-stop
	stop(sprintf(
		"[cso_toolkit.dw_use] Reviewer-mode read: file '%s' not found on Teams, Z:, or in the repo.\n Attempted:\n %s\n Fix: the producer has not deposited this artifact yet, or your network mount is missing. Contact the sector producer.",
		basename(path),
		paste(unique(attempted), collapse = "\n ")
	), call. = FALSE)
}

#' Resolve a read path with LOCAL-FIRST order (producer mode; v0.3.0
#' behaviour preserved)
#'
#' @keywords internal
#' @noRd
.resolve_for_read_producer <- function(path, fallback_canonical) {
	if (file.exists(path)) return(path)
	if (!isTRUE(fallback_canonical)) {
		stop(sprintf(
			"[cso_toolkit.dw_use] File not found and fallback_canonical = FALSE: %s\n Fix: drop the fallback_canonical = FALSE argument, or verify the path exists.",
			path
		), call. = FALSE)
	}
	swaps <- list(
		c(.try_get("teamsRawData"), .try_get("teamsRawDataCanonical")),
		c(.try_get("teamsWrkData"), .try_get("teamsWrkDataCanonical")),
		c(.try_get("teamsFolder"), .try_get("teamsFolderCanonical"))
	)
	attempted <- c(path)
	for (sw in swaps) {
		if (!any(is.na(sw)) && nzchar(sw[1]) && nzchar(sw[2]) &&
		 sw[1] != sw[2] && startsWith(path, sw[1])) {
			alt <- sub(paste0("^", sw[1]), sw[2], path, fixed = FALSE)
			attempted <- c(attempted, alt)
			if (file.exists(alt)) {
				message("[dw_use] Falling back to canonical: ", alt)
				return(alt)
			}
		}
	}
	stop(sprintf(
		"[cso_toolkit.dw_use] File not found at literal path or under any configured canonical root.\n Attempted:\n %s\n Fix: confirm the file was produced by the upstream pipeline, or that team*Canonical globals are set to the right roots.",
		paste(attempted, collapse = "\n ")
	), call. = FALSE)
}

# ============================================================================
# dw_compare -- generalised compare-vs-canonical (lifted from nt/5b)
# ============================================================================

#' Compare a current dataset against a reference (added / removed / changed)
#'
#' Three-way comparison of two data frames keyed on `by`, returning the
#' rows added on the current side, removed on the reference side, and
#' value-changed rows on the intersection. Numeric value columns can use a
#' tolerance-based equality; string columns normalise to trimmed lowercase
#' empty-equivalents (`""`, `"NA"`, `"N/A"`, `"NULL"`, `"."`).
#'
#' @param current Data frame or character path to a file. The "new" side.
#' @param reference Data frame or character path to a file. The "old" side.
#' @param by Character vector of key columns.
#' @param value_cols Character vector of columns to value-compare. Default
#' `NULL` (= all non-key columns present on both sides).
#' @param numeric_value_cols Subset of `value_cols` to treat as numeric
#' (uses `tol`). Others are string-compared.
#' @param tol Numeric tolerance for numeric value comparisons. Default
#' `1e-5`.
#' @param label Character. Label used in the summary row and report
#' filenames. Default `"compare"`.
#' @param write_report_to Character. Directory to write
#' `<label>_summary.csv`, `<label>_added_rows.csv`,
#' `<label>_removed_rows.csv`, `<label>_changed_rows.csv`. Default
#' `NULL` (don't write).
#'
#' @return A list with `summary` (one-row tibble) and `added`, `removed`,
#' `changed` data frames.
#'
#' @seealso [dw_use()] (used to materialise the inputs when paths are
#' supplied); [dw_merge()] for a Stata-style join with cardinality
#' assertion.
#' @family io
#' @export
dw_compare <- function(current, reference,
 by,
 value_cols = NULL,
 numeric_value_cols = NULL,
 tol = 1e-5,
 label = "compare",
 write_report_to = NULL) {

	.require("dplyr")
	if (is.character(current) && length(current) == 1) current <- dw_use(current)
	if (is.character(reference) && length(reference) == 1) reference <- dw_use(reference)

	common <- intersect(names(current), names(reference))
	by <- by[by %in% common]
	if (length(by) == 0) {
		cur_cols <- paste(utils::head(names(current), 8), collapse = ", ")
		if (length(names(current)) > 8) cur_cols <- paste0(cur_cols, "...")
		ref_cols <- paste(utils::head(names(reference), 8), collapse = ", ")
		if (length(names(reference)) > 8) ref_cols <- paste0(ref_cols, "...")
		stop(sprintf(
			"[cso_toolkit.dw_compare] No `by` columns are present in both sides.\n Current columns: %s\n Reference columns: %s\n Fix: pass at least one column name that appears in BOTH data frames as a join key.",
			cur_cols, ref_cols
		), call. = FALSE)
	}
	value_cols <- if (is.null(value_cols)) setdiff(common, by) else value_cols[value_cols %in% common]
	numeric_value_cols <- intersect(numeric_value_cols, value_cols)

	norm <- function(v) {
		v <- trimws(as.character(v))
		v[is.na(v) | v %in% c("NA", "N/A", "NULL", ".")] <- ""
		v
	}
	current <- dplyr::mutate(current, dplyr::across(dplyr::all_of(common), norm))
	reference <- dplyr::mutate(reference, dplyr::across(dplyr::all_of(common), norm))

	added <- dplyr::anti_join(current, reference, by = by)
	removed <- dplyr::anti_join(reference, current, by = by)

	cur_sub <- dplyr::select(current, dplyr::all_of(c(by, value_cols)))
	ref_sub <- dplyr::select(reference, dplyr::all_of(c(by, value_cols)))
	joined <- dplyr::inner_join(ref_sub, cur_sub, by = by,
	 suffix = c("_reference", "_current"))

	values_equal <- function(a, b, numeric) {
		both_missing <- (a == "") & (b == "")
		if (numeric) {
			an <- suppressWarnings(as.numeric(a))
			bn <- suppressWarnings(as.numeric(b))
			both_numeric <- !is.na(an) & !is.na(bn)
			numeric_equal <- both_numeric & abs(an - bn) <= tol
			both_str <- is.na(an) & is.na(bn)
			str_eq <- both_str & a == b
			both_missing | numeric_equal | str_eq
		} else {
			both_missing | a == b
		}
	}

	for (vc in value_cols) {
		joined[[paste0("changed_", vc)]] <- !values_equal(
			joined[[paste0(vc, "_reference")]],
			joined[[paste0(vc, "_current")]],
			numeric = vc %in% numeric_value_cols
		)
	}
	changed <- dplyr::filter(joined, dplyr::if_any(dplyr::starts_with("changed_"), ~ .x))

	summary_tbl <- tibble::tibble(
		label = label,
		reference_rows = nrow(reference),
		current_rows = nrow(current),
		row_delta = nrow(current) - nrow(reference),
		added = nrow(added),
		removed = nrow(removed),
		changed = nrow(changed),
		completed_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S")
	)

	if (!is.null(write_report_to)) {
		dir.create(write_report_to, recursive = TRUE, showWarnings = FALSE)
		prefix <- file.path(write_report_to, label)
		.require("data.table")
		data.table::fwrite(summary_tbl, paste0(prefix, "_summary.csv"))
		data.table::fwrite(added, paste0(prefix, "_added_rows.csv"))
		data.table::fwrite(removed, paste0(prefix, "_removed_rows.csv"))
		data.table::fwrite(changed, paste0(prefix, "_changed_rows.csv"))
	}

	list(summary = summary_tbl, added = added, removed = removed, changed = changed)
}

# ============================================================================
# dw_merge -- Stata-style merge with cardinality assert
# ============================================================================

#' Stata-style merge with cardinality assertion
#'
#' Thin wrapper around `dplyr::left_join` that warns when the actual
#' cardinality of `by` on the left or right side disagrees with the
#' declared `how`. Inspired by Stata's `merge m:1 / 1:1 / 1:m / m:m`.
#'
#' @param x Left-hand data frame.
#' @param using Right-hand data frame, OR a character path passed through
#' [dw_use()].
#' @param by Character vector of join keys.
#' @param how Character. One of `"m:1"`, `"1:1"`, `"1:m"`, `"m:m"`.
#' Default `"m:1"`.
#' @param ... Passed to `dplyr::left_join`.
#'
#' @return The joined data frame.
#'
#' @seealso [dw_use()] (used to materialise `using` when a path is
#' supplied); [dw_compare()] for a row-level diff.
#' @family io
#' @export
dw_merge <- function(x, using, by, how = c("m:1", "1:1", "1:m", "m:m"), ...) {
	how <- match.arg(how)
	.require("dplyr")
	y <- if (is.character(using) && length(using) == 1) dw_use(using) else using
	x_dup <- anyDuplicated(x[, by, drop = FALSE]) > 0
	y_dup <- anyDuplicated(y[, by, drop = FALSE]) > 0
	expected_x_dup <- how %in% c("m:1", "m:m")
	expected_y_dup <- how %in% c("1:m", "m:m")
	if (x_dup != expected_x_dup) {
		warning("dw_merge: left-side duplicates on `by` (",
		 paste(by, collapse = ","), ") do not match how='", how, "'")
	}
	if (y_dup != expected_y_dup) {
		warning("dw_merge: right-side duplicates on `by` (",
		 paste(by, collapse = ","), ") do not match how='", how, "'")
	}
	dplyr::left_join(x, y, by = by, ...)
}

# ============================================================================
# Example usage
# ============================================================================
#
# source("00_functions/dw_io.R") # auto-sourced by profile
#
# # WRITE -- path resolution honours session mode (producer or reviewer)
# dw_save(edu_sdg_uis,
# name = "dw_ed_edu.csv", sector = "ed", kind = "wrk",
# isid = c("DATAFLOW","REF_AREA","INDICATOR","SEX",
# "WEALTH_QUINTILE","RESIDENCE","TIME_PERIOD"),
# metadata = list(
# title = "Education indicators -- UNICEF DW format",
# producer = "01_dw_prep/012_codes/ed/02_aggregate_uis_sdg.R",
# sources = c("UIS bulk SDG_092025", "WPP 2024"),
# contact = "@karavan88",
# vintage = "2026-05"
# ))
# # In producer session: writes to Teams + carbon copy to Z: + provenance sidecar.
# # In reviewer session: writes to sandbox + provenance sidecar (no Z: mirror;
# # sandbox is not under canonical).
#
# # READ -- automatic Z: integrity check on canonical reads
# warehouse <- dw_use(name = "dw_ed_edu.csv", sector = "ed", kind = "wrk")
# # If Teams vs Z: differ, a warning is emitted; the read still completes.
#
# # Database-Manager bootstrap in reviewer session (rare; explicit):
# dw_save(pop_school_age,
# name = "pop_school_age.csv", sector = "ed", kind = "raw",
# allow_canonical_write = TRUE) # bypasses reviewer-mode guard
#
# # Compare
# report <- dw_compare(
# current = dw_use(name = "dw_ed_edu.csv", sector = "ed", kind = "wrk"),
# reference = dw_use(path = file.path(teamsWrkDataCanonical, "ed/dw_ed_edu.csv")),
# by = c("DATAFLOW","REF_AREA","INDICATOR","SEX","WEALTH_QUINTILE","TIME_PERIOD"),
# value_cols = c("OBS_VALUE", "DATA_SOURCE"),
# numeric_value_cols = "OBS_VALUE",
# tol = 1e-5
# )
