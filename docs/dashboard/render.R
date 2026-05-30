#!/usr/bin/env Rscript
# docs/dashboard/render.R
# -----------------------------------------------------------------------------
# Render the cso-toolkit sector dashboard.
#
# Reads:
#   data/state.json
#   charts/3way_parity.svg
#   charts/coverage_matrix.svg
#   charts/walltime.svg
#   charts/pr_funnel.svg
#   charts/toolkit_drift.svg
#   charts/data_flow_diagram.svg
#
# Writes:
#   index.html  (single-page SPA, vanilla JS, 8 tabs)
#
# Tabs:
#   1 Landing               — KPIs + pipeline-phase distribution + activity + watch list
#   2 Sectors               — per-sector cards + 5 v2 charts
#   3 Pipeline Phases       — Production / Review / Live kanban
#   4 cso-toolkit Branches  — branch, last commit, author, ahead/behind, PR link
#   5 cso-toolkit Issues    — grouped by milestone (v0.4.6 / v0.5.0 / unlabelled)
#   6 DBM Actions kanban    — TODO / IN-PROGRESS / DONE
#   7 History trends        — line charts over time (placeholder day 1)
#   8 cso-toolkit           — toolkit version per branch + open v0.4.6 issues + cycle burndown
# -----------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(jsonlite)
})

SCRIPT_DIR    <- local({
  # Under `Rscript path/to/render.R`, commandArgs() carries `--file=...`.
  # `sys.frame(1)$ofile` is only set when source()d, so the old code fell back
  # to getwd() under Rscript and read state.json / charts from the wrong dir.
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
CHARTS_DIR    <- file.path(DASHBOARD_DIR, "charts")
STATE_PATH    <- file.path(DATA_DIR, "state.json")
OUT_HTML      <- file.path(DASHBOARD_DIR, "index.html")

SECTOR_ORDER  <- c("nt", "hva", "im", "ws", "mnch", "cme", "ed", "wt", "ecd")
SECTOR_LABELS <- c(
  nt   = "Nutrition (NT)",
  hva  = "HIV/AIDS (HVA)",
  im   = "Immunization (IM)",
  ws   = "Water & Sanitation (WS)",
  mnch = "MNCH",
  cme  = "Child Mortality (CME)",
  ed   = "Education (ED)",
  wt   = "Women's Status (WT)",
  ecd  = "Early Childhood Dev (ECD)"
)

# ----- helpers ------------------------------------------------------------- #

read_svg <- function(name) {
  path <- file.path(CHARTS_DIR, name)
  if (!file.exists(path)) {
    return(sprintf(
      '<div class="chart-missing">chart not yet generated: %s</div>',
      htmlescape(name)
    ))
  }
  paste(readLines(path, warn = FALSE), collapse = "\n")
}

htmlescape <- function(x) {
  if (is.null(x)) return("")
  x <- as.character(x)
  x <- gsub("&", "&amp;",  x, fixed = TRUE)
  x <- gsub("<", "&lt;",   x, fixed = TRUE)
  x <- gsub(">", "&gt;",   x, fixed = TRUE)
  x <- gsub('"', "&quot;", x, fixed = TRUE)
  x
}

fmtnum <- function(x) {
  if (is.null(x) || is.na(x)) return("&mdash;")
  if (is.numeric(x) && x >= 1e6) return(sprintf("%.2fM", x / 1e6))
  if (is.numeric(x) && x >= 1e3) return(sprintf("%.0fk",  x / 1e3))
  format(x, big.mark = ",")
}

`%||%` <- function(x, y) if (is.null(x)) y else x

# ----- state load ---------------------------------------------------------- #

if (!file.exists(STATE_PATH)) {
  stop(sprintf("state.json not found at %s — run collect.R first", STATE_PATH))
}
state <- jsonlite::fromJSON(STATE_PATH, simplifyVector = FALSE)

# ----- compute KPIs -------------------------------------------------------- #

compute_kpis <- function(state) {
  rep <- state$replication %||% list()
  n_total       <- length(SECTOR_ORDER)
  n_full        <- sum(vapply(SECTOR_ORDER, function(s) {
    identical(rep[[s]]$status, "FULLY_REPLICATED")
  }, logical(1)))
  n_partial     <- sum(vapply(SECTOR_ORDER, function(s) {
    identical(rep[[s]]$status, "PARTIAL_REPLICATED")
  }, logical(1)))
  n_blocked     <- sum(vapply(SECTOR_ORDER, function(s) {
    identical(rep[[s]]$status, "BLOCKED")
  }, logical(1)))

  open_prs    <- length(Filter(function(p) identical(p$state, "open"),
                               state$cso_toolkit$prs %||% list()))
  # GitHub's /issues endpoint returns PRs too; filter them out so the
  # KPI matches the Issues tab on github.com.
  issues_only <- Filter(function(i) is.null(i$pull_request),
                        state$cso_toolkit$issues %||% list())
  open_issues <- length(Filter(function(i) identical(i$state, "open"), issues_only))
  # Normalize status the same way render_tab_actions does (uppercase + _->-)
  # so we don't undercount in-progress/in_progress/IN-PROGRESS variants.
  open_actions <- length(Filter(function(a) {
    st <- gsub("_", "-", toupper(a$status %||% "TODO"))
    st %in% c("TODO", "IN-PROGRESS")
  }, state$actions %||% list()))

  list(
    n_sectors       = n_total,
    n_full          = n_full,
    n_partial       = n_partial,
    n_blocked       = n_blocked,
    open_prs        = open_prs,
    open_issues     = open_issues,
    open_actions    = open_actions
  )
}

kpis <- compute_kpis(state)

# ----- HTML pieces --------------------------------------------------------- #

render_kpi_row <- function(kpis) {
  tiles <- list(
    list(label = "Sectors tracked",  value = kpis$n_sectors,    sub = "9 sectors in scope"),
    list(label = "Fully replicated", value = kpis$n_full,       sub = "v0.4.x mode-lock"),
    list(label = "Partial",          value = kpis$n_partial,    sub = "blocked mid-pipeline"),
    list(label = "Blocked",          value = kpis$n_blocked,    sub = "env / package issue"),
    list(label = "Open PRs",         value = kpis$open_prs,     sub = "cso-toolkit"),
    list(label = "Open issues",      value = kpis$open_issues,  sub = "cso-toolkit"),
    list(label = "DBM actions open", value = kpis$open_actions, sub = "across sectors")
  )
  paste0(
    '<div class="kpi-row">',
    paste(vapply(tiles, function(t) {
      sprintf(
        '<div class="kpi"><div class="kpi-value">%s</div><div class="kpi-label">%s</div><div class="kpi-sub">%s</div></div>',
        htmlescape(t$value), htmlescape(t$label), htmlescape(t$sub)
      )
    }, character(1)), collapse = ""),
    "</div>"
  )
}

# ----- Tab 1: Landing ------------------------------------------------------ #

render_tab_landing <- function(state, kpis) {
  rep <- state$replication %||% list()

  # pipeline phase distribution: Production / Review / Live.
  # "Publishing" is omitted until state.json carries a field that can drive it.
  phase_counts <- list(
    Production = 0L, Review = 0L, Live = 0L
  )
  for (s in SECTOR_ORDER) {
    r <- rep[[s]]
    phase <- "Production"
    if (identical(r$status, "FULLY_REPLICATED")) phase <- "Review"
    if (!is.null(r$published) && isTRUE(r$published)) phase <- "Live"
    phase_counts[[phase]] <- phase_counts[[phase]] + 1L
  }

  phase_html <- paste0(
    '<div class="phase-row">',
    paste(vapply(names(phase_counts), function(p) {
      sprintf(
        '<div class="phase-tile phase-%s"><div class="phase-name">%s</div><div class="phase-count">%d</div></div>',
        tolower(p), p, phase_counts[[p]]
      )
    }, character(1)), collapse = ""),
    "</div>"
  )

  # activity feed: latest 8 PRs from cso-toolkit (sorted by updated_at desc;
  # GitHub API pagination order is not guaranteed to match recency).
  prs <- state$cso_toolkit$prs %||% list()
  prs_sorted <- if (length(prs) == 0) {
    prs
  } else {
    ts <- vapply(prs, function(p) {
      p$updated_at %||% p$created_at %||% ""
    }, character(1))
    prs[order(ts, decreasing = TRUE)]
  }
  feed_html <- if (length(prs_sorted) == 0) {
    '<div class="muted">no PR activity captured yet</div>'
  } else {
    paste0(
      '<ul class="activity-feed">',
      paste(vapply(head(prs_sorted, 8), function(pr) {
        sprintf(
          '<li><span class="pill pill-%s">%s</span> <a href="%s">#%s</a> %s <span class="muted">(%s)</span></li>',
          htmlescape(pr$state %||% "open"),
          htmlescape(pr$state %||% "open"),
          htmlescape(pr$html_url %||% "#"),
          htmlescape(pr$number   %||% ""),
          htmlescape(pr$title    %||% ""),
          htmlescape(pr$user$login %||% "")
        )
      }, character(1)), collapse = ""),
      "</ul>"
    )
  }

  # watch list: BLOCKED / PARTIAL sectors with blocker notes
  watch <- list()
  for (s in SECTOR_ORDER) {
    r <- rep[[s]]
    if (identical(r$status, "BLOCKED") || identical(r$status, "PARTIAL_REPLICATED")) {
      watch[[length(watch) + 1L]] <- list(
        sector  = s,
        label   = SECTOR_LABELS[[s]],
        status  = r$status,
        blocker = r$blockers_for_dbm %||% r$halt_reason %||% "(no blocker detail)"
      )
    }
  }
  watch_html <- if (length(watch) == 0) {
    '<div class="muted">no stalled sectors</div>'
  } else {
    paste0(
      '<ul class="watch-list">',
      paste(vapply(watch, function(w) {
        sprintf(
          '<li><strong>%s</strong> <span class="pill pill-%s">%s</span><div class="blocker">%s</div></li>',
          htmlescape(w$label),
          if (identical(w$status, "BLOCKED")) "blocked" else "partial",
          htmlescape(w$status),
          htmlescape(substr(w$blocker, 1, 280))
        )
      }, character(1)), collapse = ""),
      "</ul>"
    )
  }

  paste0(
    '<section id="tab-landing" class="tab-pane active">',
    '<h2>Strategic overview</h2>',
    render_kpi_row(kpis),
    '<div class="row">',
      '<div class="col">',
        '<h3>Pipeline phase distribution</h3>',
        phase_html,
      '</div>',
      '<div class="col">',
        '<h3>Diagram</h3>',
        '<div class="diagram-frame">', read_svg("data_flow_diagram.svg"), '</div>',
      '</div>',
    '</div>',
    '<div class="row">',
      '<div class="col">',
        '<h3>Activity feed</h3>',
        feed_html,
      '</div>',
      '<div class="col">',
        '<h3>Watch list (stalled sectors)</h3>',
        watch_html,
      '</div>',
    '</div>',
    '</section>'
  )
}

# ----- Tab 2: Sectors ------------------------------------------------------ #

render_sector_card <- function(s, r) {
  status <- r$status %||% "UNKNOWN"
  pill_class <- switch(
    status,
    FULLY_REPLICATED   = "ok",
    PARTIAL_REPLICATED = "partial",
    BLOCKED            = "blocked",
    "muted"
  )

  fixes <- r$fixes_applied %||% r$fixes_attempted %||% list()
  fixes_html <- if (length(fixes) == 0) {
    '<div class="muted">none</div>'
  } else {
    paste0("<ul>", paste(vapply(fixes, function(f) {
      sprintf("<li>%s</li>", htmlescape(f))
    }, character(1)), collapse = ""), "</ul>")
  }

  findings <- r$toolkit_findings %||% list()
  findings_html <- if (length(findings) == 0) {
    '<div class="muted">none</div>'
  } else {
    paste0("<ul>", paste(vapply(findings, function(f) {
      sprintf("<li>%s</li>", htmlescape(f))
    }, character(1)), collapse = ""), "</ul>")
  }

  blocker <- r$blockers_for_dbm
  blocker_html <- if (is.null(blocker) || identical(blocker, "")) {
    '<div class="muted">none</div>'
  } else {
    sprintf('<pre class="blocker-pre">%s</pre>', htmlescape(blocker))
  }

  # rows: top-level scalar, else sum the per-file outputs[] array (WS / ED carry
  # no scalar rows — their counts live in outputs[], which were being dropped).
  total_rows <- NULL
  n_files    <- 0L
  if (!is.null(r$rows)) {
    total_rows <- r$rows
  } else if (!is.null(r$outputs) && length(r$outputs) > 0) {
    total_rows <- sum(vapply(r$outputs, function(o) {
      v <- o$rows %||% 0; if (is.numeric(v)) v else 0
    }, numeric(1)))
    n_files <- length(r$outputs)
  }
  rows_html <- ""
  if (!is.null(total_rows)) {
    suffix <- if (n_files > 1L) sprintf(' <span class="muted">/ %d files</span>', n_files) else ""
    rows_html <- sprintf(
      '<div class="card-stat"><span class="k">rows</span> <span class="v">%s</span>%s</div>',
      fmtnum(total_rows), suffix
    )
  }
  ind_html <- ""
  if (!is.null(r$indicators)) {
    ind_html <- sprintf(
      '<div class="card-stat"><span class="k">indicators</span> <span class="v">%s</span></div>',
      htmlescape(r$indicators)
    )
  }
  walltime_html <- ""
  if (!is.null(r$wall_time_s)) {
    walltime_html <- sprintf(
      '<div class="card-stat"><span class="k">wall time</span> <span class="v">%.1fs</span></div>',
      r$wall_time_s
    )
  }

  sprintf(
    paste0(
      '<div class="sector-card">',
        '<div class="card-head">',
          '<span class="sector-tag">%s</span> ',
          '<strong>%s</strong> ',
          '<span class="pill pill-%s">%s</span>',
        '</div>',
        '<div class="card-stats">%s%s%s</div>',
        '<details><summary>Fixes applied (%d)</summary>%s</details>',
        '<details><summary>Toolkit findings (%d)</summary>%s</details>',
        '<details><summary>Blockers for DBM</summary>%s</details>',
      '</div>'
    ),
    htmlescape(s),
    htmlescape(SECTOR_LABELS[[s]] %||% s),
    pill_class, htmlescape(status),
    rows_html, ind_html, walltime_html,
    length(fixes), fixes_html,
    length(findings), findings_html,
    blocker_html
  )
}

render_tab_sectors <- function(state) {
  rep <- state$replication %||% list()
  cards <- paste(vapply(SECTOR_ORDER, function(s) {
    render_sector_card(s, rep[[s]] %||% list())
  }, character(1)), collapse = "")

  charts_html <- paste0(
    '<div class="chart-grid">',
      '<div class="chart"><h4>3-way parity (repo vs Teams vs Helix)</h4>',
        read_svg("3way_parity.svg"), '</div>',
      '<div class="chart"><h4>Coverage matrix</h4>',
        read_svg("coverage_matrix.svg"), '</div>',
      '<div class="chart"><h4>Replication wall-time</h4>',
        read_svg("walltime.svg"), '</div>',
      '<div class="chart"><h4>PR funnel</h4>',
        read_svg("pr_funnel.svg"), '</div>',
      '<div class="chart"><h4>cso-toolkit drift</h4>',
        read_svg("toolkit_drift.svg"), '</div>',
    '</div>'
  )

  paste0(
    '<section id="tab-sectors" class="tab-pane">',
    '<h2>Per-sector status</h2>',
    '<div class="sector-grid">', cards, '</div>',
    '<h3>Charts</h3>',
    charts_html,
    '</section>'
  )
}

# ----- Tab 3: Pipeline Phases ---------------------------------------------- #

render_tab_phases <- function(state) {
  rep <- state$replication %||% list()
  # "Publishing" is omitted until state.json carries a field that can drive it.
  phases <- list(
    Production = character(0),
    Review     = character(0),
    Live       = character(0)
  )
  for (s in SECTOR_ORDER) {
    r <- rep[[s]] %||% list()
    phase <- "Production"
    if (identical(r$status, "PARTIAL_REPLICATED")) phase <- "Production"
    if (identical(r$status, "FULLY_REPLICATED"))   phase <- "Review"
    if (isTRUE(r$published))                       phase <- "Live"
    phases[[phase]] <- c(phases[[phase]], s)
  }

  cols <- paste(vapply(names(phases), function(p) {
    cards <- if (length(phases[[p]]) == 0) {
      '<div class="muted">(empty)</div>'
    } else {
      paste(vapply(phases[[p]], function(s) {
        r <- rep[[s]] %||% list()
        sprintf(
          '<div class="kanban-card"><strong>%s</strong><br><span class="muted">%s</span></div>',
          htmlescape(SECTOR_LABELS[[s]] %||% s),
          htmlescape(r$status %||% "UNKNOWN")
        )
      }, character(1)), collapse = "")
    }
    sprintf(
      '<div class="kanban-col"><h3>%s</h3>%s</div>',
      htmlescape(p), cards
    )
  }, character(1)), collapse = "")

  paste0(
    '<section id="tab-phases" class="tab-pane">',
    '<h2>Pipeline phases</h2>',
    '<div class="kanban">', cols, '</div>',
    '</section>'
  )
}

# ----- Tab 4: cso-toolkit Branches ----------------------------------------- #

render_tab_branches <- function(state) {
  branches <- state$cso_toolkit$branches %||% list()
  if (length(branches) == 0) {
    body <- '<div class="muted">no branches captured</div>'
  } else {
    rows <- paste(vapply(branches, function(b) {
      sprintf(
        '<tr><td><code>%s</code></td><td><a href="https://github.com/unicef-drp/cso-toolkit/tree/%s">view</a></td><td>%s</td><td>%s</td></tr>',
        htmlescape(b$name %||% ""),
        htmlescape(b$name %||% ""),
        htmlescape(substr(b$commit$sha %||% "", 1, 7)),
        htmlescape(b$protected %||% FALSE)
      )
    }, character(1)), collapse = "")
    body <- sprintf(
      '<div class="table-wrap"><table class="data-table"><thead><tr><th>Branch</th><th>Link</th><th>SHA</th><th>Protected</th></tr></thead><tbody>%s</tbody></table></div>',
      rows
    )
  }
  paste0(
    '<section id="tab-branches" class="tab-pane">',
    '<h2>cso-toolkit branches</h2>',
    body,
    '</section>'
  )
}

# ----- Tab 5: Issues by milestone ------------------------------------------ #

render_tab_issues <- function(state) {
  issues <- state$cso_toolkit$issues %||% list()
  issues <- Filter(function(i) is.null(i$pull_request), issues)

  # Bucket by each issue's ACTUAL milestone title (null -> "unlabelled").
  # The old 2-pattern allowlist dumped real v0.4.3/v0.4.4/v0.4.5 milestones
  # into "unlabelled", asserting issues were unlabelled when they were not.
  title_of <- function(i) {
    t <- i$milestone$title %||% ""
    if (!nzchar(t)) "unlabelled" else t
  }
  titles <- vapply(issues, title_of, character(1))
  named  <- sort(unique(titles[titles != "unlabelled"]), decreasing = TRUE)
  order_names <- c(named, if ("unlabelled" %in% titles) "unlabelled")

  section <- function(name) {
    items <- issues[titles == name]
    if (length(items) == 0) return("")
    lis <- paste(vapply(items, function(i) {
      sev <- "info"
      labels <- vapply(i$labels %||% list(), function(l) l$name %||% "", character(1))
      if (any(grepl("HIGH|critical", labels, ignore.case = TRUE))) sev <- "high"
      sprintf(
        '<li><span class="sev sev-%s">%s</span> <a href="%s">#%s</a> %s <span class="muted">(%s)</span></li>',
        sev, sev,
        htmlescape(i$html_url %||% "#"),
        htmlescape(i$number   %||% ""),
        htmlescape(i$title    %||% ""),
        htmlescape(i$state    %||% "")
      )
    }, character(1)), collapse = "")
    sprintf("<h3>%s</h3><ul>%s</ul>", htmlescape(name), lis)
  }

  paste0(
    '<section id="tab-issues" class="tab-pane">',
    '<h2>cso-toolkit issues by milestone</h2>',
    paste(vapply(order_names, section, character(1)), collapse = ""),
    '</section>'
  )
}

# ----- Tab 6: DBM Actions kanban ------------------------------------------- #

render_tab_actions <- function(state) {
  actions <- state$actions %||% list()

  buckets <- list(TODO = list(), `IN-PROGRESS` = list(), DONE = list())
  for (a in actions) {
    st <- toupper(a$status %||% "TODO")
    st <- gsub("_", "-", st)
    if (!st %in% names(buckets)) st <- "TODO"
    buckets[[st]] <- c(buckets[[st]], list(a))
  }

  # Map severities to the supported CSS class set. Action severities are
  # HIGH/MEDIUM/LOW/INFO; CSS defines .sev-high/.sev-medium/.sev-low/.sev-info.
  sev_class <- function(sev) {
    s <- tolower(sev %||% "info")
    if (s %in% c("high", "medium", "low", "info")) s else "info"
  }

  col_html <- function(name, items) {
    cards <- if (length(items) == 0) {
      '<div class="muted">(empty)</div>'
    } else {
      paste(vapply(items, function(a) {
        sev   <- a$severity %||% "info"
        sprintf(
          '<div class="kanban-card"><div><strong>%s</strong></div><div class="muted">sector: %s</div><div class="muted">owner: %s</div><span class="sev sev-%s">%s</span></div>',
          htmlescape(a$title    %||% a$id %||% ""),
          htmlescape(a$sector   %||% ""),
          htmlescape(a$owner    %||% ""),
          sev_class(sev), htmlescape(sev)
        )
      }, character(1)), collapse = "")
    }
    sprintf('<div class="kanban-col"><h3>%s</h3>%s</div>', htmlescape(name), cards)
  }

  paste0(
    '<section id="tab-actions" class="tab-pane">',
    '<h2>DBM actions</h2>',
    '<div class="kanban">',
      col_html("TODO",        buckets$TODO),
      col_html("IN-PROGRESS", buckets$`IN-PROGRESS`),
      col_html("DONE",        buckets$DONE),
    '</div>',
    '</section>'
  )
}

# ----- Tab 7: History trends ----------------------------------------------- #

render_tab_history <- function(state) {
  paste0(
    '<section id="tab-history" class="tab-pane">',
    '<h2>History trends</h2>',
    '<p class="muted">Time series begin after the first overnight collection run. ',
    'Today is day 1 — only a single data point exists.</p>',
    '<div class="placeholder">',
    sprintf("Snapshot generated at: <code>%s</code>", htmlescape(state$generated_at %||% "")),
    '</div>',
    '</section>'
  )
}

# ----- Tab 8: cso-toolkit overview ----------------------------------------- #

render_tab_toolkit <- function(state) {
  open_v046 <- Filter(function(i) {
    is.null(i$pull_request) && identical(i$state, "open") &&
      grepl("0\\.4\\.6", i$milestone$title %||% "")
  }, state$cso_toolkit$issues %||% list())

  v046_html <- if (length(open_v046) == 0) {
    '<div class="muted">no open v0.4.6 issues</div>'
  } else {
    paste0(
      "<ul>",
      paste(vapply(open_v046, function(i) {
        sprintf(
          '<li><a href="%s">#%s</a> %s</li>',
          htmlescape(i$html_url %||% "#"),
          htmlescape(i$number   %||% ""),
          htmlescape(i$title    %||% "")
        )
      }, character(1)), collapse = ""),
      "</ul>"
    )
  }

  paste0(
    '<section id="tab-toolkit" class="tab-pane">',
    '<h2>cso-toolkit</h2>',
    '<h3>Open v0.4.6 issues</h3>',
    v046_html,
    '<h3>Cycle burndown</h3>',
    '<p class="muted">Burndown chart populates after history accumulates.</p>',
    '</section>'
  )
}

# ----- CSS + JS ------------------------------------------------------------ #

CSS <- '
:root {
  --fg: #1a1d23;
  --muted: #565f6d;
  --bg: #f6f7f9;
  --card: #ffffff;
  --border: #dde1e7;
  --accent: #2b6cb0;
  --ok: #2f855a;
  --partial: #b7791f;
  --blocked: #c53030;
  --high: #9b2c2c;
  --info: #2c5282;
}
* { box-sizing: border-box; }
body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif; color: var(--fg); background: var(--bg); }
header.app { padding: 16px 24px; background: #fff; border-bottom: 1px solid var(--border); display: flex; justify-content: space-between; align-items: center; }
header.app h1 { margin: 0; font-size: 18px; }
header.app .meta { font-size: 12px; color: var(--muted); }
nav.tabs { display: flex; gap: 4px; padding: 0 24px; background: #fff; border-bottom: 1px solid var(--border); overflow-x: auto; }
nav.tabs button { background: transparent; border: 0; padding: 12px 16px; font-size: 14px; color: var(--muted); cursor: pointer; border-bottom: 2px solid transparent; }
nav.tabs button.active { color: var(--accent); border-bottom-color: var(--accent); font-weight: 600; }
main { padding: 24px; max-width: 1400px; margin: 0 auto; }
.tab-pane { display: none; }
.tab-pane.active { display: block; }
h2 { margin-top: 0; }
.row { display: grid; grid-template-columns: 1fr 1fr; gap: 24px; margin: 24px 0; }
.col h3 { margin-top: 0; }
.kpi-row { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 12px; margin: 16px 0 24px; }
.kpi { background: var(--card); border: 1px solid var(--border); border-radius: 6px; padding: 14px; }
.kpi-value { font-size: 28px; font-weight: 600; }
.kpi-label { font-size: 12px; color: var(--muted); text-transform: uppercase; letter-spacing: .5px; }
.kpi-sub { font-size: 11px; color: var(--muted); margin-top: 4px; }
.phase-row { display: grid; grid-template-columns: repeat(3, 1fr); gap: 8px; }
.phase-tile { background: var(--card); border: 1px solid var(--border); border-radius: 6px; padding: 12px; text-align: center; }
.phase-tile.phase-production { border-top: 3px solid var(--info); }
.phase-tile.phase-review     { border-top: 3px solid var(--partial); }
.phase-tile.phase-live       { border-top: 3px solid var(--ok); }
.phase-name { font-size: 12px; color: var(--muted); text-transform: uppercase; }
.phase-count { font-size: 28px; font-weight: 600; }
.activity-feed, .watch-list { list-style: none; padding: 0; margin: 0; }
.activity-feed li, .watch-list li { padding: 8px 0; border-bottom: 1px solid var(--border); font-size: 14px; }
.muted { color: var(--muted); font-size: 13px; }
.pill { display: inline-block; padding: 2px 8px; font-size: 11px; border-radius: 10px; text-transform: uppercase; letter-spacing: .5px; }
.pill-open      { background: #fef3c7; color: #92400e; }
.pill-closed    { background: #e5e7eb; color: #374151; }
.pill-ok        { background: #c6f6d5; color: var(--ok); }
.pill-partial   { background: #fefcbf; color: var(--partial); }
.pill-blocked   { background: #fed7d7; color: var(--blocked); }
.pill-muted     { background: #e2e8f0; color: var(--muted); }
.blocker { margin-top: 4px; font-size: 12px; color: var(--muted); }
.sector-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); gap: 16px; }
.sector-card { background: var(--card); border: 1px solid var(--border); border-radius: 6px; padding: 14px; }
.card-head { margin-bottom: 8px; }
.sector-tag { display: inline-block; background: var(--info); color: #fff; padding: 2px 6px; font-size: 11px; border-radius: 4px; text-transform: uppercase; }
.card-stats { display: flex; gap: 12px; flex-wrap: wrap; margin: 8px 0; font-size: 12px; }
.card-stat .k { color: var(--muted); margin-right: 4px; }
.card-stat .v { font-weight: 600; }
details { margin-top: 8px; font-size: 13px; }
details summary { cursor: pointer; color: var(--accent); }
.blocker-pre { white-space: pre-wrap; font-size: 12px; background: #f0f3f7; padding: 8px; border-radius: 4px; }
.chart-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(360px, 1fr)); gap: 16px; margin-top: 16px; }
.chart { background: var(--card); border: 1px solid var(--border); border-radius: 6px; padding: 12px; }
.chart h4 { margin: 0 0 8px; font-size: 14px; }
.chart svg { width: 100%; height: auto; }
.chart-missing { font-size: 12px; color: var(--muted); font-style: italic; padding: 24px; text-align: center; }
.kanban { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 12px; }
.kanban-col { background: var(--card); border: 1px solid var(--border); border-radius: 6px; padding: 12px; min-height: 200px; }
.kanban-col h3 { margin-top: 0; font-size: 14px; text-transform: uppercase; color: var(--muted); }
.kanban-card { background: #fafbfc; border: 1px solid var(--border); border-radius: 4px; padding: 8px; margin-bottom: 8px; font-size: 13px; }
.diagram-frame svg { width: 100%; height: auto; }
.data-table { width: 100%; border-collapse: collapse; font-size: 13px; background: var(--card); }
.data-table th, .data-table td { padding: 8px 10px; border-bottom: 1px solid var(--border); text-align: left; }
.data-table th { background: #f0f3f7; }
.sev { display: inline-block; padding: 2px 6px; font-size: 11px; border-radius: 4px; text-transform: uppercase; }
.sev-high { background: #fed7d7; color: var(--high); }
.sev-info { background: #bee3f8; color: var(--info); }
.sev-medium { background: #fefcbf; color: var(--partial); }
.sev-low { background: #e5e7eb; color: var(--muted); }
.placeholder { padding: 24px; background: var(--card); border: 1px dashed var(--border); border-radius: 6px; }
code { background: #f0f3f7; padding: 1px 4px; border-radius: 3px; font-size: 12px; }
.table-wrap { overflow-x: auto; }
nav.tabs button:focus-visible { outline: 2px solid var(--accent); outline-offset: -2px; }
@media (max-width: 640px) {
  .row { grid-template-columns: 1fr; }
  .phase-row { grid-template-columns: repeat(2, 1fr); }
  nav.tabs { padding: 0 12px; }
  main { padding: 16px; }
}
'

JS <- '
(function() {
  var nav = document.querySelector("nav.tabs");
  var buttons = Array.prototype.slice.call(document.querySelectorAll("nav.tabs button"));
  var panes = Array.prototype.slice.call(document.querySelectorAll(".tab-pane"));
  // Wire the WAI-ARIA tabs pattern programmatically so the 8 render functions
  // stay simple: tablist / tab / tabpanel roles, aria-selected, aria-controls.
  if (nav) { nav.setAttribute("role", "tablist"); nav.setAttribute("aria-label", "Dashboard sections"); }
  buttons.forEach(function(b) {
    var id = b.dataset.target;
    b.setAttribute("role", "tab");
    b.id = id + "-tab";
    b.setAttribute("aria-controls", id);
    var pane = document.getElementById(id);
    if (pane) {
      pane.setAttribute("role", "tabpanel");
      pane.setAttribute("aria-labelledby", id + "-tab");
      pane.setAttribute("tabindex", "0");
    }
  });
  function activate(tabId, focus) {
    buttons.forEach(function(b) {
      var on = b.dataset.target === tabId;
      b.classList.toggle("active", on);
      b.setAttribute("aria-selected", on ? "true" : "false");
      b.tabIndex = on ? 0 : -1;            // roving tabindex
      if (on && focus) b.focus();
    });
    panes.forEach(function(p) { p.classList.toggle("active", p.id === tabId); });
    if (window.history && window.history.replaceState) {
      window.history.replaceState(null, "", "#" + tabId);
    }
  }
  buttons.forEach(function(b, idx) {
    b.addEventListener("click", function() { activate(b.dataset.target); });
    b.addEventListener("keydown", function(e) {
      var d = e.key === "ArrowRight" ? 1 : e.key === "ArrowLeft" ? -1 : 0;
      if (!d) { return; }
      e.preventDefault();
      activate(buttons[(idx + d + buttons.length) % buttons.length].dataset.target, true);
    });
  });
  var hash = (location.hash || "").replace(/^#/, "");
  activate(hash && document.getElementById(hash) ? hash : "tab-landing");
})();
'

# ----- assemble ------------------------------------------------------------ #

tabs_def <- list(
  list(id = "tab-landing",  label = "Landing"),
  list(id = "tab-sectors",  label = "Sectors"),
  list(id = "tab-phases",   label = "Pipeline phases"),
  list(id = "tab-branches", label = "Branches"),
  list(id = "tab-issues",   label = "Issues"),
  list(id = "tab-actions",  label = "DBM actions"),
  list(id = "tab-history",  label = "History"),
  list(id = "tab-toolkit",  label = "cso-toolkit")
)

nav_html <- paste0(
  '<nav class="tabs">',
  paste(vapply(tabs_def, function(t) {
    sprintf(
      '<button data-target="%s"%s>%s</button>',
      t$id,
      if (identical(t$id, "tab-landing")) ' class="active"' else "",
      htmlescape(t$label)
    )
  }, character(1)), collapse = ""),
  "</nav>"
)

panes_html <- paste0(
  render_tab_landing(state, kpis),
  render_tab_sectors(state),
  render_tab_phases(state),
  render_tab_branches(state),
  render_tab_issues(state),
  render_tab_actions(state),
  render_tab_history(state),
  render_tab_toolkit(state)
)

html <- paste0(
  "<!doctype html>\n",
  '<html lang="en"><head><meta charset="utf-8">\n',
  "<title>cso-toolkit sector dashboard</title>\n",
  '<meta name="viewport" content="width=device-width, initial-scale=1">\n',
  "<style>", CSS, "</style>\n",
  # No-JS fallback: reveal every pane so all content stays reachable.
  "<noscript><style>.tab-pane{display:block !important}</style></noscript>\n",
  "</head><body>\n",
  '<header class="app">',
    '<h1>cso-toolkit sector dashboard</h1>',
    sprintf('<div class="meta">generated %s &middot; %d sectors</div>',
            htmlescape(state$generated_at %||% ""), length(SECTOR_ORDER)),
  "</header>\n",
  nav_html, "\n",
  "<main>\n",
  panes_html,
  "</main>\n",
  "<script>", JS, "</script>\n",
  "</body></html>\n"
)

writeLines(html, OUT_HTML, useBytes = TRUE)
message(sprintf("wrote %s (%d bytes)", OUT_HTML, file.info(OUT_HTML)$size))
