#!/usr/bin/env Rscript
# =====================================================================
# Cross-language conformance driver — R
# ---------------------------------------------------------------------
# Reads the shared fixture via dw_use(), round-trips it through
# dw_save() -> dw_use(), then writes a NORMALISED out_r.csv (fixed
# column order, rows sorted by the id keys). conformance/compare.py
# asserts out_r.csv == out_python.csv == out_stata.csv value-for-value.
#
# Usage: Rscript conformance/run_r.R <fixture.csv> <out_r.csv>
# =====================================================================

suppressMessages({
  if (requireNamespace("csotoolkit", quietly = TRUE)) {
    library(csotoolkit)
  } else {
    devtools::load_all(Sys.getenv("CSO_R_PKG", "r"), quiet = TRUE)
  }
})

args    <- commandArgs(trailingOnly = TRUE)
fixture <- if (length(args) >= 1) args[[1]] else "conformance/fixtures/indicators.csv"
outfile <- if (length(args) >= 2) args[[2]] else "out_r.csv"

KEYS <- c("REF_AREA", "INDICATOR", "SEX", "AGE", "TIME_PERIOD")

# Minimal state: a writable "Teams" root is all dw_save() needs for a plain
# local write (mirrors local_state(teamsWrkData = ...) in the round-trip test;
# no dw_mode set, so no producer mounted-remote pre-flight / no reviewer lock).
assign("teamsWrkData", tempfile("cso_conf_r_"), envir = .GlobalEnv)
dir.create(get("teamsWrkData", .GlobalEnv), recursive = TRUE, showWarnings = FALSE)

in_df <- as.data.frame(dw_use(fixture))
out   <- dw_save(in_df, name = "conformance_rt.csv", sector = "conf", kind = "wrk",
                 isid = KEYS, provenance = FALSE)
rt    <- as.data.frame(dw_use(out))

rt <- rt[, c(KEYS, "OBS_VALUE"), drop = FALSE]
rt <- rt[do.call(order, rt[KEYS]), , drop = FALSE]
utils::write.csv(rt, outfile, row.names = FALSE, na = "")
cat("[run_r] wrote", nrow(rt), "rows to", outfile, "\n")
