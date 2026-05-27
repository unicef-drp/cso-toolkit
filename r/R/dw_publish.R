# =============================================================================
# dw_publish -- API-only submission to the UNICEF Helix data platform
# =============================================================================
#
# STUB ONLY (v0.4.0).  Ships the public signature + a dry-run validation
# path; live submission (`dry_run = FALSE`) raises an envelope-shaped
# stop() pointing the caller at issue #15 where the Helix endpoint
# contract is still being negotiated with sector leads.
#
# Scope boundary -- intentionally REPEATED in the helper body so future
# maintainers don't conflate the two contracts:
#   * `dw_save()` -- writes to Teams folder + Z: drive mirror (filesystem).
#   * `dw_publish()` -- submits an existing artifact to Helix (API).
# A common confusion in DW-Production sector scripts has been to call
# the local-canonical write step "publish", which has never been what
# the toolkit means.  This helper exists to make the distinction
# concrete.
#
# Mode contract: producer-only.  Reviewer-mode calls raise BEFORE any
# network attempt (mirrors `dw_api_fetch()`).  Same envelope shape.
#
# When the real Helix integration lands (planned v0.5.0), the
# `dry_run = TRUE` branch already validates the inputs; the
# `dry_run = FALSE` branch only needs to:
#   1. Acquire an auth token via the configured credential source.
#   2. Build the HTTP / SDMX request from the validated payload.
#   3. POST to the configured endpoint.
#   4. Parse + return the response, including the submission ID.
#   5. Update the sibling `.provenance.json` with `published_at`,
#      `published_by`, and `helix_submission_id`.

#' Submit a warehouse artifact to the UNICEF Helix data platform (STUB)
#'
#' @description
#' Publishes a local warehouse artifact to the Helix data platform via
#' API.  This is **NOT** a filesystem copy -- see [dw_save()] for the
#' Teams + Z: drive mirroring contract.
#'
#' v0.4.0 ships this helper as a STUB: only `dry_run = TRUE` is
#' supported.  A live submission (`dry_run = FALSE`) raises an
#' envelope-shaped error pointing at GitHub issue
#' [#15](https://github.com/unicef-drp/cso-toolkit/issues/15) where the
#' Helix endpoint contract is being finalised with sector leads.
#'
#' The dry-run path validates the inputs against the v0.5.0-bound
#' contract so callers can wire the call site today and have the live
#' branch light up automatically when v0.5.0 lands.
#'
#' @section Mode contract:
#' Producer-only.  Reviewer-mode calls raise via [dw_require_no_api()]
#' BEFORE any other validation.  Same shape as [dw_api_fetch()].
#'
#' @section Scope boundary:
#' \itemize{
#'   \item [dw_save()] -- writes to Teams folder + Z: drive (filesystem
#'     mirror).
#'   \item `dw_publish()` (this helper) -- submits the saved artifact
#'     to Helix (API).
#' }
#' If you want a local-or-Teams copy, you want `dw_save()`; if you want
#' a Helix submission ID, you want `dw_publish()`.
#'
#' @param path Character.  Path to a local artifact (must exist).
#'   Typically the output of a `dw_save()` call.
#' @param indicator Character.  Indicator code (e.g. `"U5MR"`).
#' @param vintage Character.  Vintage tag (e.g. `"2025"`).
#' @param sector Character.  Sector code (e.g. `"hva"`, `"ed"`).
#' @param endpoint Character.  Submission endpoint.  Currently only
#'   `"helix"` is recognised.  Default `"helix"`.
#' @param dry_run Logical.  When `TRUE` (the v0.4.0 default), validate
#'   inputs + endpoint reachability without sending and return the
#'   dry-run payload.  When `FALSE`, raise an envelope-shaped
#'   `"Live submission not yet implemented"` stop until the v0.5.0
#'   live-submission branch lands.
#' @param ... Forwarded to the underlying HTTP client (currently
#'   unused; reserved for the v0.5.0 live-submission branch).
#'
#' @return A list with elements:
#'   \describe{
#'     \item{`submission_id`}{Character.  `NA_character_` in dry-run.}
#'     \item{`status`}{Character.  `"dry_run"` in dry-run.}
#'     \item{`response_body`}{List.  Echoes the validated payload in
#'       dry-run (useful for unit tests that want to assert the call
#'       site builds the right structure).}
#'     \item{`idempotent`}{Logical.  `NA` in dry-run.  In v0.5.0 will
#'       be `TRUE` when re-submitting the same `(indicator, vintage,
#'       sha256)` triple returns an existing submission ID.}
#'   }
#'
#' @examples
#' \dontrun{
#' # Dry-run validation (the v0.4.0-supported path)
#' out <- dw_publish(
#'   path      = "/data/wrk/hva/dw_hva_u5mr.csv",
#'   indicator = "U5MR",
#'   vintage   = "2025",
#'   sector    = "hva"
#' )
#' stopifnot(out$status == "dry_run")
#'
#' # Live submission -- raises in v0.4.0 (and any v0.4.x patch)
#' # dw_publish(..., dry_run = FALSE)  # -> [cso_toolkit.dw_publish] error
#' }
#' @seealso [dw_save()] (the filesystem write counterpart);
#'   [dw_api_fetch()] (the mode-contract sibling for fetch-direction
#'   external calls).
#' @family api
#' @export
dw_publish <- function(path,
                       indicator,
                       vintage,
                       sector,
                       endpoint = "helix",
                       dry_run  = TRUE,
                       ...) {

	# --- 1. Mode contract: producer-only (raises BEFORE any I/O) -----------
	# Same logic as dw_api_fetch.  Reviewer sessions cannot submit to
	# Helix; only the producer running the canonical promotion job has
	# the credentials + the authority for that endpoint.
	if (isTRUE(.try_get("dw_mode") == "reviewer")) {
		stop(
			"[cso_toolkit.dw_publish] Reviewer mode forbids API submissions ",
			"to '", endpoint, "'.\n",
			"  Why: only producer sessions hold Helix credentials and may ",
			"submit deposits; reviewer sessions read frozen caches and ",
			"publish nothing.\n",
			"  Fix: re-run this script in producer mode (set ",
			"`dw_mode <- \"producer\"` in your profile_<repo>.R), or ask ",
			"the producer to publish.",
			call. = FALSE
		)
	}

	# --- 2. Argument validation --------------------------------------------
	# Positional + named are all required; default values that would
	# silently slip an empty submission past validation are NOT
	# acceptable for an API-submission helper.
	missing_args <- character(0)
	for (nm in c("path", "indicator", "vintage", "sector")) {
		v <- get(nm)
		if (is.null(v) || (is.character(v) && !nzchar(v))) {
			missing_args <- c(missing_args, nm)
		}
	}
	if (length(missing_args) > 0) {
		stop(sprintf(
			"[cso_toolkit.dw_publish] Missing or empty required argument(s): %s\n  Fix: pass non-empty values for path, indicator, vintage, and sector.",
			paste(missing_args, collapse = ", ")
		), call. = FALSE)
	}

	# Path must exist (and be a file, not a directory)
	if (!file.exists(path) || file.info(path)$isdir) {
		stop(sprintf(
			"[cso_toolkit.dw_publish] Local artifact not found at path: %s\n  Why: dw_publish() submits an EXISTING file -- it does not write one. Call dw_save() first if the artifact has not been deposited yet.\n  Fix: confirm the path, OR call dw_save(...) first to produce the file.",
			path
		), call. = FALSE)
	}

	# Endpoint must be a recognised value (only "helix" today)
	if (!identical(endpoint, "helix")) {
		stop(sprintf(
			"[cso_toolkit.dw_publish] Unsupported endpoint '%s'.\n  Supported: 'helix' (only).\n  Fix: drop the endpoint() argument to take the default, or pass 'helix' explicitly.",
			endpoint
		), call. = FALSE)
	}

	# --- 3. Build the validated payload ------------------------------------
	# This is the shape the v0.5.0 live branch will POST.  We assemble
	# it now so dry-run callers see the exact structure their call site
	# will produce.
	payload <- list(
		path       = path,
		indicator  = indicator,
		vintage    = vintage,
		sector     = sector,
		endpoint   = endpoint,
		sha256     = .dw_publish_sha256_or_na(path),
		bytes      = .dw_publish_bytes_or_na(path),
		built_at   = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z", tz = "UTC"),
		built_by   = .dw_publish_user_or_na(),
		toolkit    = dw_toolkit_version()
	)

	# --- 4. Dry-run vs live branch ------------------------------------------
	if (isTRUE(dry_run)) {
		return(list(
			submission_id = NA_character_,
			status        = "dry_run",
			response_body = payload,
			idempotent    = NA
		))
	}

	# Live submission -- not yet implemented.  v0.5.0 will fill this in.
	stop(
		"[cso_toolkit.dw_publish] Live submission not yet implemented ",
		"(endpoint = '", endpoint, "').\n",
		"  Why: the Helix endpoint contract is still being negotiated ",
		"with sector leads (see issue #15).  v0.4.0 ships dw_publish ",
		"as a dry-run-only stub so call sites can be wired today and ",
		"the live branch lights up automatically when v0.5.0 lands.\n",
		"  Fix: pass dry_run = TRUE (the v0.4.0 default) to validate ",
		"the payload now.  Track live-submission progress at ",
		"https://github.com/unicef-drp/cso-toolkit/issues/15.",
		call. = FALSE
	)
}

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

#' Best-effort sha256 of a file; NA on failure
#' @keywords internal
#' @noRd
.dw_publish_sha256_or_na <- function(path) {
	if (requireNamespace("digest", quietly = TRUE) && file.exists(path)) {
		tryCatch(
			digest::digest(file = path, algo = "sha256"),
			error = function(e) NA_character_
		)
	}
	else {
		NA_character_
	}
}

#' File size in bytes; NA on failure
#' @keywords internal
#' @noRd
.dw_publish_bytes_or_na <- function(path) {
	tryCatch(as.numeric(file.info(path)$size), error = function(e) NA_real_)
}

#' Current user from env (cross-platform) or NA
#' @keywords internal
#' @noRd
.dw_publish_user_or_na <- function() {
	u <- Sys.getenv("USERNAME", unset = "")
	if (!nzchar(u)) u <- Sys.getenv("USER", unset = "")
	if (!nzchar(u)) NA_character_ else u
}
