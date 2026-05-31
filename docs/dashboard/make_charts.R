#!/usr/bin/env Rscript
# docs/dashboard/make_charts.R
# -----------------------------------------------------------------------------
# Generate the five interactive (ggiraph) charts for the cso-toolkit dashboard.
#
# Loads ggplot2/ggiraph ONCE and writes five self-contained-as-a-folder HTML
# widgets to charts/. Reproducible from committed data only — no network, no
# per-sector R re-runs.
#
# This script is OPERATOR-run, NOT run in CI. The GitHub Action runs only
# collect.R + render.R (jsonlite-only); render.R iframe-embeds the committed
# chart widgets below. So the charts/ HTML + charts/lib/ MUST be committed.
#
# Reads:
#   data/parity.json                            (3-way parity counts)
#   data/state.json                             (dw_production.counts for the funnel)
#   data/snapshots/replication_<sector>_latest.json  (wall_time_s per sector)
#
# Writes:
#   charts/3way_parity.html
#   charts/coverage_matrix.html
#   charts/walltime.html
#   charts/pr_funnel.html
#   charts/toolkit_drift.html
#   charts/lib/                                 (shared ggiraph/d3 deps, no CDN)
#
# Each chart is a ggiraph girafe() widget saved via saveWidget(selfcontained =
# FALSE, libdir = "lib"): a small standalone HTML that loads its JS/CSS/fonts
# from the shared local charts/lib/ — works fully offline, no CDN. render.R
# embeds each as <iframe src="charts/<name>.html"> so the widget deps stay
# isolated from the main page. Hover highlights cyan; tooltips are navy chips.
#
# Required (operator side only): jsonlite, ggplot2, ggiraph, htmlwidgets
# -----------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(jsonlite)
  library(ggplot2)
  library(ggiraph)       # interactive geoms (hover + tooltip)
  library(htmlwidgets)   # saveWidget
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

# ----- girafe writer: interactive widget -> self-contained-as-a-folder HTML - #

# Brand interactivity: hover highlights the focused element cyan; tooltips are
# navy chips. Selection is off (we only want hover read-outs, not click-select).
GIRAFE_OPTS <- list(
  ggiraph::opts_hover(css = "fill:#1CABE2;stroke:#1CABE2;cursor:pointer;"),
  ggiraph::opts_tooltip(
    css = paste0("background:#002759;color:#fff;padding:5px 9px;border-radius:5px;",
                 "font-family:sans-serif;font-size:12px;line-height:1.35;",
                 "box-shadow:0 2px 8px rgba(0,0,0,.25);"),
    opacity = 0.98),
  ggiraph::opts_selection(type = "none"),
  # saveaspng = TRUE: a working PNG download. hidden = "fullscreen": ggiraph's
  # fullscreen is a position:fixed modal appended inside the iframe document, so
  # it is trapped in the small iframe box and cannot fill the screen. We hide it
  # and provide a parent-level fullscreen control (render.R) that fullscreens the
  # iframe element itself via the real Fullscreen API.
  ggiraph::opts_toolbar(saveaspng = TRUE, hidden = "fullscreen"),
  ggiraph::opts_sizing(rescale = TRUE)  # fill the iframe width, preserve aspect
)

save_girafe <- function(plot, name, width = W_IN, height = H_IN) {
  stopifnot(grepl("\\.html$", name))
  path <- file.path(CHARTS_DIR, name)
  g <- ggiraph::girafe(ggobj = plot, width_svg = width, height_svg = height,
                       options = GIRAFE_OPTS)
  # Fill the host iframe instead of saveWidget's default fixed 960x500 box, so
  # opts_sizing(rescale) has a container width to scale the SVG to. Combined with
  # the iframe's aspect-ratio CSS (matching width:height), the chart fits exactly.
  g$sizingPolicy <- htmlwidgets::sizingPolicy(
    browser.fill = TRUE, viewer.fill = TRUE, knitr.figure = FALSE,
    defaultWidth = "100%", defaultHeight = "100%", padding = 0
  )
  # selfcontained = FALSE + a shared libdir: every chart loads its JS/CSS/fonts
  # from charts/lib/ (no CDN, no pandoc dependency). render.R iframes each html.
  htmlwidgets::saveWidget(g, path, selfcontained = FALSE, libdir = "lib")
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
p1_df$tt   <- paste0(as.character(p1_df$label), " — ", as.character(p1_df$series),
                     ": ", p1_df$value, " indicators")
p1_df$ttid <- paste(p1_df$label, p1_df$series)

pal_3way <- c(
  MINE = unname(OKABE_ITO["blue"]),       # repo-local
  DEP  = unname(OKABE_ITO["orange"]),     # Teams deposit
  SDMX = unname(OKABE_ITO["sky_blue"])    # SDMX-published ceiling
)

p1 <- ggplot(p1_df, aes(x = label, y = value, fill = series)) +
  geom_col_interactive(aes(tooltip = tt, data_id = ttid),
                       position = position_dodge(width = 0.78), width = 0.72) +
  coord_flip() +
  scale_fill_manual(values = pal_3way) +
  labs(
    title    = "Indicator coverage — repo-local vs Teams deposit vs SDMX-published",
    subtitle = "Bars per indicator set; gap to SDMX = indicators published but not yet replicated locally",
    x = NULL, y = "Indicators"
  ) +
  theme_dash()

save_girafe(p1, "3way_parity.html")

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
status_lab  <- c(full = "full (= SDMX ceiling)", partial = "partial", none = "none")
p2_df$tt    <- paste0(as.character(p2_df$label), " — ", as.character(p2_df$stage_x),
                      ": ", status_lab[as.character(p2_df$status)])
p2_df$ttid  <- paste(p2_df$label, p2_df$stage_x)

p2 <- ggplot(p2_df, aes(x = stage_x, y = label, fill = status)) +
  geom_tile_interactive(aes(tooltip = tt, data_id = ttid),
                        color = "#ffffff", linewidth = 1.1) +
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

save_girafe(p2, "coverage_matrix.html")

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
p3_df$tt    <- paste0(as.character(p3_df$label), ": ", p3_df$tag, " wall time")
p3_df$ttid  <- as.character(p3_df$label)

p3 <- ggplot(p3_df, aes(x = label, y = secs)) +
  geom_col_interactive(aes(tooltip = tt, data_id = ttid),
                       fill = unname(OKABE_ITO["blue"]), width = 0.68) +
  geom_text(aes(label = tag), hjust = -0.12, size = 3.1, color = "#1a1d23") +
  coord_flip() +
  scale_y_sqrt(expand = expansion(mult = c(0, 0.18))) +
  labs(
    title    = "Replication wall-time by sector",
    subtitle = "sqrt scale — Nutrition (~25 min, 8 splits) dwarfs the others",
    x = NULL, y = "Wall time (s, sqrt scale)"
  ) +
  theme_dash()

save_girafe(p3, "walltime.html")

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
p4_df$tt   <- paste0(as.character(p4_df$stage), ": ", p4_df$count, " pull requests")
p4_df$ttid <- as.character(p4_df$stage)

pal_pr <- c(
  "Open"              = unname(OKABE_ITO["orange"]),
  "Merged"            = unname(OKABE_ITO["green"]),
  "Closed (unmerged)" = "#9aa3ae"
)

p4 <- ggplot(p4_df, aes(x = stage, y = count, fill = stage)) +
  geom_col_interactive(aes(tooltip = tt, data_id = ttid), width = 0.66) +
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

save_girafe(p4, "pr_funnel.html")

# ======================================================================== #
# Chart 5 — toolkit_drift.svg : version alignment across sector branches    #
# ======================================================================== #
# Small dataset embedded inline (not in data/). These are the nine DW-Production
# review/sector-*-2026-05-18 replication branches (NOT cso-toolkit's own
# branches); the 2026-05-18 audit found all nine adopting cso-toolkit v0.4.5.
# v0.4.6 is the next cso-toolkit release. This is a fixed point-in-time audit,
# not live data — labelled as such so it cannot go stale.
drift_df <- data.frame(
  sector  = c("Nutrition (NT)", "HIV/AIDS (HVA)", "Immunization (IM)",
              "Water & Sanitation (WS)", "MNCH", "Child Mortality (CME)",
              "Education (ED)", "Women's Status (WT)", "Early Childhood Dev (ECD)"),
  version = 0.45,
  stringsAsFactors = FALSE
)
drift_df$sector <- factor(drift_df$sector, levels = rev(drift_df$sector))
drift_df$tt   <- paste0(as.character(drift_df$sector),
                        " — cso-toolkit v0.4.5 (2026-05-18 audit)")
drift_df$ttid <- as.character(drift_df$sector)
in_flight <- 0.46  # cso-toolkit v0.4.6 dashed marker (next release)

p5 <- ggplot(drift_df, aes(x = version, y = sector)) +
  geom_vline(xintercept = in_flight, linetype = "dashed",
             color = unname(OKABE_ITO["vermillion"]), linewidth = 0.6) +
  annotate("text", x = in_flight, y = Inf,
           label = "v0.4.6 (next release)", hjust = 0.5, vjust = 1.3,
           size = 3, color = unname(OKABE_ITO["vermillion"])) +
  geom_segment(aes(x = 0.445, xend = version, yend = sector),
               color = "#cbd2da", linewidth = 0.8) +
  geom_point_interactive(aes(tooltip = tt, data_id = ttid),
                         color = unname(OKABE_ITO["green"]), size = 3) +
  scale_x_continuous(
    breaks = c(0.45, 0.46),
    labels = c("v0.4.5", "v0.4.6"),
    limits = c(0.445, 0.465)
  ) +
  coord_cartesian(clip = "off") +
  labs(
    title    = "cso-toolkit version adopted per DW-Production sector",
    subtitle = paste0("Point-in-time audit (2026-05-18): all nine sector ",
                      "replications had adopted cso-toolkit v0.4.5"),
    x = NULL, y = NULL
  ) +
  theme_dash() +
  theme(panel.grid.major.y = element_blank())

save_girafe(p5, "toolkit_drift.html")

message("make_charts.R: 5 interactive charts written to ", CHARTS_DIR)
