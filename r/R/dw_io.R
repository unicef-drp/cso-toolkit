#-------------------------------------------------------------------
# 00_functions/dw_io.R
# Purpose: Uniform read/write helpers for DW-Production R scripts.
#          Auto-dispatch by file extension; supports every IO form the
#          sector scripts currently use; enforces the reviewer/producer
#          contract for writes; mirrors canonical writes to Z: and
#          verifies canonical reads against Z: when the drive is mounted.
#
# Mode is a SESSION property only — set by `dw_mode` in
# ~/.config/user_config.yml and read by profile_DW-Production.R. It is
# NOT a per-call argument on dw_save/dw_use. Path globals (teamsWrkData,
# teamsRawData, dwWrkData, etc.) are already mode-aware in the profile;
# the helpers below resolve through them.
#
# Public entry points:
#   dw_save(x, path|name, ..., isid = NULL, metadata = NULL)
#   dw_use(path|name, ..., as = "tibble")
#   dw_compare(current, reference, by, value_cols, ...)
#   dw_resolve_path(name, sector, kind, vintage)
#   dw_is_canonical(path)
#   dw_verify_z(path, compare = "size" | "sha256")
#   dw_merge(x, using, by, how)
#
# Added: 2026-05-23 (reviewer-mode audit). Auto-sourced by the profile
#        via `dwFunct`; no per-script source() needed.
#-------------------------------------------------------------------

# ============================================================================
# Helpers
# ============================================================================

`%||%` <- function(a, b) if (is.null(a) || (length(a) == 1 && is.na(a))) b else a

.require <- function(pkg) {
	if (!requireNamespace(pkg, quietly = TRUE)) {
		stop(sprintf("Package '%s' is required for this file format. ", pkg),
		     "Install via `install.packages('", pkg, "')`.")
	}
	invisible(TRUE)
}

.try_get <- function(name) tryCatch(get(name, envir = .GlobalEnv),
                                    error = function(e) NA_character_)

#' Filesystem root for a given `kind`. Reads session-level globals (which
#' are already mode-aware in profile_DW-Production.R).
.dw_root_for <- function(kind = c("wrk", "raw", "meta")) {
	kind <- match.arg(kind)
	switch(kind,
		wrk  = .try_get("teamsWrkData"),
		raw  = .try_get("teamsRawData"),
		meta = .try_get("dwMetaData")
	)
}

# ============================================================================
# Path resolution
# ============================================================================

#' Resolve a logical DW path to a filesystem path
#'
#' Two call styles:
#'   - Path-string:  dw_resolve_path(path = "ed/dw_ed_edu.csv", kind = "wrk")
#'   - Structured:   dw_resolve_path(name = "dw_ed_edu.csv", sector = "ed",
#'                                   kind = "wrk")
#'
#' kind: "wrk" | "raw" | "meta"
#' vintage: optional subfolder (YYYY-MM, YYYY-MM-DD, etc.)
dw_resolve_path <- function(path = NULL, name = NULL, sector = NULL,
                            kind = c("wrk", "raw", "meta"),
                            vintage = NULL) {
	kind <- match.arg(kind)
	root <- .dw_root_for(kind = kind)
	if (is.na(root) || !nzchar(root)) {
		stop("dw_resolve_path: root for kind='", kind,
		     "' is not defined. Is the profile loaded?")
	}
	subpath <- if (!is.null(name)) {
		file.path(sector %||% "", if (!is.null(vintage)) vintage else "", name)
	} else if (!is.null(path)) {
		path
	} else {
		stop("dw_resolve_path: provide either `path` or `name` (with optional sector / vintage).")
	}
	subpath <- gsub("/+", "/", subpath)
	subpath <- sub("^/", "", subpath)
	file.path(root, subpath)
}

#' Is `path` under one of the canonical deposit roots?
dw_is_canonical <- function(path) {
	path_n <- normalizePath(path, winslash = "/", mustWork = FALSE)
	canon_roots <- c(
		.try_get("teamsWrkDataCanonical"),
		.try_get("teamsRawDataCanonical"),
		.try_get("teamsFolderCanonical")
	)
	canon_roots <- canon_roots[!is.na(canon_roots) & nzchar(canon_roots)]
	if (length(canon_roots) == 0) return(FALSE)
	canon_n <- vapply(canon_roots, normalizePath, character(1),
	                  winslash = "/", mustWork = FALSE)
	any(startsWith(path_n, canon_n))
}

# ============================================================================
# Z: drive mirror (carbon-copy writes; integrity check on reads)
# ============================================================================

#' Map a Teams-canonical path to the equivalent Z: drive path.
#' Returns NA_character_ if Z: not available or `path` is not under canonical.
.dw_z_mirror_path <- function(path) {
	if (!isTRUE(.try_get("dw_z_available"))) return(NA_character_)
	teams_canon <- .try_get("teamsFolderCanonical")
	z_root      <- .try_get("dwZDrive")
	if (is.na(teams_canon) || is.na(z_root)) return(NA_character_)
	tn <- normalizePath(teams_canon, winslash = "/", mustWork = FALSE)
	zn <- normalizePath(z_root,      winslash = "/", mustWork = FALSE)
	pn <- normalizePath(path,        winslash = "/", mustWork = FALSE)
	if (!startsWith(pn, tn)) return(NA_character_)
	rel <- sub(paste0("^", tn), "", pn)
	rel <- sub("^/", "", rel)
	file.path(zn, rel)
}

#' Carbon-copy a canonical write to Z: (silent on absence; warn on copy fail).
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

#' Verify that the file at `path` (canonical Teams) matches its Z: mirror.
#' Returns a list with `status` and supporting fields. `compare = "size"`
#' (fast) or `"sha256"` (deep). Returns NULL if Z: not available.
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
		psha <- digest::digest(file = path,   algo = "sha256")
		zsha <- digest::digest(file = z_path, algo = "sha256")
		list(status = if (identical(psha, zsha)) "match_sha256" else "sha256_mismatch",
		     path = path, z_path = z_path,
		     primary_sha = psha, z_sha = zsha)
	}
}

# ============================================================================
# isid uniqueness check (Stata-style; inspired by edukit_save)
# ============================================================================

dw_isid <- function(df, keys, where = "<unknown>") {
	missing_keys <- setdiff(keys, names(df))
	if (length(missing_keys) > 0) {
		stop("dw_isid (", where, "): keys not in data: ",
		     paste(missing_keys, collapse = ", "))
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
		stop("dw_isid (", where, "): ", n_dup,
		     " duplicate row(s) on key (", paste(keys, collapse = ", "), ").\n",
		     "First duplicates:\n",
		     paste(utils::capture.output(print(sample_show)), collapse = "\n"))
	}
	invisible(TRUE)
}

# ============================================================================
# dw_save — uniform write with auto-dispatch + Z: mirror
# ============================================================================

#' Save an object to disk, dispatching on the file extension
#'
#' Supported extensions:
#'   .csv, .tsv, .txt    -> data.table::fwrite (defaults na="", row.names=FALSE)
#'   .csv.gz / .tsv.gz   -> fwrite with compress="gzip"
#'   .xlsx               -> writexl (DF or named list of DFs) /
#'                           openxlsx::saveWorkbook (Workbook objects)
#'   .rds                -> saveRDS
#'   .RData/.Rdata/.rda  -> save() with named-list expansion
#'   .dta                -> haven::write_dta
#'   .parquet            -> arrow::write_parquet
#'   .json               -> jsonlite::write_json
#'   .yml, .yaml         -> yaml::write_yaml
#'
#' Path resolution (pick one):
#'   - `path = "..."` — used as-is (absolute or relative)
#'   - `name = "..."` + optional `sector`/`kind`/`vintage` — resolved via
#'     `dw_resolve_path()` using session-default mode (teamsWrkData /
#'     teamsRawData / dwMetaData; these are mode-aware in the profile).
#'
#' Mode contract: enforced at call site.
#'   Writes resolving to canonical paths in reviewer-session STOP unless
#'   `allow_canonical_write = TRUE` (Database Manager bootstrap).
#'
#' Z: mirror: AUTOMATIC.
#'   When `path` resolves under canonical AND `dw_z_available == TRUE`, the
#'   primary write is carbon-copied to the Z: equivalent. Z: absence is
#'   non-blocking (Teams write still succeeds; Z: copy is skipped with a
#'   single advisory at profile-load time).
#'
#' Quality contract:
#'   `isid = c("col1","col2",...)` runs `dw_isid()` before writing.
#'
#' Provenance sidecar:
#'   `provenance = TRUE` writes `<path>.provenance.json` with timestamp,
#'   user, dw_mode, sha256, schema, and the user-supplied `metadata = list(...)`
#'   (title, abstract, producer, sources, contact, vintage, ...).
dw_save <- function(x,
                    path = NULL,
                    name = NULL, sector = NULL,
                    kind = c("wrk", "raw", "meta"),
                    isid = NULL,
                    metadata = NULL,
                    compress = FALSE,
                    overwrite = TRUE,
                    provenance = TRUE,
                    vintage = NULL,
                    allow_canonical_write = FALSE,
                    mirror_to_z = TRUE,
                    ...) {

	kind <- match.arg(kind)

	if (is.null(path)) {
		path <- dw_resolve_path(name = name, sector = sector, kind = kind,
		                        vintage = vintage)
	}

	# Mode contract — reviewer-session must not write canonical
	is_canon <- dw_is_canonical(path)
	if (is_canon && !isTRUE(allow_canonical_write)) {
		is_reviewer <- isTRUE(.try_get("dw_mode") == "reviewer")
		if (is_reviewer) {
			stop("[dw_save] Reviewer mode forbids writes under canonical: ",
			     path, "\n  Writes must land in the sandbox or repo-local path.\n",
			     "  If this is a deliberate Database Manager bootstrap, ",
			     "pass `allow_canonical_write = TRUE`.")
		}
	}

	# Quality contract — isid before write
	if (!is.null(isid) && is.data.frame(x)) {
		dw_isid(x, keys = isid, where = path)
	}

	# Optional compression: append .gz for CSV/TSV/TXT
	fmt <- tolower(tools::file_ext(path))
	if (isTRUE(compress) && fmt %in% c("csv", "tsv", "txt") &&
	    !grepl("\\.gz$", path, ignore.case = TRUE)) {
		path <- paste0(path, ".gz")
	}

	dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
	tmp_path <- paste0(path, ".tmp")
	if (file.exists(tmp_path)) file.remove(tmp_path)

	fmt_for_dispatch <- tolower(tools::file_ext(sub("\\.gz$", "", path,
	                                                ignore.case = TRUE)))
	switch(fmt_for_dispatch,
		csv = .write_csv(x, tmp_path, sep = ",",  compress = compress, ...),
		tsv = .write_csv(x, tmp_path, sep = "\t", compress = compress, ...),
		txt = .write_csv(x, tmp_path, sep = "\t", compress = compress, ...),
		xlsx = .write_xlsx(x, tmp_path, ...),
		rds  = saveRDS(x, file = tmp_path, ...),
		rdata = .write_rdata(x, tmp_path, ...),
		"rda" = .write_rdata(x, tmp_path, ...),
		dta  = { .require("haven");    haven::write_dta(x, path = tmp_path, ...) },
		parquet = { .require("arrow"); arrow::write_parquet(x, sink = tmp_path, ...) },
		json = { .require("jsonlite"); jsonlite::write_json(x, path = tmp_path,
		                                                    auto_unbox = TRUE,
		                                                    pretty = TRUE, ...) },
		yml  = { .require("yaml");     yaml::write_yaml(x, file = tmp_path, ...) },
		yaml = { .require("yaml");     yaml::write_yaml(x, file = tmp_path, ...) },
		stop("dw_save: unsupported file extension '", fmt_for_dispatch,
		     "' for path: ", path)
	)

	if (!overwrite && file.exists(path)) {
		file.remove(tmp_path)
		stop("dw_save: file exists and overwrite = FALSE: ", path)
	}
	file.rename(tmp_path, path)

	# Provenance sidecar
	if (isTRUE(provenance) && !fmt_for_dispatch %in% c("rdata", "rda")) {
		.write_provenance(path, x, fmt = fmt_for_dispatch,
		                  vintage = vintage, metadata = metadata, isid = isid)
	}

	# Z: drive mirror (only for canonical writes; silent on Z: absence)
	if (is_canon && isTRUE(mirror_to_z)) {
		.dw_mirror_to_z(path)
	}

	invisible(path)
}

# ---- internal writers ------------------------------------------------------

.write_csv <- function(x, path, sep = ",", na = "", row.names = FALSE,
                       compress = FALSE, ...) {
	.require("data.table")
	args <- list(x = x, file = path, sep = sep, na = na, ...)
	if (isTRUE(compress)) args$compress <- "gzip"
	do.call(data.table::fwrite, args)
}

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
			path        = path,
			format      = fmt,
			written_at  = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z", tz = "UTC"),
			user        = Sys.getenv("USERNAME"),
			dw_mode     = .try_get("dw_mode"),
			vintage     = vintage,
			sha256      = sha,
			isid        = isid,
			schema      = schema
		),
		if (!is.null(metadata)) list(metadata = metadata) else list()
	)
	jsonlite::write_json(prov, path = paste0(path, ".provenance.json"),
	                     auto_unbox = TRUE, pretty = TRUE)
}

# ============================================================================
# dw_use — uniform read with auto-dispatch + Z: integrity check
# ============================================================================

#' Read a file from disk, dispatching on the file extension. Same path
#' resolution as dw_save.
#'
#' Z: integrity: AUTOMATIC.
#'   When the resolved path is under canonical AND `dw_z_available == TRUE`,
#'   a size-check (default; cheap) compares Teams vs Z:. Mismatch emits a
#'   warning; the read still proceeds (with the Teams data). Skip via
#'   `verify_z = FALSE`. Use `verify_z = "sha256"` for a deep check.
#'
#' `as`: "tibble" | "data.frame" | "data.table" (default tibble)
#' `cols`: optional character vector restricting columns to read
#' `fallback_canonical`: retry under canonical root if the literal path
#'   doesn't exist (default TRUE — lets reviewer-mode reads find the deposit)
dw_use <- function(path = NULL,
                   name = NULL, sector = NULL,
                   kind = c("wrk", "raw", "meta"),
                   cols = NULL,
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
				        "\n  Teams: ", res$path,
				        "\n  Z:    ", res$z_path %||% "<no z path>")
			}
		}
	}

	fmt <- tolower(tools::file_ext(sub("\\.gz$", "", resolved, ignore.case = TRUE)))
	x <- switch(fmt,
		csv = .read_csv(resolved, sep = ",",  cols = cols, ...),
		tsv = .read_csv(resolved, sep = "\t", cols = cols, ...),
		txt = .read_csv(resolved, sep = "\t", cols = cols, ...),
		xlsx = .read_xlsx(resolved, cols = cols, ...),
		rds  = readRDS(resolved, ...),
		rdata = .read_rdata(resolved, ...),
		"rda" = .read_rdata(resolved, ...),
		dta  = { .require("haven");    haven::read_dta(resolved, col_select = cols, ...) },
		parquet = { .require("arrow"); arrow::read_parquet(resolved, col_select = cols, ...) },
		json = { .require("jsonlite"); jsonlite::read_json(resolved, ...) },
		yml  = { .require("yaml");     yaml::read_yaml(resolved, ...) },
		yaml = { .require("yaml");     yaml::read_yaml(resolved, ...) },
		stop("dw_use: unsupported file extension '", fmt, "' for: ", resolved)
	)

	if (fmt %in% c("csv", "tsv", "txt", "xlsx", "dta", "parquet")) {
		x <- switch(as,
			"tibble"     = { .require("tibble"); tibble::as_tibble(x) },
			"data.frame" = as.data.frame(x),
			"data.table" = { .require("data.table"); data.table::as.data.table(x) }
		)
	}
	x
}

.read_csv <- function(path, sep, cols = NULL, ...) {
	.require("data.table")
	data.table::fread(input = path, sep = sep,
	                  select = cols, showProgress = FALSE, ...)
}

.read_xlsx <- function(path, sheet = 1, cols = NULL, ...) {
	.require("readxl")
	x <- readxl::read_xlsx(path, sheet = sheet, ...)
	if (!is.null(cols)) x <- x[, intersect(names(x), cols), drop = FALSE]
	x
}

.read_rdata <- function(path, ...) {
	env <- new.env(parent = emptyenv())
	load(path, envir = env)
	as.list(env)
}

.resolve_for_read <- function(path, fallback_canonical) {
	if (file.exists(path)) return(path)
	if (!isTRUE(fallback_canonical)) {
		stop("dw_use: file not found and fallback_canonical = FALSE: ", path)
	}
	swaps <- list(
		c(.try_get("teamsRawData"), .try_get("teamsRawDataCanonical")),
		c(.try_get("teamsWrkData"), .try_get("teamsWrkDataCanonical")),
		c(.try_get("teamsFolder"),  .try_get("teamsFolderCanonical"))
	)
	for (sw in swaps) {
		if (!any(is.na(sw)) && sw[1] != sw[2] && startsWith(path, sw[1])) {
			alt <- sub(paste0("^", sw[1]), sw[2], path, fixed = FALSE)
			if (file.exists(alt)) {
				message("[dw_use] Falling back to canonical: ", alt)
				return(alt)
			}
		}
	}
	stop("dw_use: file not found at literal path or canonical fallback: ", path)
}

# ============================================================================
# dw_compare — generalised compare-vs-canonical (lifted from nt/5b)
# ============================================================================

dw_compare <- function(current, reference,
                       by,
                       value_cols = NULL,
                       numeric_value_cols = NULL,
                       tol = 1e-5,
                       label = "compare",
                       write_report_to = NULL) {

	.require("dplyr")
	if (is.character(current)   && length(current)   == 1) current   <- dw_use(current)
	if (is.character(reference) && length(reference) == 1) reference <- dw_use(reference)

	common <- intersect(names(current), names(reference))
	by <- by[by %in% common]
	if (length(by) == 0) stop("dw_compare: no `by` columns are present in both sides.")
	value_cols <- if (is.null(value_cols)) setdiff(common, by) else value_cols[value_cols %in% common]
	numeric_value_cols <- intersect(numeric_value_cols, value_cols)

	norm <- function(v) {
		v <- trimws(as.character(v))
		v[is.na(v) | v %in% c("NA", "N/A", "NULL", ".")] <- ""
		v
	}
	current   <- dplyr::mutate(current,   dplyr::across(dplyr::all_of(common), norm))
	reference <- dplyr::mutate(reference, dplyr::across(dplyr::all_of(common), norm))

	added   <- dplyr::anti_join(current,   reference, by = by)
	removed <- dplyr::anti_join(reference, current,   by = by)

	cur_sub <- dplyr::select(current,   dplyr::all_of(c(by, value_cols)))
	ref_sub <- dplyr::select(reference, dplyr::all_of(c(by, value_cols)))
	joined  <- dplyr::inner_join(ref_sub, cur_sub, by = by,
	                             suffix = c("_reference", "_current"))

	values_equal <- function(a, b, numeric) {
		both_missing <- (a == "") & (b == "")
		if (numeric) {
			an <- suppressWarnings(as.numeric(a))
			bn <- suppressWarnings(as.numeric(b))
			both_numeric  <- !is.na(an) & !is.na(bn)
			numeric_equal <- both_numeric & abs(an - bn) <= tol
			both_str <- is.na(an) & is.na(bn)
			str_eq   <- both_str & a == b
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
		current_rows   = nrow(current),
		row_delta      = nrow(current) - nrow(reference),
		added          = nrow(added),
		removed        = nrow(removed),
		changed        = nrow(changed),
		completed_at   = format(Sys.time(), "%Y-%m-%d %H:%M:%S")
	)

	if (!is.null(write_report_to)) {
		dir.create(write_report_to, recursive = TRUE, showWarnings = FALSE)
		prefix <- file.path(write_report_to, label)
		.require("data.table")
		data.table::fwrite(summary_tbl, paste0(prefix, "_summary.csv"))
		data.table::fwrite(added,       paste0(prefix, "_added_rows.csv"))
		data.table::fwrite(removed,     paste0(prefix, "_removed_rows.csv"))
		data.table::fwrite(changed,     paste0(prefix, "_changed_rows.csv"))
	}

	list(summary = summary_tbl, added = added, removed = removed, changed = changed)
}

# ============================================================================
# dw_merge — Stata-style merge with cardinality assert
# ============================================================================

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
# source("00_functions/dw_io.R")  # auto-sourced by profile
#
# # WRITE — path resolution honours session mode (producer or reviewer)
# dw_save(edu_sdg_uis,
#         name = "dw_ed_edu.csv", sector = "ed", kind = "wrk",
#         isid = c("DATAFLOW","REF_AREA","INDICATOR","SEX",
#                  "WEALTH_QUINTILE","RESIDENCE","TIME_PERIOD"),
#         metadata = list(
#           title    = "Education indicators — UNICEF DW format",
#           producer = "01_dw_prep/012_codes/ed/02_aggregate_uis_sdg.R",
#           sources  = c("UIS bulk SDG_092025", "WPP 2024"),
#           contact  = "@karavan88",
#           vintage  = "2026-05"
#         ))
# # In producer session: writes to Teams + carbon copy to Z: + provenance sidecar.
# # In reviewer session: writes to sandbox + provenance sidecar (no Z: mirror;
# # sandbox is not under canonical).
#
# # READ — automatic Z: integrity check on canonical reads
# warehouse <- dw_use(name = "dw_ed_edu.csv", sector = "ed", kind = "wrk")
# # If Teams vs Z: differ, a warning is emitted; the read still completes.
#
# # Database-Manager bootstrap in reviewer session (rare; explicit):
# dw_save(pop_school_age,
#         name = "pop_school_age.csv", sector = "ed", kind = "raw",
#         allow_canonical_write = TRUE)   # bypasses reviewer-mode guard
#
# # Compare
# report <- dw_compare(
#   current   = dw_use(name = "dw_ed_edu.csv", sector = "ed", kind = "wrk"),
#   reference = dw_use(path = file.path(teamsWrkDataCanonical, "ed/dw_ed_edu.csv")),
#   by        = c("DATAFLOW","REF_AREA","INDICATOR","SEX","WEALTH_QUINTILE","TIME_PERIOD"),
#   value_cols = c("OBS_VALUE", "DATA_SOURCE"),
#   numeric_value_cols = "OBS_VALUE",
#   tol = 1e-5
# )
