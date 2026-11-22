# =============================================================================
# dw_deposit -- fetch pipeline inputs from the canonical deposit and verify them
# =============================================================================
#
# Some pipelines keep their raw inputs out of Git (Consult-tool exports,
# licensed microdata, large deliveries) in a local, gitignored folder of the
# consumer repository. Reproducibility then rests on the copy deposited in the
# canonical store: the Teams `060.DW-MASTER` folder and its Z: drive mirror.
#
#   dw_fetch_inputs()  fills the local folder from the deposit (or reads the
#                      deposit in place) and verifies every input;
#   dw_check_deposit() proves that every local input has an identical
#                      (SHA-256) copy in the deposit.
#
# Mode contract: both functions only READ the canonical deposit and only
# WRITE under `local_root`, so they behave identically in producer and
# reviewer sessions and never touch Teams or Z:.
#
# The deposit layout mirrors the consumer repository: a local folder
# `<repo>/<rel_dir>` corresponds to `<teamsFolderCanonical>/<rel_dir>` on
# Teams and `<dwZDrive>/<rel_dir>` on Z:.
#
# R and Python (python/src/dw_deposit.py); Stata routes via R or Python
# (#152). Parity case: conformance/cases/deposit_fetch_inputs.json.

# -----------------------------------------------------------------------------
# Internal helpers
# -----------------------------------------------------------------------------

#' SHA-256 of a file
#'
#' @param path Character. File path.
#' @return Character. Lower-case hex digest.
#' @keywords internal
#' @noRd
.dw_deposit_sha <- function(path) {
	.require("digest")
	digest::digest(file = path, algo = "sha256")
}

#' Resolve the deposit folders on Teams and Z: for a relative folder
#'
#' @param rel_dir Character. Folder relative to the deposit root.
#' @param teams_root,z_root Character or `NULL`. Deposit roots; `NULL` reads
#'   `teamsFolderCanonical` / `dwZDrive` (the latter only when
#'   `dw_z_available` is `TRUE`) from the session globals.
#' @return List with `teams` and `z` folder paths (`NA_character_` when
#'   unavailable).
#' @keywords internal
#' @noRd
.dw_deposit_dirs <- function(rel_dir, teams_root = NULL, z_root = NULL) {
	if (is.null(teams_root)) teams_root <- .try_get("teamsFolderCanonical")
	if (is.null(z_root)) {
		z_root <- if (isTRUE(.try_get("dw_z_available"))) .try_get("dwZDrive") else NA_character_
	}
	join <- function(root) {
		if (is.null(root) || length(root) != 1 || is.na(root) || !nzchar(root)) {
			return(NA_character_)
		}
		if (!dir.exists(root)) return(NA_character_)
		file.path(root, rel_dir)
	}
	list(teams = join(teams_root), z = join(z_root))
}

#' Files under a folder matching a pattern, relative to the folder
#'
#' @keywords internal
#' @noRd
.dw_deposit_list <- function(dir, pattern = NULL) {
	if (is.na(dir) || !dir.exists(dir)) return(character(0))
	files <- list.files(dir, pattern = pattern, recursive = TRUE)
	# never treat a folder placeholder or an interrupted fetch as an input
	files[!grepl("(^|/)\\.gitkeep$|\\.dw_fetch\\.tmp$", files)]
}

#' Subfolders under a folder, relative to it (`character(0)` if absent)
#'
#' @keywords internal
#' @noRd
.dw_deposit_subdirs <- function(dir) {
	if (is.na(dir) || !dir.exists(dir)) return(character(0))
	setdiff(list.dirs(dir, full.names = FALSE, recursive = TRUE), "")
}

#' Make sure a folder tree exists locally, each folder holding a `.gitkeep`
#'
#' Git does not track empty folders, so an empty `.gitkeep` placeholder keeps
#' each folder visible in every clone (the consumer's `.gitignore` must not
#' ignore `.gitkeep` files for that to work).
#'
#' @param root Character. Local root folder.
#' @param subdirs Character. Subfolders relative to `root`.
#' @return Invisibly, the number of `.gitkeep` files created.
#' @keywords internal
#' @noRd
.dw_deposit_gitkeep <- function(root, subdirs = character(0)) {
	created <- 0L
	for (d in unique(c(root, file.path(root, subdirs)))) {
		dir.create(d, recursive = TRUE, showWarnings = FALSE)
		keep <- file.path(d, ".gitkeep")
		if (!file.exists(keep) && isTRUE(file.create(keep))) created <- created + 1L
	}
	invisible(created)
}

#' Compare one file (by size and hash) with one deposit copy
#'
#' @return One of `"match"`, `"differs"`, `"missing"`, `"no access"`.
#' @keywords internal
#' @noRd
.dw_deposit_compare <- function(copy_path, size, sha) {
	if (is.na(copy_path)) return("no access")
	if (!file.exists(copy_path)) return("missing")
	if (!identical(file.size(copy_path), size)) return("differs")
	if (identical(.dw_deposit_sha(copy_path), sha)) "match" else "differs"
}

#' Copy a file, verify the copy's SHA-256, then move it into place
#'
#' Copies to `<dest>.dw_fetch.tmp`, checks the hash against the source, and
#' renames onto `dest`, so a partial copy never appears as an input. One
#' retry. Same atomic-rename pattern as [dw_stage()].
#'
#' @return Character. The SHA-256 of the copied file.
#' @keywords internal
#' @noRd
.dw_deposit_copy <- function(src, dest) {
	dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
	tmp <- paste0(dest, ".dw_fetch.tmp")
	src_sha <- .dw_deposit_sha(src)
	for (attempt in 1:2) {
		if (file.exists(tmp)) file.remove(tmp)
		copied <- isTRUE(file.copy(src, tmp, overwrite = TRUE, copy.date = TRUE))
		if (copied && identical(.dw_deposit_sha(tmp), src_sha) &&
		 isTRUE(file.rename(tmp, dest))) {
			return(src_sha)
		}
	}
	if (file.exists(tmp)) file.remove(tmp)
	stop(sprintf(
		"[cso_toolkit.dw_fetch_inputs] Could not copy '%s' from the deposit.\n Source: %s\n Target: %s\n The copy failed or its SHA-256 did not match the source, twice.\n Fix: make sure the source is fully synced (OneDrive) or Z: is reachable, and that the target folder is writable; then rerun.",
		basename(dest), src, dest), call. = FALSE)
}

#' Text block naming the deposit folders, for messages
#'
#' @keywords internal
#' @noRd
.dw_deposit_where <- function(dirs) {
	paste0(
		" Teams: ", if (is.na(dirs$teams)) "(not available)" else dirs$teams, "\n",
		" Z:     ", if (is.na(dirs$z)) "(not available)" else dirs$z
	)
}

# -----------------------------------------------------------------------------
# Public entry points
# -----------------------------------------------------------------------------

#' Check that local input files are deposited on Teams or Z:
#'
#' For every file in `paths` (which must lie under `local_root`), looks for
#' the file at the same relative path in the canonical deposit,
#' `<teams_root>/<rel_dir>` and `<z_root>/<rel_dir>`, and compares the two by
#' size and SHA-256. A file passes when an identical copy exists on Teams
#' **or** on Z:, and no copy that exists differs. Z: being unmounted is not a
#' failure when Teams holds an identical copy.
#'
#' Use it at the top of a pipeline whose inputs are kept out of Git, so a run
#' can only proceed on inputs that someone else can retrieve from the
#' deposit. [dw_fetch_inputs()] calls it after fetching.
#'
#' @param paths Character. Full paths of the local input files to check.
#' @param local_root Character. The local folder that mirrors `rel_dir`
#'   (for example `<repo>/02_consultations/023_targets/inputs`). Each path's
#'   location relative to it is the location looked up in the deposit.
#' @param rel_dir Character. The same folder relative to the deposit root
#'   (for example `"02_consultations/023_targets/inputs"`).
#' @param teams_root Character or `NULL`. Teams deposit root. `NULL`
#'   (default) uses the session's `teamsFolderCanonical`.
#' @param z_root Character or `NULL`. Z: deposit root. `NULL` (default) uses
#'   the session's `dwZDrive` when `dw_z_available` is `TRUE`.
#' @param stop_on_fail Logical. Stop with an error envelope when any file
#'   fails (default `TRUE`). When `FALSE`, return the report and let the
#'   caller decide.
#' @param verbose Logical or `NULL`. Show high-level progress and result
#'   messages. `NULL` (default) inherits `getOption("dw.verbose", TRUE)`;
#'   set `TRUE`/`FALSE` to override for this call. See [dw_verbosity()].
#' @param debug Logical or `NULL`. Show internal troubleshooting detail
#'   (resolved paths, dims, branch decisions). `NULL` (default) inherits
#'   `getOption("dw.debug", FALSE)`; implies `verbose`. See [dw_verbosity()].
#'
#' @return Invisibly, a data frame with one row per file: `file` (path
#'   relative to `local_root`), `sha256`, `teams` and `z` (each one of
#'   `"match"`, `"differs"`, `"missing"`, `"no access"`), and `ok`
#'   (logical).
#'
#' @section Errors:
#' Stops with a `[cso_toolkit.dw_check_deposit]` envelope when neither
#' deposit root is reachable, when a path lies outside `local_root`, or
#' (with `stop_on_fail = TRUE`) when any file is missing from the deposit
#' or differs from a deposited copy.
#'
#' @seealso [dw_fetch_inputs()] (fetches missing inputs, then calls this);
#'   [dw_verify_z()] (Teams vs Z: for one canonical file); [dw_stage()]
#'   (reviewer-mode staging with a `.staged.json` sidecar).
#' @family io
#' @export
#' @examples
#' \dontrun{
#' rel  <- "02_consultations/023_targets/inputs"
#' root <- file.path(projectFolder, rel)
#' files <- list.files(root, pattern = "_20(23|24|25)\\.csv$",
#'                     recursive = TRUE, full.names = TRUE)
#' dw_check_deposit(files, local_root = root, rel_dir = rel)
#' }
dw_check_deposit <- function(paths, local_root, rel_dir,
                             teams_root = NULL, z_root = NULL,
                             stop_on_fail = TRUE,
                             verbose = NULL, debug = NULL) {
	vd <- .dw_vd(verbose, debug); v <- vd$v; d <- vd$d
	dirs <- .dw_deposit_dirs(rel_dir, teams_root, z_root)
	.dw_dbg("dw_check_deposit", "teams=", dirs$teams, " | z=", dirs$z, d = d)

	if (is.na(dirs$teams) && is.na(dirs$z)) {
		stop(paste0(
			"[cso_toolkit.dw_check_deposit] Cannot verify the inputs: neither the Teams deposit nor Z: is available.\n",
			" The check needs teamsFolderCanonical (Teams) or dwZDrive with dw_z_available = TRUE (Z:).\n",
			" Fix: source the consumer profile (it sets those globals), make sure the Teams folder is synced, or connect to Z: (VPN); then rerun."
		), call. = FALSE)
	}

	root_n <- sub("/+$", "", normalizePath(local_root, winslash = "/", mustWork = FALSE))
	paths_n <- normalizePath(paths, winslash = "/", mustWork = FALSE)
	outside <- !startsWith(paths_n, paste0(root_n, "/"))
	if (any(outside)) {
		stop(sprintf(
			"[cso_toolkit.dw_check_deposit] %d path(s) are not under local_root (%s), so their deposit location is undefined:\n %s\n Fix: pass the files that live under local_root, or set local_root to the folder that mirrors rel_dir.",
			sum(outside), root_n, paste(paths[outside], collapse = "\n ")), call. = FALSE)
	}
	rel <- substring(paths_n, nchar(root_n) + 2)

	report <- data.frame(file = rel, sha256 = NA_character_,
	                     teams = NA_character_, z = NA_character_,
	                     stringsAsFactors = FALSE)
	for (i in seq_along(paths_n)) {
		size <- file.size(paths_n[i])
		sha <- .dw_deposit_sha(paths_n[i])
		report$sha256[i] <- sha
		report$teams[i] <- .dw_deposit_compare(
			if (is.na(dirs$teams)) NA_character_ else file.path(dirs$teams, rel[i]), size, sha)
		report$z[i] <- .dw_deposit_compare(
			if (is.na(dirs$z)) NA_character_ else file.path(dirs$z, rel[i]), size, sha)
	}
	deposited <- report$teams == "match" | report$z == "match"
	differs <- report$teams == "differs" | report$z == "differs"
	report$ok <- deposited & !differs

	table_text <- paste(utils::capture.output(print(
		report[, c("file", "teams", "z")], row.names = FALSE, right = FALSE)),
		collapse = "\n ")

	if (any(!report$ok) && isTRUE(stop_on_fail)) {
		fixes <- character(0)
		if (any(!deposited & !differs)) fixes <- c(fixes,
			" - missing: copy the file to the Teams deposit folder above (same relative path) and let OneDrive sync.")
		if (any(differs)) fixes <- c(fixes,
			" - differs: the local file and the deposited copy are not the same; decide which is correct and replace the other.")
		stop(paste0(
			"[cso_toolkit.dw_check_deposit] Deposit check failed for ", sum(!report$ok),
			" of ", nrow(report), " input file(s).\n ",
			table_text, "\n",
			" Deposit folders checked:\n", .dw_deposit_where(dirs), "\n",
			" Each local input needs an identical copy (same SHA-256) on Teams or Z:, at the same relative path.\n",
			" Fix:\n", paste(fixes, collapse = "\n")
		), call. = FALSE)
	}

	.dw_msg("dw_check_deposit", sum(report$ok), " of ", nrow(report),
	        " input file(s) match a copy in the deposit.\n ", table_text, "\n",
	        .dw_deposit_where(dirs), v = v)
	invisible(report)
}

#' Fetch pipeline inputs from the canonical deposit, then verify them
#'
#' For pipelines whose inputs are kept out of Git in a local folder that
#' mirrors a folder of the canonical deposit (Teams `060.DW-MASTER` and its
#' Z: mirror). In order:
#'
#' 1. Lists the input files (matching `pattern`) in `local_root` and in the
#'    deposit folder `<root>/<rel_dir>` on Teams and on Z:.
#' 2. Stops if Teams and Z: hold different versions of the same file.
#' 3. Files in the deposit but not in `local_root`: with `copy = TRUE`
#'    (default) copies them into `local_root` at the same relative path,
#'    preferring Z: as [dw_stage()] does, and verifies each copy's SHA-256;
#'    with `copy = FALSE` leaves `local_root` untouched and returns their
#'    deposit paths, so the caller reads them in place.
#' 4. With `gitkeep = TRUE` (default), makes sure `local_root` and every
#'    subfolder found locally or in the deposit exist locally, each holding
#'    an empty `.gitkeep`, so the folder layout stays visible even when the
#'    files themselves are gitignored or not copied. `.gitkeep` files are
#'    never treated as inputs.
#' 5. Calls [dw_check_deposit()] on every local file, so a local file that
#'    is missing from the deposit or differs from it stops the run.
#'
#' Stops if no input file exists locally or in the deposit. The returned
#' manifest records each input's SHA-256 and origin; pass it to
#' [dw_save()]'s `metadata` so the output's `.provenance.json` sidecar names
#' the exact inputs it was built from.
#'
#' @param local_root Character. The local inputs folder (created if
#'   missing when files are copied).
#' @param rel_dir Character. The same folder relative to the deposit root
#'   (for example `"02_consultations/023_targets/inputs"`).
#' @param pattern Character or `NULL`. Regular expression selecting input
#'   files (matched against file names, searched recursively). `NULL`
#'   (default) selects every file; pass a pattern so documentation files
#'   such as a folder `README.md` are not treated as inputs.
#' @param copy Logical. `TRUE` (default) copies deposit-only files into
#'   `local_root`; `FALSE` reads them in place from the deposit.
#' @param gitkeep Logical. `TRUE` (default) creates `local_root` and the
#'   local and deposit subfolders under it, each with an empty `.gitkeep`, so
#'   the folders are always visible locally and can be tracked by Git. For a
#'   gitignored inputs folder, the consumer's `.gitignore` needs an exception
#'   such as `!<rel_dir>/**/` plus `!<rel_dir>/**/.gitkeep`. `FALSE` creates
#'   only the folders a copy needs.
#' @param teams_root Character or `NULL`. Teams deposit root. `NULL`
#'   (default) uses the session's `teamsFolderCanonical`.
#' @param z_root Character or `NULL`. Z: deposit root. `NULL` (default) uses
#'   the session's `dwZDrive` when `dw_z_available` is `TRUE`.
#' @param verbose Logical or `NULL`. Show high-level progress and result
#'   messages. `NULL` (default) inherits `getOption("dw.verbose", TRUE)`;
#'   set `TRUE`/`FALSE` to override for this call. See [dw_verbosity()].
#' @param debug Logical or `NULL`. Show internal troubleshooting detail
#'   (resolved paths, dims, branch decisions). `NULL` (default) inherits
#'   `getOption("dw.debug", FALSE)`; implies `verbose`. See [dw_verbosity()].
#'
#' @return A data frame (the input manifest), one row per input file:
#'   `file` (path relative to `local_root` / `rel_dir`), `path` (the full
#'   path to read), `sha256`, `origin` (`"local"`, `"copied from Z:"`,
#'   `"copied from Teams"`, `"read from Z:"` or `"read from Teams"`), and
#'   `teams` / `z` (deposit status, as in [dw_check_deposit()]).
#'
#' @section Errors:
#' Stops with a `[cso_toolkit.dw_fetch_inputs]` envelope when no input file
#' exists anywhere, when Teams and Z: disagree on a file, or when a copy
#' cannot be verified; and with a `[cso_toolkit.dw_check_deposit]` envelope
#' when a local input is missing from the deposit or differs from it.
#'
#' @seealso [dw_check_deposit()]; [dw_stage()] (reviewer-mode staging of a
#'   single canonical file into the sandbox); [dw_save()] (write outputs
#'   with a `.provenance.json` sidecar).
#' @family io
#' @export
#' @examples
#' \dontrun{
#' manifest <- dw_fetch_inputs(
#'   local_root = file.path(projectFolder, "02_consultations/023_targets/inputs"),
#'   rel_dir    = "02_consultations/023_targets/inputs",
#'   pattern    = "_20(23|24|25)\\.(csv|txt)$"
#' )
#' data <- lapply(manifest$path, readr::read_csv)
#'
#' # record the exact inputs in the output's provenance sidecar
#' dw_save(result, path = out_csv,
#'         metadata = list(inputs = manifest[, c("file", "sha256", "origin")]))
#' }
dw_fetch_inputs <- function(local_root, rel_dir, pattern = NULL, copy = TRUE,
                            gitkeep = TRUE,
                            teams_root = NULL, z_root = NULL,
                            verbose = NULL, debug = NULL) {
	vd <- .dw_vd(verbose, debug); v <- vd$v; d <- vd$d
	dirs <- .dw_deposit_dirs(rel_dir, teams_root, z_root)
	.dw_dbg("dw_fetch_inputs", "local=", local_root, " | teams=", dirs$teams,
	        " | z=", dirs$z, " | copy=", copy, d = d)

	local_rel <- .dw_deposit_list(local_root, pattern)
	teams_rel <- .dw_deposit_list(dirs$teams, pattern)
	z_rel <- .dw_deposit_list(dirs$z, pattern)

	if (length(local_rel) + length(teams_rel) + length(z_rel) == 0) {
		stop(paste0(
			"[cso_toolkit.dw_fetch_inputs] No input files",
			if (is.null(pattern)) "" else paste0(" matching '", pattern, "'"),
			" were found locally or in the deposit.\n",
			" Local: ", normalizePath(local_root, winslash = "/", mustWork = FALSE), "\n",
			.dw_deposit_where(dirs), "\n",
			" Fix: deposit the input files in the Teams folder above (same relative layout as the local folder) and rerun",
			if (is.na(dirs$teams) && is.na(dirs$z))
				"; the deposit is not reachable either, so also source the consumer profile, sync Teams, or connect to Z:." else "."
		), call. = FALSE)
	}

	# Teams and Z: must agree wherever both hold a file.
	for (f in intersect(teams_rel, z_rel)) {
		tp <- file.path(dirs$teams, f); zp <- file.path(dirs$z, f)
		if (!identical(file.size(tp), file.size(zp)) ||
		 !identical(.dw_deposit_sha(tp), .dw_deposit_sha(zp))) {
			stop(sprintf(
				"[cso_toolkit.dw_fetch_inputs] Teams and Z: hold different versions of '%s'.\n Teams: %s\n Z:     %s\n The deposit must have one version of each input before any run uses it.\n Fix: decide which version is correct, replace the other, and rerun.",
				f, tp, zp), call. = FALSE)
		}
	}

	deposit_only <- setdiff(union(z_rel, teams_rel), local_rel)
	src_of <- function(f) if (f %in% z_rel) file.path(dirs$z, f) else file.path(dirs$teams, f)
	mirror_of <- function(f) if (f %in% z_rel) "Z:" else "Teams"

	copied <- character(0)
	in_place <- data.frame(file = character(0), path = character(0),
	                       sha256 = character(0), origin = character(0),
	                       teams = character(0), z = character(0),
	                       stringsAsFactors = FALSE)

	if (length(deposit_only) > 0 && isTRUE(copy)) {
		.dw_msg("dw_fetch_inputs", "copying ", length(deposit_only),
		        " input file(s) from the deposit into ", local_root, v = v)
		for (f in deposit_only) {
			.dw_deposit_copy(src_of(f), file.path(local_root, f))
			.dw_msg("dw_fetch_inputs", "  copied ", f, " (from ", mirror_of(f), ")", v = v)
		}
		copied <- deposit_only
		local_rel <- c(local_rel, deposit_only)
	} else if (length(deposit_only) > 0) {
		.dw_msg("dw_fetch_inputs", "copy = FALSE: reading ", length(deposit_only),
		        " input file(s) in place from the deposit", v = v)
		for (f in deposit_only) {
			src <- src_of(f)
			sha <- .dw_deposit_sha(src)
			size <- file.size(src)
			in_place[nrow(in_place) + 1, ] <- list(
				f, src, sha, paste0("read from ", mirror_of(f)),
				.dw_deposit_compare(if (is.na(dirs$teams)) NA_character_ else file.path(dirs$teams, f), size, sha),
				.dw_deposit_compare(if (is.na(dirs$z)) NA_character_ else file.path(dirs$z, f), size, sha))
		}
	}

	if (isTRUE(gitkeep)) {
		subdirs <- unique(c(.dw_deposit_subdirs(local_root),
		                    .dw_deposit_subdirs(dirs$teams),
		                    .dw_deposit_subdirs(dirs$z)))
		n_keep <- .dw_deposit_gitkeep(local_root, subdirs)
		.dw_dbg("dw_fetch_inputs", "gitkeep: ", n_keep, " placeholder(s) created under ",
		        local_root, d = d)
	}

	manifest <- in_place
	if (length(local_rel) > 0) {
		local_paths <- file.path(local_root, local_rel)
		report <- dw_check_deposit(local_paths, local_root, rel_dir,
		                           teams_root = teams_root, z_root = z_root,
		                           verbose = v, debug = d)
		origin <- ifelse(report$file %in% copied,
		                 paste0("copied from ", vapply(report$file, mirror_of, character(1))),
		                 "local")
		manifest <- rbind(
			data.frame(file = report$file, path = local_paths, sha256 = report$sha256,
			           origin = unname(origin), teams = report$teams, z = report$z,
			           stringsAsFactors = FALSE),
			manifest)
	}

	manifest <- manifest[order(manifest$file), , drop = FALSE]
	rownames(manifest) <- NULL
	manifest
}
