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
#' The dry-run path validates the call-site arguments (presence,
#' shape, path exists, endpoint allowlist) and assembles the payload
#' the v0.5.0 live branch will POST -- it does NOT check Helix
#' network reachability or credentials.  Live reachability + auth
#' checks land with the live-submission branch.
#'
#' @section Mode contract:
#' Producer-only.  Reviewer-mode calls raise BEFORE any other
#' validation with an envelope-shaped `[cso_toolkit.dw_publish]`
#' message.  The shape mirrors the consumer-profile-generated
#' `dw_require_no_api()` helper used elsewhere in the toolkit
#' (which is profile-defined, not exported by the package, so this
#' helper carries its own equivalent guard inline).
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
#'   the call-site arguments (presence + shape + path exists +
#'   endpoint allowlist), assemble the v0.5.0 submission payload, and
#'   return it without contacting any network.  When `FALSE`, raise
#'   an envelope-shaped `"Live submission not yet implemented"`
#'   stop until the v0.5.0 live-submission branch lands.  Note:
#'   neither branch performs an actual reachability or credential
#'   check in v0.4.0 -- that ships with the live branch in v0.5.0.
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
#' @param verbose Logical or `NULL`. Show high-level progress and result
#'   messages. `NULL` (default) inherits `getOption("dw.verbose", TRUE)`;
#'   set `TRUE`/`FALSE` to override for this call. See [dw_verbosity()].
#' @param debug Logical or `NULL`. Show internal troubleshooting detail
#'   (resolved paths, dims, branch decisions). `NULL` (default) inherits
#'   `getOption("dw.debug", FALSE)`; implies `verbose`. See [dw_verbosity()].
#' @export
dw_publish <- function(path,
                       indicator,
                       vintage,
                       sector,
                       endpoint = "helix",
                       dry_run  = TRUE,
                       verbose  = NULL,
                       debug    = NULL,
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
	#
	# `missing()` lets us check whether the caller passed the argument
	# at all WITHOUT forcing evaluation, so an omitted required arg
	# does not trigger base-R's "argument 'x' is missing, with no
	# default" message and bypass our envelope.  We also normalise
	# length-pathological inputs (NULL, length 0, length > 1) so the
	# existence + endpoint checks below don't blow up on a multi-length
	# condition.
	missing_args  <- character(0)
	invalid_shape <- character(0)
	if (missing(path))      missing_args <- c(missing_args, "path")
	if (missing(indicator)) missing_args <- c(missing_args, "indicator")
	if (missing(vintage))   missing_args <- c(missing_args, "vintage")
	if (missing(sector))    missing_args <- c(missing_args, "sector")

	if (length(missing_args) > 0) {
		stop(sprintf(
			"[cso_toolkit.dw_publish] Missing required argument(s): %s\n  Fix: pass non-empty single-string values for path, indicator, vintage, and sector.",
			paste(missing_args, collapse = ", ")
		), call. = FALSE)
	}

	# Now that every arg is present, force evaluation and check shape.
	check_shape <- function(nm, value) {
		if (is.null(value) || length(value) == 0L) return("empty")
		if (length(value) != 1L) return("invalid_shape")
		if (is.character(value) && !nzchar(value)) return("empty")
		"ok"
	}
	empty_args <- character(0)
	for (pair in list(list("path", path),
	                  list("indicator", indicator),
	                  list("vintage", vintage),
	                  list("sector", sector))) {
		status <- check_shape(pair[[1]], pair[[2]])
		if (status == "empty")          empty_args    <- c(empty_args,    pair[[1]])
		if (status == "invalid_shape")  invalid_shape <- c(invalid_shape, pair[[1]])
	}
	if (length(empty_args) > 0) {
		stop(sprintf(
			"[cso_toolkit.dw_publish] Empty required argument(s): %s\n  Fix: pass non-empty single-string values for path, indicator, vintage, and sector.",
			paste(empty_args, collapse = ", ")
		), call. = FALSE)
	}
	if (length(invalid_shape) > 0) {
		stop(sprintf(
			"[cso_toolkit.dw_publish] Argument(s) must be single strings (length 1): %s\n  Fix: pass a scalar character for each of path, indicator, vintage, sector -- not a vector.",
			paste(invalid_shape, collapse = ", ")
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
	vd <- .dw_vd(verbose, debug); v <- vd$v; d <- vd$d
	.dw_msg("dw_publish", "preparing ", endpoint, " submission for ", indicator, " (", vintage, ")", v = v)
	.dw_dbg("dw_publish", "path=", path, " sector=", sector, " dry_run=", dry_run, d = d)
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
		.dw_msg("dw_publish", "DRY RUN -- payload validated, nothing submitted (sha256 ", substr(payload$sha256, 1, 12), ")", v = v)
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
