# =============================================================================
# dw_project -- set the project-level collaboration model (cso_project.yml)
# =============================================================================
#
# Session MODES stay per person: `dw_mode` (producer | reviewer) comes from
# each user's ~/.config/user_config.yml. How many people may PRODUCE is a
# property of the PROJECT, committed in the repository as `cso_project.yml`
# (schema: cso_project/1; collaboration: single-producer | multi-producer;
# collaboration_since; optional members).
#
# This file holds the admin action that changes the setting:
#
#   dw_set_collaboration()  write cso_project.yml and baseline the existing
#                           sidecars, in one reviewed commit.
#
# Reading the setting (dw_collaboration()), the session state and the
# multi-producer guards used by dw_save() live in dw_io.R, so a consumer
# that vendors only dw_io.R still honours a multi-producer project.
# Vendor this file too to switch a project with dw_set_collaboration().
#
# Python sibling: python/src/dw_project.py (same file, keys, envelopes and
# sidecar fields). Stata: not yet (issue #168).

#' Insert a `baseline` object into a sidecar's JSON text, byte-preserving
#'
#' Adds `"baseline": {...}` as the last member of the top-level object and
#' leaves every other byte as it was, so `sha256` and every other field are
#' untouched. Returns `NULL` when the sidecar is skipped (not a JSON object,
#' already baselined, or written under a multi-producer project).
#' @keywords internal
#' @noRd
.dw_baseline_text <- function(txt, baseline) {
	parsed <- tryCatch(jsonlite::fromJSON(txt, simplifyVector = FALSE), error = function(e) NULL)
	if (!is.list(parsed) || (length(parsed) > 0 && is.null(names(parsed)))) return(NULL)
	if (!is.null(parsed$baseline) || !is.null(parsed$collaboration)) return(NULL)
	pos <- max(gregexpr("}", txt, fixed = TRUE)[[1]])
	if (pos < 1) return(NULL)
	nl <- if (grepl("\r\n", txt, fixed = TRUE)) "\r\n" else "\n"
	before <- sub("[[:space:]]+$", "", substr(txt, 1, pos - 1))
	after <- substr(txt, pos, nchar(txt))
	val <- function(x) as.character(jsonlite::toJSON(x, auto_unbox = TRUE))
	member <- paste0(
		"  \"baseline\": {", nl,
		"    \"collaboration\": ", val(baseline$collaboration), ",", nl,
		"    \"at\": ", val(baseline$at), ",", nl,
		"    \"by\": ", val(baseline$by), nl,
		"  }")
	sep <- if (endsWith(before, "{")) nl else paste0(",", nl)
	out <- paste0(before, sep, member, nl, after)
	# Self-check: the result parses and every original field is unchanged.
	chk <- tryCatch(jsonlite::fromJSON(out, simplifyVector = FALSE), error = function(e) NULL)
	if (is.null(chk) || !identical(chk[names(parsed)], parsed)) return(NULL)
	out
}

#' Render cso_project.yml text (identical in R and Python)
#' @keywords internal
#' @noRd
.dw_project_yaml <- function(model, since, members = NULL, extra = list()) {
	lines <- c(
		"# cso_project.yml -- project-level cso-toolkit settings. Commit this file.",
		"# Session modes (dw_mode: producer | reviewer) stay per person in",
		"# ~/.config/user_config.yml; this file says how many people may produce.",
		"# Change it with dw_set_collaboration() in one reviewed pull request.",
		paste0("schema: ", .DW_PROJECT_SCHEMA),
		paste0("collaboration: ", model),
		paste0("collaboration_since: ", since)
	)
	if (length(members)) {
		lines <- c(lines, "members:", paste0("  - ", members))
	}
	if (length(extra)) {
		lines <- c(lines, sub("\n$", "", yaml::as.yaml(extra)))
	}
	paste0(paste(lines, collapse = "\n"), "\n")
}

#' Set the project's collaboration model (cso_project.yml)
#'
#' Writes or updates `cso_project.yml` at `root` and, with
#' `baseline = TRUE`, adds a `baseline` object (`collaboration`, `at`, `by`)
#' to every existing `*.provenance.json` under `root`. The baseline marks
#' artefacts that predate the switch as **project-owned**, so the first
#' multi-producer write over them is not reported as a change of producer
#' and their lineage chain starts cleanly. The baseline is inserted as text:
#' `sha256` and every other field of the sidecar are left byte-for-byte as
#' they were.
#'
#' Idempotent: a second call with the same arguments changes nothing (the
#' file is rewritten only when the model or members change, and sidecars
#' that already carry a `baseline`, or that were written under a
#' multi-producer project, are skipped). Commit the result as one reviewed
#' pull request, so every collaborator switches at the same commit.
#'
#' @param model Character. `"single-producer"` or `"multi-producer"`.
#' @param root Character or `NULL`. Repository root that holds (or will
#'   hold) `cso_project.yml`. `NULL` (default) uses the profile's
#'   `rootFolder` global, else the working directory.
#' @param members Character vector or `NULL`. Informational list of the
#'   collaborators' user names or handles. `NULL` keeps the current list.
#' @param baseline Logical. Add the `baseline` object to existing sidecars.
#'   Default `TRUE`.
#' @param verbose Logical or `NULL`. Show high-level progress and result
#'   messages. `NULL` (default) inherits `getOption("dw.verbose", TRUE)`;
#'   set `TRUE`/`FALSE` to override for this call. See [dw_verbosity()].
#' @param debug Logical or `NULL`. Show internal troubleshooting detail.
#'   `NULL` (default) inherits `getOption("dw.debug", FALSE)`; implies
#'   `verbose`. See [dw_verbosity()].
#'
#' @return Invisibly, a list: `project_file`, `collaboration`,
#'   `project_file_changed` (logical), `sidecars_found`, `sidecars_updated`
#'   (counts) and `updated` (paths of the sidecars that gained a baseline).
#'
#' @section Errors:
#' Stops with a `[cso_toolkit.dw_set_collaboration]` envelope in reviewer
#' mode (the call writes), for an unknown `model`, or when `root` does not
#' exist.
#'
#' @seealso [dw_collaboration()]; [dw_save()].
#' @family collaboration
#' @export
#' @examples
#' \dontrun{
#' # One reviewed PR: switch the project, baseline the existing sidecars.
#' dw_set_collaboration("multi-producer", root = rootFolder,
#'                      members = c("jpazevedo", "kbarnes"))
#' }
dw_set_collaboration <- function(model = c("single-producer", "multi-producer"),
                                 root = NULL, members = NULL, baseline = TRUE,
                                 verbose = NULL, debug = NULL) {
	vd <- .dw_vd(verbose, debug); v <- vd$v; d <- vd$d
	if (!(is.character(model) && length(model) == 1 && model %in% .DW_COLLAB_MODELS)) {
		stop(sprintf(
			"[cso_toolkit.dw_set_collaboration] Unknown collaboration model '%s'.\n Fix: pass 'single-producer' or 'multi-producer'.",
			paste(model, collapse = ", ")), call. = FALSE)
	}
	if (isTRUE(.try_get("dw_mode") == "reviewer")) {
		stop("[cso_toolkit.dw_set_collaboration] Reviewer mode cannot change the project's collaboration model: the call writes cso_project.yml and the provenance sidecars.\n Fix: run it in a producer session, then open one pull request with the result for review.",
		     call. = FALSE)
	}
	root <- root %||% .try_get("rootFolder") %||% getwd()
	if (!dir.exists(root)) {
		stop(sprintf(
			"[cso_toolkit.dw_set_collaboration] Folder not found: %s\n Fix: pass the repository root as `root`.",
			root), call. = FALSE)
	}
	file <- file.path(root, .DW_PROJECT_FILE)
	me <- .dw_current_user()
	now <- .dw_now_iso()

	# --- cso_project.yml ---
	old <- if (file.exists(file)) .dw_read_project(file) else NULL
	keep_members <- if (is.null(members)) old$members else as.character(members)
	changed <- is.null(old) || !identical(old$collaboration, model) ||
		(!is.null(members) && !identical(old$members, keep_members))
	if (changed) {
		since <- if (!is.null(old) && identical(old$collaboration, model) && !is.null(old$collaboration_since)) {
			old$collaboration_since
		} else format(Sys.Date(), "%Y-%m-%d")
		extra <- if (is.null(old)) list() else
			old[setdiff(names(old), c("schema", "collaboration", "collaboration_since", "members", "file"))]
		# writeBin, not writeLines: LF line endings on every platform (a text
		# connection would write CRLF on Windows), matching the Python sibling.
		writeBin(charToRaw(.dw_project_yaml(model, since, keep_members, extra)), file)
		.dw_msg("dw_set_collaboration", "wrote ", file, ": collaboration = ", model, v = v)
	} else {
		.dw_msg("dw_set_collaboration", file, " already sets collaboration = ", model, "; unchanged", v = v)
	}

	# --- baseline the existing sidecars ---
	sidecars <- list.files(root, pattern = "\\.provenance\\.json$", recursive = TRUE,
	                       full.names = TRUE, all.files = TRUE)
	sidecars <- sidecars[!grepl("(^|/)\\.git/", sidecars)]
	updated <- character(0)
	if (isTRUE(baseline)) {
		bl <- list(collaboration = model, at = now, by = me)
		for (sc in sidecars) {
			new <- tryCatch(
				.dw_baseline_text(rawToChar(readBin(sc, "raw", n = file.info(sc)$size)), bl),
				error = function(e) NULL)
			if (is.null(new)) next
			tmp <- paste0(sc, ".tmp")
			writeBin(charToRaw(new), tmp)
			if (!file.rename(tmp, sc)) {
				unlink(tmp)
				warning(sprintf(
					"[cso_toolkit.dw_set_collaboration] Could not update %s.\n Fix: close any program holding the file and run dw_set_collaboration() again (it skips sidecars already baselined).",
					sc), call. = FALSE)
				next
			}
			updated <- c(updated, sc)
		}
		.dw_msg("dw_set_collaboration", "baselined ", length(updated), " of ",
		        length(sidecars), " provenance sidecar(s) under ", root, v = v)
	}
	.dw_dbg("dw_set_collaboration", "updated: ", paste(basename(updated), collapse = ", "), d = d)

	# The session now follows the new setting.
	.dw_set_global("dw_collaboration_model", model)
	.dw_set_global("dw_project_file", file)
	.dw_session_start()

	invisible(list(project_file = file, collaboration = model,
	               project_file_changed = changed,
	               sidecars_found = length(sidecars),
	               sidecars_updated = length(updated),
	               updated = updated))
}
