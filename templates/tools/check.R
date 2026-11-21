# ---------------------------------------------------------------------------
# tools/check.R -- every check of the CI menu, run locally with one command
# ---------------------------------------------------------------------------
# Template from unicef-drp/cso-toolkit: templates/tools/check.R
# Guidance: docs/ci_cd_guidelines.md ("checks run locally first").
#
# From the repo root:
#   Rscript --no-init-file tools/check.R                  # the default checks
#   Rscript --no-init-file tools/check.R --only sidecars,tests
#   Rscript --no-init-file tools/check.R --skip tests
#   Rscript --no-init-file tools/check.R --list           # names, then exit
# (Use --no-init-file, not --vanilla: --vanilla also drops .Renviron and the
# library path it sets.)
#
# Prints one [PASS] / [FAIL] / [SKIP] / [WARN] line per check, each failure
# with a Why and a Fix line, and exits non-zero when any check fails. The
# GitHub Actions templates in templates/workflows/ call this same script, so
# the local run and CI cannot drift apart. Paste the output into the pull
# request: that is the check record when Actions are not run on every push.
#
# Needs: R, git on the PATH, and the packages testthat (tests), jsonlite
# (sidecars; testthat installs it), yaml (vintage). gitleaks is used when
# it is on the PATH; locally the secret scan is skipped without it, in CI
# (CI=true) a missing tool is a failure.
# ---------------------------------------------------------------------------

# ---- Edit for your repo (environment variables of the same name override) --
CONFIG <- list(
  # Checks run by default, in this order. Optional extras: lint (advisory,
  # never fails), manuscript (LaTeX build + page limit).
  CHECKS      = "tracked-data large-files secret-scan sidecars contract-audit vintage tests",
  # Folders whose contents stay out of git, at any depth. Official
  # statistics add the raw-data stage of the deposit layout, 011_rawdata.
  DATA_DIRS   = "data inputs _apis _frozen",
  # Files allowed inside DATA_DIRS (shell-style globs on the file name).
  DATA_ALLOW  = "README.md .gitkeep *.provenance.json input_manifest.*",
  # Formats that are data wherever they appear.
  DATA_EXTS   = "sav dta rds RData rda parquet feather sas7bdat zip 7z gz tar h5 duckdb sqlite db",
  # Official-statistics repos: output folders that must hold nothing tracked
  # (the embargo; docs/gitignore_guidelines.md). Set to
  # "output outputs results wrk 013_wrkdata" there (013_wrkdata: the work-data
  # stage of the deposit layout); empty for a research project.
  # releases/ (the post-publication release record) is always exempt.
  OUTPUT_DIRS = "",
  # Paths exempt from tracked-data and large-files (extended regex).
  ALLOW_PATHS = "^tests/|^_config_template/",
  MAX_FILE_MB = "50",
  # Vendored cso-toolkit helpers and the code the contract audit reads.
  TOOLKIT_DIR = "00_functions",
  AUDIT_PATHS = "R",
  # What contract-audit does with a violation (a raw read, write or HTTP
  # call that bypasses the dw_* wrappers): "blocking" fails the run;
  # "advisory" lists the violations as [WARN] and does not fail. Official
  # statistics keep "blocking"; a research project starts "advisory" and
  # moves to "blocking" once its code reads through dw_use().
  AUDIT_MODE  = "blocking",
  # manuscript check
  PAPER_DIR   = "paper",
  ROOT_FILE   = "main.tex",
  MAX_PAGES   = "40"
)
# ---------------------------------------------------------------------------

cfg <- function(key) {
  v <- Sys.getenv(key, unset = NA)
  if (is.na(v)) CONFIG[[key]] else v
}
words <- function(x) {
  x <- trimws(x)
  if (!nzchar(x)) character() else strsplit(x, "[[:space:],]+")[[1]]
}
on_ci <- identical(tolower(Sys.getenv("CI")), "true")

# ---- Arguments ---------------------------------------------------------------
args <- commandArgs(trailingOnly = TRUE)
arg_value <- function(flag) {
  i <- match(flag, args)
  if (is.na(i) || i == length(args)) return(character())
  words(args[i + 1])
}
ALL_CHECKS <- c("tracked-data", "large-files", "secret-scan", "sidecars",
                "contract-audit", "vintage", "tests", "lint", "manuscript")
if ("--list" %in% args) {
  cat("Default:", cfg("CHECKS"), "\nAvailable:", paste(ALL_CHECKS, collapse = " "), "\n")
  quit(status = 0)
}
checks <- if ("--only" %in% args) arg_value("--only") else words(cfg("CHECKS"))
checks <- setdiff(checks, arg_value("--skip"))
unknown <- setdiff(checks, ALL_CHECKS)
if (length(unknown)) {
  cat("[check] unknown check(s):", paste(unknown, collapse = ", "),
      "\n  Fix: use --list to see the names.\n")
  quit(status = 2)
}

# ---- Repo root and git -------------------------------------------------------
git <- function(...) {
  out <- suppressWarnings(system2("git", c(...), stdout = TRUE, stderr = TRUE))
  structure(out, status = attr(out, "status") %||% 0L)
}
`%||%` <- function(a, b) if (is.null(a)) b else a
root <- git("rev-parse", "--show-toplevel")
if (attr(root, "status") != 0L) {
  cat("[check] not inside a git repository (or git is not on the PATH).\n",
      " Fix: run from the repo root, with git installed.\n")
  quit(status = 2)
}
setwd(root[1])
# --no-init-file skips the project's .Rprofile, so activate renv here (the
# project library then supplies testthat, jsonlite, yaml). CHECK_NO_RENV=true
# turns this off, e.g. in a CI job that installs packages without restoring.
use_renv <- file.exists(file.path("renv", "activate.R")) &&
  !identical(tolower(Sys.getenv("CHECK_NO_RENV")), "true")
if (use_renv) source(file.path("renv", "activate.R"))
# Tracked files. `git ls-files -z` separates names with NUL (safe for any
# file name); R strings cannot hold NUL, so read the output as raw bytes.
tracked <- local({
  tmp <- tempfile()
  on.exit(unlink(tmp))
  system2("git", c("ls-files", "-z"), stdout = tmp)
  bytes <- readBin(tmp, "raw", file.info(tmp)$size)
  if (!length(bytes)) return(character())
  ends <- which(bytes == as.raw(0))
  starts <- c(1L, head(ends, -1) + 1L)
  vapply(seq_along(ends), function(i) {
    s <- rawToChar(bytes[starts[i]:(ends[i] - 1L)])
    Encoding(s) <- "UTF-8"
    s
  }, character(1))
})

head_sha <- git("rev-parse", "--short", "HEAD")
if (attr(head_sha, "status") != 0L) head_sha <- "(none yet)"   # a new repository
dirty <- length(git("status", "--porcelain", "--untracked-files=no")) > 0
cat(sprintf("== tools/check.R  %s  commit %s%s  R %s  %s ==\n",
            basename(getwd()), head_sha[1], if (dirty) " (+ uncommitted changes)" else "",
            getRversion(), format(Sys.time(), "%Y-%m-%d %H:%M %Z")))

# ---- Result bookkeeping --------------------------------------------------------
results <- character()
report <- function(status, name, detail = character(), why = NULL, fix = NULL) {
  results[name] <<- status
  cat(sprintf("[%s] %s\n", status, name))
  for (d in detail) cat("       ", d, "\n", sep = "")
  if (!is.null(why)) cat("  Why: ", why, "\n", sep = "")
  if (!is.null(fix)) cat("  Fix: ", paste(fix, collapse = "\n       "), "\n", sep = "")
}
glob_any <- function(x, globs) {
  if (!length(globs)) return(rep(FALSE, length(x)))
  Reduce(`|`, lapply(utils::glob2rx(globs), function(g) grepl(g, x)))
}
allowed_path <- function(f) {
  a <- cfg("ALLOW_PATHS")
  if (!nzchar(a)) rep(FALSE, length(f)) else grepl(a, f, perl = TRUE)
}
rscript <- file.path(R.home("bin"), if (.Platform$OS.type == "windows") "Rscript.exe" else "Rscript")

# ---- Checks ----------------------------------------------------------------------
check <- list()

check[["tracked-data"]] <- function(name) {
  f <- tracked[!allowed_path(tracked)]
  base <- basename(f)
  dirs <- strsplit(dirname(f), "/", fixed = TRUE)
  in_dirs <- function(set) vapply(dirs, function(d) any(d %in% set), logical(1))
  problems <- character()

  hit <- in_dirs(words(cfg("DATA_DIRS"))) & !glob_any(base, words(cfg("DATA_ALLOW")))
  problems <- c(problems, sprintf("%s  (data file inside a data folder)", f[hit]))

  ext <- ifelse(grepl(".", base, fixed = TRUE), sub("^.*\\.", "", base), "")
  hit <- ext %in% words(cfg("DATA_EXTS"))
  problems <- c(problems, sprintf("%s  (data format .%s)", f[hit], ext[hit]))

  secret <- glob_any(base, c(".env", ".env.*", "*.pem", "*.key", "*.p12", "*.pfx",
                             ".netrc", ".Renviron", "user_config.yml")) & base != ".env.example"
  problems <- c(problems, sprintf("%s  (secret or personal configuration)", f[secret]))

  out_dirs <- words(cfg("OUTPUT_DIRS"))
  if (length(out_dirs)) {
    hit <- in_dirs(out_dirs) & !startsWith(f, "releases/")
    problems <- c(problems, sprintf("%s  (inside an embargoed output folder)", f[hit]))
  }

  if (length(problems)) {
    report("FAIL", name, problems,
           why = "data stay in the deposit, secrets nowhere in git, and pre-release outputs are embargoed; git holds code and provenance sidecars.",
           fix = c("git rm --cached -- <path>   (keeps the file on disk), add the rule to .gitignore",
                   "(docs/gitignore_guidelines.md), commit. History still holds it: see the guidelines."))
  } else {
    report("PASS", name, sprintf("%d tracked file(s) checked", length(tracked)))
  }
}

check[["large-files"]] <- function(name) {
  limit <- as.numeric(cfg("MAX_FILE_MB")) * 1024^2
  f <- tracked[!allowed_path(tracked) & file.exists(tracked)]
  size <- file.size(f)
  big <- !is.na(size) & size > limit
  if (any(big)) {
    report("FAIL", name, sprintf("%s  (%.0f MB)", f[big], size[big] / 1024^2),
           why = sprintf("git keeps every version forever; GitHub rejects files over 100 MB (limit here: %s MB).", cfg("MAX_FILE_MB")),
           fix = "move the file to the deposit (Teams / Z: / Gitea LFS), commit its .provenance.json sidecar instead, and git rm --cached -- <path>.")
  } else {
    report("PASS", name, sprintf("no tracked file over %s MB", cfg("MAX_FILE_MB")))
  }
}

check[["secret-scan"]] <- function(name) {
  gl <- Sys.which("gitleaks")
  if (!nzchar(gl)) {
    if (on_ci) {
      return(report("FAIL", name, "gitleaks is not on the PATH",
                    fix = "install the pinned gitleaks binary before this step (see ci-hygiene.yml)."))
    }
    return(report("SKIP", name, "gitleaks is not installed; install it to scan locally (https://github.com/gitleaks/gitleaks/releases)"))
  }
  out <- suppressWarnings(system2(gl, c("git", "--redact", "--no-banner", "--exit-code", "1", "."),
                                  stdout = TRUE, stderr = TRUE))
  if ((attr(out, "status") %||% 0L) != 0L) {
    report("FAIL", name, tail(out, 15),
           why = "anything pushed is readable by everyone with access, forever.",
           fix = c("treat the secret as compromised and rotate it first; then remove it from the code.",
                   "A known false positive goes in .gitleaksignore (fingerprint from the report), with a comment saying why."))
  } else {
    report("PASS", name, "gitleaks: no leaks in the history (findings would be redacted)")
  }
}

check[["sidecars"]] <- function(name) {
  if (!requireNamespace("jsonlite", quietly = TRUE)) {
    return(report("FAIL", name, "the jsonlite package is not installed",
                  fix = "install.packages(\"jsonlite\")"))
  }
  f <- tracked[endsWith(tracked, ".provenance.json") & file.exists(tracked)]
  hex64 <- "^[0-9a-f]{64}$"
  problems <- character()
  for (path in f) {
    p <- tryCatch(jsonlite::fromJSON(path, simplifyVector = FALSE),
                  error = function(e) structure(conditionMessage(e), class = "bad_json"))
    if (inherits(p, "bad_json")) {
      problems <- c(problems, sprintf("%s: not valid JSON (%s)", path,
                                      gsub("[[:space:]]+", " ", trimws(p))))
      next
    }
    if (!is.list(p) || is.null(names(p))) {
      problems <- c(problems, sprintf("%s: top level is not a JSON object", path))
      next
    }
    if (!is.null(p$url) && !is.null(p$fetched_at)) {            # dw_api / frozen-URL sidecar
      need <- c("url", "fetched_at", "dw_mode", "sha256"); hash_key <- "sha256"
    } else if (identical(p$format, "dw_save.provenance/1")) {   # Stata dw_save sidecar
      need <- c("path", "format", "written_at", "dw_mode", "datasignature"); hash_key <- NULL
    } else {                                                    # R / Python dw_save sidecar
      need <- c("path", "format", "written_at", "dw_mode", "sha256"); hash_key <- "sha256"
    }
    missing <- setdiff(need, names(p))
    if (length(missing)) {
      problems <- c(problems, sprintf("%s: missing key(s): %s", path, paste(missing, collapse = ", ")))
    }
    if (!is.null(hash_key) && !is.null(p[[hash_key]])) {
      v <- p[[hash_key]]
      if (!(is.character(v) && length(v) == 1 && grepl(hex64, v))) {
        problems <- c(problems, sprintf("%s: %s is not a 64-character hex digest", path, hash_key))
      }
    }
  }
  if (length(problems)) {
    report("FAIL", name, problems,
           why = "the committed sidecar is the record of which bytes a result came from.",
           fix = c("re-write the output with dw_save() (R: install digest so sha256 is filled),",
                   "or regenerate the sidecar; schema: handbook Appendix B."))
  } else {
    report("PASS", name, sprintf("%d sidecar(s) parse and carry the core keys (hashes are verified in reviewer mode, not here)", length(f)))
  }
}

# Vendored helpers read their session state from .GlobalEnv; reviewer mode
# forbids network calls and canonical writes for the rest of this run.
load_toolkit <- function(files) {
  td <- cfg("TOOLKIT_DIR")
  assign("dw_mode", "reviewer", envir = globalenv())
  assign("dw_apis_allowed", FALSE, envir = globalenv())
  assign("dwFunct", td, envir = globalenv())
  for (f in files) {
    p <- file.path(td, f)
    if (!file.exists(p)) return(p)
    sys.source(p, envir = globalenv())
  }
  NULL
}

check[["contract-audit"]] <- function(name) {
  td <- cfg("TOOLKIT_DIR")
  mode <- cfg("AUDIT_MODE")
  if (!mode %in% c("blocking", "advisory")) {
    return(report("FAIL", name, sprintf("AUDIT_MODE is \"%s\"", mode),
                  fix = "set AUDIT_MODE at the top of tools/check.R to \"blocking\" or \"advisory\"."))
  }
  missing <- load_toolkit(c("dw_io.R", "test_scripts.R"))
  if (!is.null(missing)) {
    return(report("FAIL", name, sprintf("%s not found", missing),
                  why = "the audit runs the vendored toolkit, the exact code the repo runs.",
                  fix = sprintf("vendor dw_io.R and test_scripts.R into %s/ (handbook chapter 41), set TOOLKIT_DIR, or drop contract-audit from CHECKS.", td)))
  }
  paths <- words(cfg("AUDIT_PATHS"))
  paths <- paths[file.exists(paths)]
  if (!length(paths)) {
    return(report("FAIL", name, sprintf("none of AUDIT_PATHS exists: %s", cfg("AUDIT_PATHS")),
                  fix = "set AUDIT_PATHS at the top of tools/check.R to the folders holding analysis code."))
  }
  ign <- c(".git", "renv", "packrat", "node_modules", ".Rproj.user", basename(td))
  hits <- do.call(rbind, lapply(paths, function(p) {
    get("test_scripts", globalenv())(p, ignore_dirs = ign, verbose = FALSE)
  }))
  if (!is.null(hits) && nrow(hits) > 0) {
    cols <- intersect(c("file", "line", "rule"), names(hits))
    detail <- apply(hits[, cols, drop = FALSE], 1, paste, collapse = "  ")
    if (identical(mode, "advisory")) {
      detail <- c(sprintf("%d violation(s); AUDIT_MODE = \"advisory\", so the run does not fail", nrow(hits)),
                  detail)
    }
    report(if (identical(mode, "advisory")) "WARN" else "FAIL", name, detail,
           why = "raw IO and HTTP calls bypass the dw_* wrappers, so they leave no provenance and ignore reviewer mode.",
           fix = "route the call through the dw_* wrapper the rule names, or mark a documented exception with `# cso-allow: <rule>` (handbook chapter 43).")
  } else {
    report("PASS", name, sprintf("test_scripts(): no violations in %s", paste(paths, collapse = ", ")))
  }
}

check[["vintage"]] <- function(name) {
  td <- cfg("TOOLKIT_DIR")
  mpath <- file.path(td, ".toolkit_manifest.yml")
  fail <- function(what, fix) report("FAIL", name, what,
                                     why = "the manifest is the record of which toolkit vintage this repo runs.", fix = fix)
  if (!requireNamespace("yaml", quietly = TRUE)) return(fail("the yaml package is not installed", "install.packages(\"yaml\")"))
  if (!file.exists(mpath)) return(fail(paste("no manifest at", mpath), "copy templates/.toolkit_manifest.yml from cso-toolkit and fill it in."))
  m <- tryCatch(yaml::read_yaml(mpath), error = function(e) e)
  if (inherits(m, "error")) return(fail(paste("manifest does not parse:", conditionMessage(m)), "fix the YAML syntax."))
  miss <- setdiff(c("source", "pulled_version", "vendored"), names(m))
  if (length(miss)) return(fail(paste("manifest lacks:", paste(miss, collapse = ", ")), "add the keys; see templates/.toolkit_manifest.yml."))
  vend <- unlist(m$vendored)
  absent <- vend[!file.exists(file.path(td, vend))]
  if (length(absent)) return(fail(paste("listed in vendored: but missing:", paste(absent, collapse = ", ")),
                                  "re-vendor the files or remove them from vendored:."))
  missing <- load_toolkit(c("dw_io.R", "cso_toolkit_sync.R"))
  if (!is.null(missing)) return(fail(paste(missing, "not found"), "vendor cso_toolkit_sync.R (v0.10.0+) with dw_io.R."))
  behind <- character()
  withCallingHandlers(
    suppressMessages(get("cso_toolkit_check", globalenv())(quiet = FALSE)),
    warning = function(w) {
      if (grepl("[cso_toolkit.cso_toolkit_check]", conditionMessage(w), fixed = TRUE)) {
        behind <<- conditionMessage(w)
        invokeRestart("muffleWarning")
      }
    })
  if (length(behind)) return(fail(c("the vendored toolkit is behind target_version:", strsplit(behind, "\n")[[1]]),
                                  "a producer re-vendors with cso_toolkit_pull(target_version = ...)."))
  report("PASS", name, sprintf("manifest well-formed; pinned %s%s", m$pulled_version,
                               if (!is.null(m$target_version)) paste0(", target ", m$target_version) else ""))
}

check[["tests"]] <- function(name) {
  runner <- file.path("tests", "testthat.R")
  if (file.exists("DESCRIPTION")) {
    return(report("SKIP", name, "this is an R package: run R CMD check (devtools::check()) instead"))
  }
  if (!file.exists(runner)) {
    return(report("FAIL", name, "tests/testthat.R not found",
                  why = "testthat is part of every R repo (docs/ci_cd_guidelines.md).",
                  fix = "copy templates/testthat/ from cso-toolkit, or drop tests from CHECKS."))
  }
  # A fresh R process, so the runner's reviewer-mode globals and sourced
  # files do not leak into this one (and vice versa).
  rargs <- if (use_renv) {
    c("--no-init-file", "-e", shQuote("source('renv/activate.R'); source('tests/testthat.R')"))
  } else {
    c("--no-init-file", runner)
  }
  out <- suppressWarnings(system2(rscript, rargs, stdout = TRUE, stderr = TRUE))
  status <- attr(out, "status") %||% 0L
  summary <- grep("\\[ FAIL [0-9]+ \\| WARN", out, value = TRUE)
  if (status != 0L) {
    report("FAIL", name, tail(out, 25),
           fix = "run Rscript --no-init-file tests/testthat.R and fix the failing test (or the code it caught).")
  } else {
    report("PASS", name, if (length(summary)) tail(summary, 1) else "tests/testthat.R exited 0")
  }
}

check[["lint"]] <- function(name) {
  if (!requireNamespace("lintr", quietly = TRUE)) {
    return(report("SKIP", name, "lintr is not installed (advisory check)"))
  }
  lints <- lintr::lint_dir(".", exclusions = list(cfg("TOOLKIT_DIR"), "renv", "tests/testthat/fixtures"))
  if (length(lints)) {
    report("WARN", name, c(sprintf("%d lint(s); advisory, does not fail the run", length(lints)),
                           utils::head(format(lints), 10)))
  } else {
    report("PASS", name, "no lints")
  }
}

check[["manuscript"]] <- function(name) {
  tex <- file.path(cfg("PAPER_DIR"), cfg("ROOT_FILE"))
  if (!file.exists(tex)) return(report("FAIL", name, paste(tex, "not found"), fix = "set PAPER_DIR / ROOT_FILE at the top of tools/check.R."))
  if (!nzchar(Sys.which("latexmk"))) {
    return(report(if (on_ci) "FAIL" else "SKIP", name, "latexmk is not on the PATH (TinyTeX: tinytex::install_tinytex())"))
  }
  out <- suppressWarnings(system2("latexmk", c("-pdf", "-interaction=nonstopmode", "-halt-on-error", "-cd", tex),
                                  stdout = TRUE, stderr = TRUE))
  if ((attr(out, "status") %||% 0L) != 0L) {
    return(report("FAIL", name, tail(out, 20), fix = "fix the LaTeX error above (the build uses the committed tables and figures only)."))
  }
  pdf <- sub("\\.tex$", ".pdf", tex)
  if (!nzchar(Sys.which("pdfinfo"))) return(report("PASS", name, c(paste("built", pdf), "page count not checked: pdfinfo (poppler) is not on the PATH")))
  info <- system2("pdfinfo", pdf, stdout = TRUE)
  pages <- as.integer(sub("^Pages:[[:space:]]+", "", grep("^Pages:", info, value = TRUE)))
  limit <- as.integer(cfg("MAX_PAGES"))
  if (limit > 0 && length(pages) && pages > limit) {
    report("FAIL", name, sprintf("%s: %d pages, limit %d", pdf, pages, limit),
           why = "the target journal rejects over-length submissions.",
           fix = "cut text or move material to the supplement; or update MAX_PAGES if the journal changed.")
  } else {
    report("PASS", name, sprintf("%s: %d page(s), limit %d", pdf, pages, limit))
  }
}

# ---- Run -------------------------------------------------------------------------
for (name in checks) {
  tryCatch(check[[name]](name), error = function(e) {
    report("FAIL", name, paste("the check itself errored:", conditionMessage(e)))
  })
}

n_fail <- sum(results == "FAIL")
cat(sprintf("== %d check(s): %d passed, %d failed, %d skipped, %d warned ==\n",
            length(results), sum(results == "PASS"), n_fail,
            sum(results == "SKIP"), sum(results == "WARN")))
quit(status = if (n_fail > 0) 1L else 0L)
