# =============================================================================
# dw_provenance -- read provenance sidecars and compare two runs
# =============================================================================
#
# dw_save() writes a `<path>.provenance.json` sidecar beside every output: the
# output's SHA-256, schema, unique key, user, mode and a caller-supplied
# `metadata` block. When that block carries an `inputs` record (file + SHA-256
# per input, e.g. the manifest returned by dw_fetch_inputs()), the sidecar
# ties the output to the exact inputs it was built from.
#
#   dw_read_provenance()  reads the sidecar of an output;
#   dw_provenance_diff()  compares the sidecars of two runs of the same
#                         output and says whether the new run reproduced the
#                         previous one (same inputs, byte-identical output),
#                         whether the inputs changed, or whether the output
#                         changed although the inputs did not.
#
# Record-level differences are dw_compare()'s job; this file answers the
# run-level question first, from the sidecars alone.
#
# Mode contract: read-only; behaves identically in producer and reviewer
# sessions.
#
# R only. TODO: Python and Stata siblings; cross-language parity tracked at
# GitHub issue #152.

#' Read the provenance sidecar of an output
#'
#' Reads the `<path>.provenance.json` sidecar that [dw_save()] writes beside
#' each output. `path` may be the output itself or the sidecar.
#'
#' @param path Character. Path of the output file, or of its
#'   `.provenance.json` sidecar.
#' @param verbose Logical or `NULL`. Show high-level progress and result
#'   messages. `NULL` (default) inherits `getOption("dw.verbose", TRUE)`;
#'   set `TRUE`/`FALSE` to override for this call. See [dw_verbosity()].
#' @param debug Logical or `NULL`. Show internal troubleshooting detail
#'   (resolved paths, dims, branch decisions). `NULL` (default) inherits
#'   `getOption("dw.debug", FALSE)`; implies `verbose`. See [dw_verbosity()].
#'
#' @return The parsed sidecar as a list (`path`, `format`, `written_at`,
#'   `user`, `dw_mode`, `vintage`, `sha256`, `isid`, `schema`, `metadata`;
#'   see the provenance-schema appendix), with JSON arrays of records
#'   simplified to data frames (so `metadata$inputs` is a data frame).
#'   `NULL` when the sidecar does not exist.
#'
#' @section Errors:
#' Stops with a `[cso_toolkit.dw_read_provenance]` envelope when the sidecar
#' exists but is not valid JSON.
#'
#' @seealso [dw_save()] (writes the sidecar); [dw_provenance_diff()]
#'   (compares two runs); [dw_fetch_inputs()] (returns the input manifest to
#'   record in `metadata$inputs`).
#' @family io
#' @export
#' @examples
#' \dontrun{
#' prov <- dw_read_provenance("outputs/consolidated.csv")
#' prov$sha256
#' prov$metadata$inputs
#' }
dw_read_provenance <- function(path, verbose = NULL, debug = NULL) {
	vd <- .dw_vd(verbose, debug); v <- vd$v; d <- vd$d
	sidecar <- if (grepl("\\.provenance\\.json$", path)) path else paste0(path, ".provenance.json")
	.dw_dbg("dw_read_provenance", "sidecar=", sidecar, d = d)
	if (!file.exists(sidecar)) {
		.dw_msg("dw_read_provenance", "no provenance sidecar for ", basename(path), v = v)
		return(NULL)
	}
	.require("jsonlite")
	tryCatch(
		jsonlite::read_json(sidecar, simplifyVector = TRUE),
		error = function(e) stop(sprintf(
			"[cso_toolkit.dw_read_provenance] The provenance sidecar is not valid JSON: %s\n Parser said: %s\n Fix: rewrite the output with dw_save() to regenerate its sidecar, or restore the sidecar from version control.",
			sidecar, conditionMessage(e)), call. = FALSE)
	)
}

#' Coerce a run argument to a parsed sidecar (or NULL)
#'
#' @keywords internal
#' @noRd
.dw_as_provenance <- function(x, v, d) {
	if (is.null(x)) return(NULL)
	if (is.list(x)) return(x)
	if (is.character(x) && length(x) == 1) return(dw_read_provenance(x, verbose = v, debug = d))
	stop("[cso_toolkit.dw_provenance_diff] `previous` and `current` must be a path, a parsed sidecar (list), or NULL.\n Fix: pass the output path or the result of dw_read_provenance().",
	 call. = FALSE)
}

#' Input record of a parsed sidecar as a data frame (file, sha256), or NULL
#'
#' @keywords internal
#' @noRd
.dw_provenance_inputs <- function(prov, inputs_key) {
	rec <- prov$metadata[[inputs_key]]
	if (is.null(rec)) return(NULL)
	rec <- as.data.frame(rec, stringsAsFactors = FALSE)
	if (!all(c("file", "sha256") %in% names(rec))) return(NULL)
	rec[, c("file", "sha256"), drop = FALSE]
}

#' Compare the provenance of two runs of the same output
#'
#' Answers, from the [dw_save()] sidecars alone, whether a new run of a
#' pipeline reproduced the previous one. The inputs are compared through the
#' `metadata[[inputs_key]]` record of each sidecar (one row per input with
#' `file` and `sha256`, such as the manifest returned by
#' [dw_fetch_inputs()]); the outputs through the sidecars' `sha256`.
#'
#' The returned `status` is one of:
#' \describe{
#'   \item{`"reproduced"`}{Same inputs and a byte-identical output.}
#'   \item{`"output_changed"`}{Same inputs but a different output: the code
#'     or the environment changed. Warns (envelope) when `warn = TRUE`.}
#'   \item{`"inputs_changed"`}{Inputs were added, removed or changed; the
#'     lists are returned.}
#'   \item{`"first_run"`}{There is no previous sidecar.}
#'   \item{`"no_input_record"`}{A sidecar has no usable input record, so
#'     only the output hashes are compared (`same_output`).}
#' }
#'
#' Use [dw_compare()] next to see which records changed.
#'
#' @param previous Path of the previous output (or its sidecar), a parsed
#'   sidecar from [dw_read_provenance()], or `NULL`. Read it **before** the
#'   new run overwrites the output.
#' @param current Path of the new output (or its sidecar), or a parsed
#'   sidecar.
#' @param inputs_key Character. Name of the input record inside the
#'   sidecar's `metadata`. Default `"inputs"`.
#' @param warn Logical. Emit a warning when the status is
#'   `"output_changed"`. Default `TRUE`.
#' @param verbose Logical or `NULL`. Show high-level progress and result
#'   messages. `NULL` (default) inherits `getOption("dw.verbose", TRUE)`;
#'   set `TRUE`/`FALSE` to override for this call. See [dw_verbosity()].
#' @param debug Logical or `NULL`. Show internal troubleshooting detail
#'   (resolved paths, dims, branch decisions). `NULL` (default) inherits
#'   `getOption("dw.debug", FALSE)`; implies `verbose`. See [dw_verbosity()].
#'
#' @return A list: `status` (above), `same_inputs` and `same_output`
#'   (logical, `NA` when unknown), `inputs_added`, `inputs_removed` and
#'   `inputs_changed` (character vectors of input file names), and
#'   `previous_sha256` / `current_sha256`.
#'
#' @seealso [dw_read_provenance()]; [dw_compare()] (record-level diff);
#'   [dw_fetch_inputs()] (input manifest); [dw_save()].
#' @family io
#' @export
#' @examples
#' \dontrun{
#' previous <- dw_read_provenance(out_csv)   # before overwriting
#' dw_save(result, path = out_csv,
#'         metadata = list(inputs = manifest[, c("file", "sha256", "origin")]))
#' run <- dw_provenance_diff(previous, out_csv)
#' run$status
#' }
dw_provenance_diff <- function(previous, current, inputs_key = "inputs",
                               warn = TRUE, verbose = NULL, debug = NULL) {
	vd <- .dw_vd(verbose, debug); v <- vd$v; d <- vd$d
	prev <- .dw_as_provenance(previous, v, d)
	curr <- .dw_as_provenance(current, v, d)
	if (is.null(curr)) {
		stop("[cso_toolkit.dw_provenance_diff] The current output has no provenance sidecar.\n Fix: write the output with dw_save() (provenance = TRUE, the default) before comparing runs.",
		 call. = FALSE)
	}

	out <- list(status = NA_character_, same_inputs = NA, same_output = NA,
	            inputs_added = character(0), inputs_removed = character(0),
	            inputs_changed = character(0),
	            previous_sha256 = if (is.null(prev)) NA_character_ else (prev$sha256 %||% NA_character_),
	            current_sha256 = curr$sha256 %||% NA_character_)

	if (is.null(prev)) {
		out$status <- "first_run"
		.dw_msg("dw_provenance_diff", "first run: no previous provenance to compare with", v = v)
		return(out)
	}

	out$same_output <- identical(out$previous_sha256, out$current_sha256) &&
		!is.na(out$current_sha256)
	pin <- .dw_provenance_inputs(prev, inputs_key)
	cin <- .dw_provenance_inputs(curr, inputs_key)
	.dw_dbg("dw_provenance_diff", "previous sha=", out$previous_sha256, " | current sha=",
	        out$current_sha256, " | inputs prev/curr=", NROW(pin), "/", NROW(cin), d = d)

	if (is.null(pin) || is.null(cin)) {
		out$status <- "no_input_record"
		.dw_msg("dw_provenance_diff", "a sidecar has no '", inputs_key,
		        "' record, so only the outputs were compared: ",
		        if (out$same_output) "byte-identical" else "different", v = v)
		return(out)
	}

	out$inputs_added <- setdiff(cin$file, pin$file)
	out$inputs_removed <- setdiff(pin$file, cin$file)
	common <- intersect(cin$file, pin$file)
	out$inputs_changed <- common[cin$sha256[match(common, cin$file)] !=
	                             pin$sha256[match(common, pin$file)]]
	out$same_inputs <- length(out$inputs_added) + length(out$inputs_removed) +
		length(out$inputs_changed) == 0

	if (out$same_inputs && out$same_output) {
		out$status <- "reproduced"
		.dw_msg("dw_provenance_diff", "reproduced: same inputs (SHA-256) and a byte-identical output", v = v)
	} else if (out$same_inputs) {
		out$status <- "output_changed"
		if (isTRUE(warn)) {
			warning(sprintf(
				"[cso_toolkit.dw_provenance_diff] Same inputs as the previous run but a different output (SHA-256 %s -> %s).\n The code or the environment changed between the two runs.\n Fix: if the change is intended, record it (commit, NEWS); otherwise run dw_compare() on the two outputs to find the records that moved.",
				substr(out$previous_sha256, 1, 12), substr(out$current_sha256, 1, 12)), call. = FALSE)
		}
	} else {
		out$status <- "inputs_changed"
		.dw_msg("dw_provenance_diff", "inputs changed since the previous run:",
		        if (length(out$inputs_added)) paste0("\n  added:   ", paste(out$inputs_added, collapse = ", ")) else "",
		        if (length(out$inputs_removed)) paste0("\n  removed: ", paste(out$inputs_removed, collapse = ", ")) else "",
		        if (length(out$inputs_changed)) paste0("\n  changed: ", paste(out$inputs_changed, collapse = ", ")) else "",
		        v = v)
	}
	out
}
