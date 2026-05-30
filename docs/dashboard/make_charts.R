#!/usr/bin/env Rscript
# docs/dashboard/make_charts.R
# -----------------------------------------------------------------------------
# Generate the five v2 SVG charts for the cso-toolkit sector dashboard.
#
# Loads ggplot2 ONCE and writes five SVGs to charts/. Reproducible from
# committed data only — no network, no per-sector R re-runs.
#
# Reads:
#   data/parity.json                            (3-way parity counts)
#   data/state.json                             (dw_production.prs for the funnel)
#   data/snapshots/replication_<sector>_latest.json  (wall_time_s per sector)
#
# Writes:
#   charts/3way_parity.svg
#   charts/coverage_matrix.svg
#   charts/walltime.svg
#   charts/pr_funnel.svg
#   charts/toolkit_drift.svg
#
# Each SVG is emitted standalone via svglite (viewBox present) and then
# post-processed so the root <svg> carries width="100%" with no fixed pixel
# height. The dashboard CSS (`.chart svg { width:100%; height:auto }`) then
# scales it responsively off the viewBox aspect ratio.
#
# Required: jsonlite, ggplot2, svglite
# -----------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(jsonlite)
  library(ggplot2)
})

# ----- paths --------------------------------------------------------------- #

SCRIPT_DIR <- local({
  # Under `Rscript path/to/make_charts.R`, commandArgs() carries `--file=...`.
  # `sys.frame(1)$ofile` is only set when source()d, so fall back gracefully.
  a <- commandArgs(trailingOnly = FALSE)
  f <- sub("^--file=", "", grep("^--file=", a, value = TRUE))
  if (length(f) == 1L && nzchar(f)) {
    return(dirname(normalizePath(f, winslash = "/")))
  }
  ofile <- tryCatch(sys.frame(1)$ofile, error = function(e) NULL)
  if (!is.null(ofile)) return(dirname(normalizePath(ofile, winslash = "/")))
  getwd()
})
DASHBOARD_DIR <- SCRIPT_DIR
DATA_DIR      <- file.path(DASHBOARD_DIR, "data")
SNAPSHOTS_DIR <- file.path(DATA_DIR, "snapshots")
CHARTS_DIR    <- file.path(DASHBOARD_DIR, "charts")
PARITY_PATH   <- file.path(DATA_DIR, "parity.json")
STATE_PATH    <- file.path(DATA_DIR, "state.json")

dir.create(CHARTS_DIR, showWarnings = FALSE, recursive = TRUE)

`%||%` <- function(x, y) if (is.null(x)) y else x

# ----- house style: Okabe-Ito palette + minimal theme ---------------------- #
# Okabe & Ito (2008) colorblind-safe palette, per the r-ggplot skill.

OKABE_ITO <- c(
  black      = "#000000",
  orange     = "#E69F00",
  sky_blue   = "#56B4E9",
  green      = "#009E73",
  yellow     = "#F0E442",
  blue       = "#0072B2",
  vermillion = "#D55E00",
  purple     = "#CC79A7"
)

theme_dash <- function(base_size = 11) {
  theme_minimal(base_size = base_size) +
    theme(
      plot.title      = element_text(face = "bold", size = base_size + 1,
                                     margin = margin(b = 6)),
      plot.title.position = "plot",
      plot.subtitle   = element_text(color = "#6a7585", size = base_size - 1,
                                     margin = margin(b = 8)),
      axis.title      = element_text(color = "#6a7585", size = base_size - 1),
      panel.grid.minor = element_blank(),
      legend.position = "bottom",
      legend.title    = element_blank(),
      legend.key.size = unit(10, "pt"),
      plot.margin     = margin(8, 12, 8, 8)
    )
}

# Device geometry (inches) — ~7 x 4.5 per the r-ggplot skill default.
W_IN <- 7
H_IN <- 4.5

# ----- SVG writer: emit standalone, then force responsive width ------------ #

save_svg <- function(plot, name, title = NULL, desc = NULL,
                     width = W_IN, height = H_IN) {
  path <- file.path(CHARTS_DIR, name)
  stem <- tools::file_path_sans_ext(name)
  # standalone = FALSE: emit an inline-ready fragment (no <?xml?> prolog / DOCTYPE)
  # since render.R inlines every SVG into ONE HTML document — an XML prolog mid-body
  # is invalid HTML. The root <svg> keeps its xmlns + viewBox.
  svglite::svglite(path, width = width, height = height, standalone = FALSE)
  print(plot)
  invisible(grDevices::dev.off())

  txt <- readLines(path, warn = FALSE)

  # svglite derives clipPath ids from rect geometry, so identical panels across
  # charts collide as duplicate ids when inlined together. Namespace them per
  # chart so every id is globally unique regardless of geometry.
  txt <- gsub("(id=['\"]|url\\(#)cp", paste0("\\1", stem, "-cp"), txt)

  i <- grep("<svg ", txt)[1]
  if (!is.na(i)) {
    # Responsive: drop svglite's fixed pt width/height, keep the viewBox so the
    # dashboard CSS (`width:100%; height:auto`) scales off the aspect ratio.
    txt[i] <- sub("width='[0-9.]+pt' height='[0-9.]+pt'", "width='100%'", txt[i])
    if (!grepl("width='100%'", txt[i], fixed = TRUE) &&
        !grepl('width="100%"', txt[i], fixed = TRUE)) {
      txt[i] <- sub("(<svg )", "\\1width='100%' ", txt[i])
    }
    # Accessible name: role=img + aria-label + injected <title>/<desc> as the
    # first children, so screen readers announce each chart (svglite emits none).
    if (!is.null(title)) {
      lab <- gsub("[<>'\"]", "", title)
      txt[i] <- sub("(<svg )", sprintf("\\1role='img' aria-label='%s' ", lab), txt[i])
      node <- sprintf("<title>%s</title>%s", title,
                      if (!is.null(desc)) sprintf("<desc>%s</desc>", desc) else "")
      txt[i] <- sub(">", paste0(">", node), txt[i])  # inject after opening <svg ...>
    }
  }
  writeLines(txt, path, useBytes = TRUE)
  message(sprintf("wrote %s", path))
}

# Human-readable seconds: "25 min", "44 s".
fmt_secs <- function(s) {
  vapply(s, function(x) {
    if (is.na(x)) return(NA_character_)
    if (x >= 90) sprintf("%.0f min", x / 60) else sprintf("%.0f s", x)
  }, character(1))
}

# ----- load parity --------------------------------------------------------- #

if (!file.exists(PARITY_PATH)) {
  stop(sprintf("parity.json not found at %s", PARITY_PATH))
}
parity <- jsonlite::fromJSON(PARITY_PATH, simplifyVector = TRUE)
# Stable row order = file order; lock factor levels so bars stack top-to-bottom.
parity$label <- factor(parity$label, levels = rev(parity$label))

# ======================================================================== #
# Chart 1 — 3way_parity.svg : grouped horizontal bars MINE / DEP / SDMX     #
# ======================================================================== #

p1_df <- rbind(
  data.frame(label = parity$label, series = "MINE", value = parity$mine),
  data.frame(label = parity$label, series = "DEP",  value = parity$dep),
  data.frame(label = parity$label, series = "SDMX", value = parity$sdmx)
)
p1_df$series <- factor(p1_df$series, levels = c("MINE", "DEP", "SDMX"))

pal_3way <- c(
  MINE = unname(OKABE_ITO["blue"]),       # repo-local
  DEP  = unname(OKABE_ITO["orange"]),     # Teams deposit
  SDMX = unname(OKABE_ITO["sky_blue"])    # SDMX-published ceiling
)

p1 <- ggplot(p1_df, aes(x = label, y = value, fill = series)) +
  geom_col(position = position_dodge(width = 0.78), width = 0.72) +
  coord_flip() +
  scale_fill_manual(values = pal_3way) +
  labs(
    title    = "Indicator coverage — repo-local vs Teams deposit vs SDMX-published",
    subtitle = "Bars per indicator set; gap to SDMX = indicators published but not yet replicated locally",
    x = NULL, y = "Indicators"
  ) +
  theme_dash()

save_svg(p1, "3way_parity.svg",
         title = "Indicator coverage by sector: repo-local vs Teams deposit vs SDMX-published",
         desc  = "Grouped bar chart; the gap from the local bar to the SDMX bar is the count of published indicators not yet replicated locally.")

# ======================================================================== #
# Chart 2 — coverage_matrix.svg : tile heatmap of pipeline stage reached    #
# ======================================================================== #

stage_of <- function(count, sdmx) {
  if (is.na(count) || count == 0) return("none")
  if (count >= sdmx)             return("full")
  "partial"
}

p2_df <- do.call(rbind, lapply(seq_len(nrow(parity)), function(k) {
  data.frame(
    label = parity$label[k],
    stringsAsFactors = FALSE,
    rbind(
      data.frame(stage_x = "Local", status = stage_of(parity$mine[k], parity$sdmx[k])),
      data.frame(stage_x = "Teams", status = stage_of(parity$dep[k],  parity$sdmx[k])),
      data.frame(stage_x = "SDMX",  status = stage_of(parity$sdmx[k], parity$sdmx[k]))
    )
  )
}))
p2_df$stage_x <- factor(p2_df$stage_x, levels = c("Local", "Teams", "SDMX"))
p2_df$status  <- factor(p2_df$status,  levels = c("full", "partial", "none"))

pal_stage <- c(
  full    = unname(OKABE_ITO["green"]),
  partial = unname(OKABE_ITO["orange"]),
  none    = "#cbd2da"
)

# Redundant non-colour glyph per cell (✓ full / ◑ partial / – none) so the
# matrix is readable in monochrome or by colour-blind viewers.
glyph_map <- c(full = "✓", partial = "◑", none = "–")  # check / half-circle / dash
p2_df$glyph <- glyph_map[as.character(p2_df$status)]

p2 <- ggplot(p2_df, aes(x = stage_x, y = label, fill = status)) +
  geom_tile(color = "#ffffff", linewidth = 1.1) +
  geom_text(aes(label = glyph, color = status == "full"),
            size = 4, show.legend = FALSE) +
  scale_fill_manual(
    values = pal_stage,
    breaks = c("full", "partial", "none"),
    labels = c("full (= SDMX)", "partial", "none")
  ) +
  scale_color_manual(values = c(`TRUE` = "#ffffff", `FALSE` = "#1a1d23"),
                     guide = "none") +
  scale_x_discrete(position = "top") +
  labs(
    title    = "Coverage matrix — pipeline stage reached per indicator set",
    subtitle = "full = count equals SDMX ceiling · partial = 0 < count < SDMX · none = absent",
    x = NULL, y = NULL
  ) +
  theme_dash() +
  theme(panel.grid = element_blank())

save_svg(p2, "coverage_matrix.svg",
         title = "Coverage matrix: pipeline stage reached per indicator set",
         desc  = "Tile grid; rows are indicator sets, columns are Local, Teams and SDMX stages; each cell marked full (check), partial (half-circle) or none (dash).")

# ======================================================================== #
# Chart 3 — walltime.svg : horizontal bars, sqrt x-scale, on-bar labels     #
# ======================================================================== #

WT_SECTORS <- c("nt", "hva", "im", "ws", "mnch", "cme", "ed")
WT_LABELS  <- c(
  nt = "Nutrition", hva = "HIV/AIDS", im = "Immunization", ws = "WASH",
  mnch = "MNCH", cme = "Child mortality", ed = "Education"
)

read_walltime <- function(sector) {
  path <- file.path(SNAPSHOTS_DIR, sprintf("replication_%s_latest.json", sector))
  if (!file.exists(path)) return(NA_real_)
  snap <- jsonlite::fromJSON(path, simplifyVector = FALSE)
  wt <- snap$wall_time_s
  if (is.null(wt)) return(NA_real_)
  as.numeric(wt)
}

p3_df <- data.frame(
  sector = WT_SECTORS,
  label  = unname(WT_LABELS[WT_SECTORS]),
  secs   = vapply(WT_SECTORS, read_walltime, numeric(1)),
  stringsAsFactors = FALSE
)
p3_df <- p3_df[!is.na(p3_df$secs), , drop = FALSE]
p3_df <- p3_df[order(p3_df$secs), , drop = FALSE]
p3_df$label <- factor(p3_df$label, levels = p3_df$label)
p3_df$tag   <- fmt_secs(p3_df$secs)

p3 <- ggplot(p3_df, aes(x = label, y = secs)) +
  geom_col(fill = unname(OKABE_ITO["blue"]), width = 0.68) +
  geom_text(aes(label = tag), hjust = -0.12, size = 3.1, color = "#1a1d23") +
  coord_flip() +
  scale_y_sqrt(expand = expansion(mult = c(0, 0.18))) +
  labs(
    title    = "Replication wall-time by sector",
    subtitle = "sqrt scale — Nutrition (~25 min, 8 splits) dwarfs the others",
    x = NULL, y = "Wall time (s, sqrt scale)"
  ) +
  theme_dash()

save_svg(p3, "walltime.svg",
         title = "Replication wall-time by sector",
         desc  = "Horizontal bars on a square-root scale; Nutrition at about 25 minutes dwarfs the others, which run in seconds.")

# ======================================================================== #
# Chart 4 — pr_funnel.svg : Open / Merged / Closed-unmerged                 #
# ======================================================================== #

if (!file.exists(STATE_PATH)) {
  stop(sprintf("state.json not found at %s", STATE_PATH))
}
state <- jsonlite::fromJSON(STATE_PATH, simplifyVector = FALSE)
# DW-Production PR funnel from privacy-safe aggregate counts (collect.R emits
# counts only — the private repo's PR list is never published).
dwc      <- state$dw_production$counts %||% list()
n_open   <- dwc$prs_open   %||% 0L
n_merged <- dwc$prs_merged %||% 0L
n_closed <- dwc$prs_closed %||% 0L
n_total  <- dwc$prs_total  %||% (n_open + n_merged + n_closed)

p4_df <- data.frame(
  stage = factor(c("Open", "Merged", "Closed (unmerged)"),
                 levels = c("Open", "Merged", "Closed (unmerged)")),
  count = c(n_open, n_merged, n_closed)
)

pal_pr <- c(
  "Open"              = unname(OKABE_ITO["orange"]),
  "Merged"            = unname(OKABE_ITO["green"]),
  "Closed (unmerged)" = "#9aa3ae"
)

p4 <- ggplot(p4_df, aes(x = stage, y = count, fill = stage)) +
  geom_col(width = 0.66) +
  geom_text(aes(label = count), vjust = -0.4, size = 3.4, color = "#1a1d23") +
  scale_fill_manual(values = pal_pr, guide = "none") +
  scale_y_continuous(expand = expansion(mult = c(0, 0.14))) +
  labs(
    title    = "DW-Production PR funnel",
    subtitle = sprintf("%d pull requests total — open vs merged vs closed-unmerged",
                       n_total),
    x = NULL, y = "Pull requests"
  ) +
  theme_dash() +
  theme(legend.position = "none")

save_svg(p4, "pr_funnel.svg",
         title = "DW-Production pull-request funnel: open vs merged vs closed-unmerged",
         desc  = "Bar chart of DW-Production pull-request counts bucketed by state.")

# ======================================================================== #
# Chart 5 — toolkit_drift.svg : version alignment across sector branches    #
# ======================================================================== #
# Small dataset embedded inline (not in data/). These are the nine DW-Production
# review/sector-*-2026-05-18 replication branches (NOT cso-toolkit's own
# branches); the 2026-05-18 audit found all nine adopting cso-toolkit v0.4.5.
# v0.4.6 is the in-flight cso-toolkit release.
drift_df <- data.frame(
  sector  = c("Nutrition (NT)", "HIV/AIDS (HVA)", "Immunization (IM)",
              "Water & Sanitation (WS)", "MNCH", "Child Mortality (CME)",
              "Education (ED)", "Women's Status (WT)", "Early Childhood Dev (ECD)"),
  version = 0.45,
  stringsAsFactors = FALSE
)
drift_df$sector <- factor(drift_df$sector, levels = rev(drift_df$sector))
in_flight <- 0.46  # cso-toolkit v0.4.6 dashed marker (in flight)

p5 <- ggplot(drift_df, aes(x = version, y = sector)) +
  geom_vline(xintercept = in_flight, linetype = "dashed",
             color = unname(OKABE_ITO["vermillion"]), linewidth = 0.6) +
  annotate("text", x = in_flight, y = Inf,
           label = "v0.4.6 (in flight)", hjust = 0.5, vjust = 1.3,
           size = 3, color = unname(OKABE_ITO["vermillion"])) +
  geom_segment(aes(x = 0.445, xend = version, yend = sector),
               color = "#cbd2da", linewidth = 0.8) +
  geom_point(color = unname(OKABE_ITO["green"]), size = 3) +
  scale_x_continuous(
    breaks = c(0.45, 0.46),
    labels = c("v0.4.5", "v0.4.6"),
    limits = c(0.445, 0.465)
  ) +
  coord_cartesian(clip = "off") +
  labs(
    title    = "cso-toolkit version adopted per DW-Production sector",
    subtitle = "2026-05-18 audit — all nine sector replications pinned at v0.4.5 (current release); v0.4.6 in flight",
    x = NULL, y = NULL
  ) +
  theme_dash() +
  theme(panel.grid.major.y = element_blank())

save_svg(p5, "toolkit_drift.svg",
         title = "cso-toolkit version adopted per DW-Production sector replication",
         desc  = "Lollipop chart; all nine sector replications from the 2026-05-18 audit sit at cso-toolkit v0.4.5, with v0.4.6 marked as the in-flight release.")

message("make_charts.R: 5 SVGs written to ", CHARTS_DIR)
