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

	aggregate_total = function(id) {
		plain()
		x <- as.data.frame(dw_use(fx("aggregate_total_input.csv")))
		a <- aggregate_data_v2(x, value = "value", weight = "weight", by = "Region_Code",
		                       method = "total", global = TRUE, global_label = "WORLD")
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

	compare_diagnose = function(id) {
		plain()
		ref <- as.data.frame(dw_use(fx("compare_reference.csv")))
		cur <- as.data.frame(dw_use(fx("compare_current.csv")))
		p <- dw_compare(cur, ref, by = c("REF_AREA", "TIME_PERIOD"), value_cols = "OBS_VALUE",
		                numeric_value_cols = "OBS_VALUE", tol = 1e-6, diagnose = TRUE)$profile
		out_json(list(columns = I(p$columns$column), n_changed = I(p$columns$n_changed),
		              rel_q50 = p$magnitude$rel_q50[p$magnitude$column == "OBS_VALUE"],
		              keys = I(p$keys$value[p$keys$key == "REF_AREA"]),
		              added = I(p$added$value[p$added$key == "REF_AREA"]),
		              removed = I(p$removed$value[p$removed$key == "REF_AREA"])), id)
	},

	compare_same_file = function(id) {
		plain()
		p <- fx("compare_reference.csv")
		e <- tryCatch({dw_compare(p, p, by = c("REF_AREA", "TIME_PERIOD")); NULL}, error = identity)
		out_json(list(refused = !is.null(e), envelope = !is.null(e) && is_envelope(e)), id)
	},

	deposit_fetch_inputs = function(id) {
		plain()
		set_state(teamsFolderCanonical = NULL, dw_z_available = FALSE)
		local <- file.path(work, id, "local")
		unlink(local, recursive = TRUE)
		m <- dw_fetch_inputs(local, "inputs", pattern = "_20(23|24|25)\\.csv$",
		                     teams_root = fx("deposit/teams"), z_root = NA_character_,
		                     verbose = FALSE)
		out_csv(m[, c("file", "sha256", "origin", "teams", "z")], id)
	},

	provenance_diff_status = function(id) {
		plain()
		d <- file.path(work, id)
		dir.create(d, showWarnings = FALSE, recursive = TRUE)
		p <- file.path(d, "out.csv")
		unlink(c(p, paste0(p, ".provenance.json")))
		inp <- function(files, shas) data.frame(file = files, sha256 = shas, stringsAsFactors = FALSE)
		run <- function(df, inputs) {
			meta <- list(title = "parity")
			if (!is.null(inputs)) meta$inputs <- inputs
			dw_save(df, path = p, metadata = meta, overwrite = TRUE, verbose = FALSE)
		}
		df1 <- data.frame(k = c("x", "y"), v = c(1, 2), stringsAsFactors = FALSE)
		in1 <- inp(c("a.csv", "b.csv"), c("aaa", "bbb"))
		st <- character(0)
		run(df1, in1)
		st[1] <- dw_provenance_diff(NULL, p, verbose = FALSE)$status
		prev <- dw_read_provenance(p, verbose = FALSE); run(df1, in1)
		st[2] <- dw_provenance_diff(prev, p, verbose = FALSE)$status
		prev <- dw_read_provenance(p, verbose = FALSE); run(transform(df1, v = v * 10), in1)
		st[3] <- dw_provenance_diff(prev, p, warn = FALSE, verbose = FALSE)$status
		prev <- dw_read_provenance(p, verbose = FALSE); run(df1, inp(c("a.csv", "c.csv"), c("aaa2", "ccc")))
		r4 <- dw_provenance_diff(prev, p, verbose = FALSE)
		st[4] <- r4$status
		prev <- dw_read_provenance(p, verbose = FALSE); run(df1, NULL)
		st[5] <- dw_provenance_diff(prev, p, verbose = FALSE)$status
		out_json(list(statuses = I(st), inputs_added = I(r4$inputs_added),
		              inputs_removed = I(r4$inputs_removed), inputs_changed = I(r4$inputs_changed)), id)
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
	},

	stage_lifecycle = function(id) {
		d <- file.path(work, id)
		unlink(d, recursive = TRUE)
		teams <- file.path(d, "teams"); z <- file.path(d, "z"); sb <- file.path(d, "sandbox")
		rel <- file.path("nt", "regions.csv")
		for (r in c(teams, z, sb)) dir.create(file.path(r, "nt"), recursive = TRUE, showWarnings = FALSE)
		put <- function(root, text, f = rel) writeLines(text, file.path(root, f))
		put(teams, c("id,value", "AFG,1")); put(z, c("id,value", "AFG,1"))
		roots <- c("teamsRawData", "teamsWrkData", "teamsFolder")
		set_state(dw_mode = "reviewer", teamsRawData = sb, teamsWrkData = sb, teamsFolder = sb,
		          teamsRawDataCanonical = teams, teamsWrkDataCanonical = teams,
		          teamsFolderCanonical = teams, dwZDrive = z, dw_z_available = TRUE)
		on.exit({
			do.call(set_state, stats::setNames(rep(list(NULL), 8),
			        c(roots, paste0(roots, "Canonical"), "dwZDrive", "dw_z_available")))
			plain()
		})
		sha <- function(f) digest::digest(file = f, algo = "sha256")
		sbp <- file.path(sb, rel); scp <- paste0(sbp, ".staged.json")
		out <- dw_stage(file.path(teams, rel))           # canonical input -> sandbox
		sc <- jsonlite::fromJSON(scp)
		mt <- file.mtime(sbp)
		Sys.sleep(1.1)
		dw_stage(sbp)
		second_copied <- !identical(file.mtime(sbp), mt)
		writeLines(c("id,value", "XXX,9"), sbp)          # tampered sandbox
		e_drift <- tryCatch({dw_stage(sbp); NULL}, error = identity)
		dw_stage(sbp, overwrite = TRUE)
		restored <- sha(sbp) == sha(file.path(teams, rel))
		Sys.sleep(1.1)
		put(teams, c("id,value", "AFG,9")); put(z, c("id,value", "AFG,9"))
		w <- NULL
		withCallingHandlers(dw_stage(sbp), warning = function(x) {
			w <<- conditionMessage(x); invokeRestart("muffleWarning")
		})
		rel2 <- file.path("nt", "other.csv")
		put(teams, c("id", "A"), rel2); put(z, c("id", "B"), rel2)
		e_mirror <- tryCatch({dw_stage(file.path(sb, rel2)); NULL}, error = identity)
		out_json(list(
			returns_sandbox = .normalize_for_comparison(out) == .normalize_for_comparison(sbp),
			sidecar_keys = sort(names(sc)), sidecar_type = sc$type, source_root = sc$source_root,
			sidecar_sha_matches = identical(sc$sha256, sha(file.path(z, rel))),
			mtime_format_ok = grepl("^\\d{4}-\\d\\d-\\d\\dT\\d\\d:\\d\\d:\\d\\d[+-]\\d{4}$", sc$mtime),
			second_call_copied = second_copied,
			drift_stops = !is.null(e_drift) && grepl("SANDBOX DRIFT", conditionMessage(e_drift)),
			overwrite_restores = restored,
			upstream_warns = !is.null(w) && grepl("UPSTREAM CHANGED", w),
			upstream_recopied = sha(sbp) == sha(file.path(teams, rel)),
			mirrors_disagree_stops = !is.null(e_mirror) &&
				grepl("CANONICAL INTEGRITY", conditionMessage(e_mirror)),
			envelope = !is.null(e_drift) && is_envelope(e_drift)
		), id)
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
