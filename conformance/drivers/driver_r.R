#!/usr/bin/env Rscript
# =====================================================================
# Parity certificate driver -- R (the reference language)
# ---------------------------------------------------------------------
# Runs the parity cases R implements against the toolkit in this working
# tree (devtools::load_all("r"), never an installed package) and writes
# one output per case into <out_dir>: <id>.csv (kind "values") or
# <id>.json (kind "json"); a case that crashes writes <id>.error.txt.
# conformance/certify.py runs the three drivers and compares them.
#
# Usage: Rscript --no-init-file conformance/drivers/driver_r.R \
#          <case_ids,comma,separated> <fixtures_dir> <out_dir>
# =====================================================================

args <- commandArgs(trailingOnly = TRUE)
stopifnot(length(args) == 3)
case_ids <- strsplit(args[[1]], ",", fixed = TRUE)[[1]]
fix_dir <- normalizePath(args[[2]], winslash = "/", mustWork = TRUE)
out_dir <- normalizePath(args[[3]], winslash = "/", mustWork = TRUE)
repo <- Sys.getenv("CERT_REPO", ".")

suppressMessages(devtools::load_all(file.path(repo, "r"), quiet = TRUE,
                                    export_all = TRUE, helpers = FALSE))
options(dw.verbose = FALSE)

work <- file.path(out_dir, "_work")
dir.create(work, showWarnings = FALSE, recursive = TRUE)
fx <- function(f) file.path(fix_dir, f)
out_csv <- function(df, id) utils::write.csv(as.data.frame(df), file.path(out_dir, paste0(id, ".csv")),
                                             row.names = FALSE, na = "", fileEncoding = "UTF-8")
out_json <- function(x, id) writeLines(jsonlite::toJSON(x, auto_unbox = TRUE, null = "null", na = "null",
                                                        digits = NA, pretty = TRUE),
                                       file.path(out_dir, paste0(id, ".json")), useBytes = TRUE)
is_envelope <- function(e) grepl("^\\[cso_toolkit\\.", conditionMessage(e))
set_state <- function(...) {
	kv <- list(...)
	for (k in names(kv)) {
		if (is.null(kv[[k]])) {
			if (exists(k, envir = .GlobalEnv, inherits = FALSE)) rm(list = k, envir = .GlobalEnv)
		} else assign(k, kv[[k]], envir = .GlobalEnv)
	}
}
# A plain local session: no dw_mode, so no mirror pre-flight, no reviewer lock.
plain <- function() set_state(dw_mode = NULL, dw_apis_allowed = NULL,
                              dw_collaboration_model = "single-producer",
                              dw_session_start = "2000-01-01T00:00:00+0000")

roundtrip <- function(fixture, ext, id) {
	plain()
	x <- as.data.frame(dw_use(fx(fixture)))
	p <- file.path(work, paste0(id, ".", ext))
	dw_save(x, path = p, overwrite = TRUE, provenance = FALSE)
	out_csv(dw_use(p), id)
}

cases <- list(
	io_roundtrip_csv = function(id) roundtrip("indicators.csv", "csv", id),
	io_roundtrip_dta = function(id) roundtrip("indicators.csv", "dta", id),
	io_edge_values   = function(id) roundtrip("edge_values.csv", "csv", id),

	save_isid_duplicate = function(id) {
		plain()
		x <- as.data.frame(dw_use(fx("duplicate_keys.csv")))
		p <- file.path(work, paste0(id, ".csv"))
		e <- tryCatch({dw_save(x, path = p, isid = c("REF_AREA", "TIME_PERIOD"),
		                       overwrite = TRUE, provenance = FALSE); NULL},
		              error = identity)
		out_json(list(error = !is.null(e), envelope = !is.null(e) && is_envelope(e),
		              file_written = file.exists(p)), id)
	},

	reviewer_refuses_api = function(id) {
		d <- file.path(work, id)
		dir.create(d, showWarnings = FALSE)
		set_state(dw_mode = "reviewer", dw_apis_allowed = FALSE,
		          teamsRawData = d, teamsRawDataCanonical = d)
		e <- tryCatch({dw_api_fetch("csv", cache_key = "never_cached",
		                            url = "https://example.org/x.csv"); NULL},
		              error = identity)
		plain()
		out_json(list(refused = !is.null(e), envelope = !is.null(e) && is_envelope(e)), id)
	},

	provenance_sidecar = function(id) {
		plain()
		x <- as.data.frame(dw_use(fx("indicators.csv")))
		p <- file.path(work, paste0(id, ".csv"))
		dw_save(x, path = p, overwrite = TRUE, provenance = TRUE)
		sc <- paste0(p, ".provenance.json")
		have <- file.exists(sc)
		prov <- if (have) jsonlite::fromJSON(sc, simplifyVector = FALSE) else list()
		req <- c("path", "written_at", "user", "dw_mode", "sha256", "schema")
		out_json(list(
			sidecar = have,
			missing_keys = I(setdiff(req, names(prov))),
			sha256_matches = identical(prov$sha256, digest::digest(file = p, algo = "sha256")),
			rows = prov$schema$rows %||% NA, cols = prov$schema$cols %||% NA), id)
	},

	compare_counts = function(id) {
		plain()
		ref <- as.data.frame(dw_use(fx("compare_reference.csv")))
		cur <- as.data.frame(dw_use(fx("compare_current.csv")))
		r <- dw_compare(cur, ref, by = c("REF_AREA", "TIME_PERIOD"),
		                value_cols = "OBS_VALUE", numeric_value_cols = "OBS_VALUE", tol = 1e-6)
		out_json(list(added = r$summary$added, removed = r$summary$removed,
		              changed = r$summary$changed), id)
	},

	aggregate_weighted_mean = function(id) {
		plain()
		x <- as.data.frame(dw_use(fx("aggregate_input.csv")))
		a <- aggregate_data_v2(x, value = "value", weight = "weight", by = "Region_Code",
		                       method = "weighted_mean", global = TRUE, global_label = "WORLD")
		out_csv(a, id)
	},

	version_compare = function(id) {
		case <- jsonlite::fromJSON(file.path(repo, "conformance", "cases", paste0(id, ".json")),
		                           simplifyVector = FALSE)
		out_json(list(behind = lapply(case$pairs, function(p) {
			b <- .cso_version_behind(p[[1]], p[[2]])
			if (is.na(b)) NULL else b
		})), id)
	},

	config_user_block = function(id) {
		case <- jsonlite::fromJSON(file.path(repo, "conformance", "cases", paste0(id, ".json")),
		                           simplifyVector = FALSE)
		d <- file.path(work, id)
		dir.create(d, showWarnings = FALSE, recursive = TRUE)
		p <- create_profile(case$project, output_path = d, verbose = FALSE)
		src <- readLines(p, warn = FALSE)
		src <- sub('^required_pkgs <- c\\(.*\\)$', 'required_pkgs <- c("yaml")', src)
		writeLines(src, p)
		p <- normalizePath(p, winslash = "/")
		rscript <- file.path(R.home("bin"), if (.Platform$OS.type == "windows") "Rscript.exe" else "Rscript")
		modes <- lapply(seq_along(case$fixtures), function(i) {
			home <- file.path(d, paste0("home", i))
			dir.create(file.path(home, ".config"), recursive = TRUE, showWarnings = FALSE)
			file.copy(fx(case$fixtures[[i]]), file.path(home, ".config", "user_config.yml"), overwrite = TRUE)
			code <- sprintf("source('%s'); cat('MODE=', dw_mode, '\\n', sep = '')", p)
			old <- Sys.getenv(c("USERNAME", "USER", "USERPROFILE"), unset = NA)
			Sys.setenv(USERNAME = case$user, USER = case$user,
			           USERPROFILE = normalizePath(home, winslash = "/"))
			out <- suppressWarnings(system2(rscript, c("--no-init-file", "-e", shQuote(code)),
			                                stdout = TRUE, stderr = TRUE))
			for (k in names(old)) if (is.na(old[[k]])) Sys.unsetenv(k) else do.call(Sys.setenv, as.list(old[k]))
			hit <- grep("^MODE=", out, value = TRUE)
			if ((attr(out, "status") %||% 0L) != 0L || !length(hit)) NULL else sub("^MODE=", "", hit[[1]])
		})
		out_json(list(modes = modes), id)
	},

	collab_out_of_band = function(id) {
		set_state(dw_mode = NULL, dw_apis_allowed = NULL,
		          dw_collaboration_model = "multi-producer",
		          dw_session_start = "2999-01-01T00:00:00+0000")
		on.exit(plain())
		old <- Sys.getenv("USERNAME", unset = NA)
		Sys.setenv(USERNAME = "certify")
		on.exit(if (is.na(old)) Sys.unsetenv("USERNAME") else Sys.setenv(USERNAME = old), add = TRUE)
		p <- file.path(work, paste0(id, ".csv"))
		unlink(c(p, paste0(p, ".provenance.json")))
		dw_save(data.frame(a = 1:2), path = p, overwrite = TRUE)
		cat("9\n", file = p, append = TRUE)              # changed without dw_save()
		e <- tryCatch({dw_save(data.frame(a = 5L), path = p, overwrite = TRUE); NULL},
		              error = identity)
		dw_save(data.frame(a = 5L), path = p, overwrite = TRUE, takeover = TRUE)
		back <- as.data.frame(dw_use(p))
		out_json(list(blocked = !is.null(e), envelope = !is.null(e) && is_envelope(e),
		              takeover_written = nrow(back) == 1 && back$a[[1]] == 5), id)
	}
)

for (id in case_ids) {
	f <- cases[[id]]
	if (is.null(f)) next                                 # not implemented in R
	res <- tryCatch({suppressMessages(suppressWarnings(f(id))); NULL}, error = identity)
	if (!is.null(res)) writeLines(conditionMessage(res), file.path(out_dir, paste0(id, ".error.txt")))
}

out_json(list(language = "r", version = R.version.string,
              toolkit = dw_toolkit_version()), "_versions")
