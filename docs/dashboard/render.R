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

# Interactive ggiraph charts are committed as standalone widget HTML (operator
# runs make_charts.R). Each is iframe-embedded so its JS/CSS deps stay isolated
# from the main page; aspect-ratio CSS keeps it responsive without letterboxing.
chart_frame <- function(file, title) {
  path <- file.path(CHARTS_DIR, file)
  if (!file.exists(path)) {
    return(sprintf('<div class="chart-missing">chart not yet generated: %s</div>',
                   htmlescape(file)))
  }
  sprintf(paste0('<iframe class="chart-frame" src="charts/%s" title="%s" ',
                 'loading="lazy" scrolling="no"></iframe>'),
          file, htmlescape(title))
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

# ----- per-sector replicated-indicator counts ------------------------------ #
# Derived from the authoritative parity.json (the same source behind the
# 3-way-parity + coverage charts). A sector's replicated count = max(repo-local
# "mine", Teams "dep"), summed over its indicator sets (WASH = 3 sets), because a
# run's output lands in one place. This reproduces the snapshot `indicators`
# field exactly for the sectors that carry it (nt 40, hva 23, im 18) and
# completes the rest (ws 55, mnch 27, cme 24, ed 16). BLOCKED sectors count 0 —
# their non-zero "dep" is the producer's prior deposit, not a replication.
PARITY_PATH <- file.path(DATA_DIR, "parity.json")
INDIC_BY_SECTOR <- local({
  if (!file.exists(PARITY_PATH)) return(list())
  rows <- jsonlite::fromJSON(PARITY_PATH, simplifyVector = FALSE)
  # Sum, over each sector's indicator sets, of max(repo-local "mine", Teams
  # "dep"). Per-set max (not max of the per-sector sums) so a sector whose sets
  # split between repo-local and Teams is counted correctly, not undercounted.
  agg <- list()
  for (r in rows) {
    sec <- sub("_.*$", "", r$key %||% "")
    if (!nzchar(sec)) next
    agg[[sec]] <- (agg[[sec]] %||% 0) + max(r$mine %||% 0, r$dep %||% 0)
  }
  rep <- state$replication %||% list()
  out <- list()
  for (sec in names(agg)) {
    out[[sec]] <- if (identical(rep[[sec]]$status, "BLOCKED")) 0L
                  else as.integer(agg[[sec]])
  }
  out
})
INDIC_TOTAL    <- as.integer(sum(unlist(INDIC_BY_SECTOR), na.rm = TRUE))
N_INDIC_SECTORS <- length(Filter(function(v) v > 0, INDIC_BY_SECTOR))

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

  # The dashboard tracks DW-Production sector work, so the PR/issue KPIs report
  # DW-Production. collect.R emits privacy-safe aggregate counts only (the repo
  # is private; the site is public), so read those — no per-item lists exist.
  dwc <- state$dw_production$counts %||% list()
  open_prs    <- dwc$prs_open    %||% 0L
  open_issues <- dwc$issues_open %||% 0L
  # Normalize status the same way render_tab_actions does (uppercase + _->-)
  # so we don't undercount in-progress/in_progress/IN-PROGRESS variants.
  open_actions <- length(Filter(function(a) {
    st <- gsub("_", "-", toupper(a$status %||% "TODO"))
    st %in% c("TODO", "IN-PROGRESS")
  }, state$actions %||% list()))

  # Subject-area coverage from the full 012_codes universe. "Not yet replicated"
  # = subject areas with no replication sector; of those, "folders empty" =
  # subjects whose 012_codes folder has no pipeline code yet (started == FALSE).
  topics      <- state$topics %||% list()
  topic_codes <- vapply(topics, function(t) t$code %||% "", character(1))
  n_subjects  <- length(topics)
  n_not_repl  <- length(setdiff(topic_codes, SECTOR_ORDER))
  n_empty     <- sum(vapply(topics, function(t) !isTRUE(t$started), logical(1)))

  list(
    n_sectors       = n_total,
    n_full          = n_full,
    n_partial       = n_partial,
    n_blocked       = n_blocked,
    open_prs        = open_prs,
    open_issues     = open_issues,
    open_actions    = open_actions,
    n_subjects      = n_subjects,
    n_not_repl      = n_not_repl,
    n_empty         = n_empty,
    indicators_replicated = INDIC_TOTAL,
    n_indic_sectors       = N_INDIC_SECTORS
  )
}

kpis <- compute_kpis(state)

# ----- HTML pieces --------------------------------------------------------- #

# KPI tiles are clickable deep-dive links: each jumps to the tab that explains
# the number. With JS the tab activates in place; without JS the href anchor
# still scrolls to the section (no-JS reveals every pane).
render_kpi_row <- function(kpis) {
  tiles <- list(
    list(label = "Sectors tracked",  value = kpis$n_sectors,    sub = "9 in scope",         jump = "tab-sectors"),
    list(label = "Fully replicated", value = kpis$n_full,       sub = "v0.4.x mode-lock",    jump = "tab-sectors"),
    list(label = "Partial",          value = kpis$n_partial,    sub = "halted mid-pipeline", jump = "tab-phases"),
    list(label = "Blocked",          value = kpis$n_blocked,    sub = "env / package issue", jump = "tab-phases", alert = isTRUE(kpis$n_blocked > 0)),
    list(label = "Not yet replicated", value = kpis$n_not_repl, sub = sprintf("%d subject folders empty", kpis$n_empty), jump = "tab-sectors", idle = TRUE),
    list(label = "Indicators replicated", value = kpis$indicators_replicated, sub = sprintf("across %d sectors (vs SDMX)", kpis$n_indic_sectors), jump = "tab-sectors"),
    list(label = "Open PRs",         value = kpis$open_prs,     sub = "DW-Production",        jump = "tab-issues"),
    list(label = "Open issues",      value = kpis$open_issues,  sub = "DW-Production",        jump = "tab-issues"),
    list(label = "DBM actions open", value = kpis$open_actions, sub = "across sectors",       jump = "tab-actions")
  )
  paste0(
    '<div class="kpi-row">',
    paste(vapply(tiles, function(t) {
      sprintf(
        '<a class="kpi%s%s" href="#%s" data-jump="%s"><div class="kpi-value">%s</div><div class="kpi-label">%s</div><div class="kpi-sub">%s</div></a>',
        if (isTRUE(t$alert)) " alert" else "",
        if (isTRUE(t$idle)) " idle" else "",
        htmlescape(t$jump), htmlescape(t$jump),
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
  # cso-toolkit PRs (public repo) — DW-Production PR titles are private and must
  # not be published, so the activity feed shows toolkit activity instead.
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

  # Hero: one status verdict + a clickable sector traffic-light strip.
  strip_html <- paste(vapply(SECTOR_ORDER, function(s) {
    r  <- rep[[s]] %||% list()
    st <- r$status %||% "UNKNOWN"
    cls  <- if (identical(st, "FULLY_REPLICATED")) "st-ok"
            else if (identical(st, "PARTIAL_REPLICATED")) "st-partial"
            else if (identical(st, "BLOCKED")) "st-blocked" else "st-partial"
    meta <- if (identical(st, "FULLY_REPLICATED")) "replicated"
            else if (identical(st, "PARTIAL_REPLICATED")) "partial" else "blocked"
    sprintf(paste0('<a class="s-dot" href="#tab-sectors" data-jump="tab-sectors" ',
                   'title="%s"><span class="s-code">%s</span>',
                   '<span class="s-state %s"></span><span class="s-meta">%s</span></a>'),
            htmlescape(SECTOR_LABELS[[s]] %||% s), toupper(htmlescape(s)), cls, meta)
  }, character(1)), collapse = "")

  hero_html <- sprintf(paste0(
    '<div class="hero">',
      '<div><span class="hero-num">%d</span><span class="hero-den">/ %d sectors replicated</span>',
        '<div class="hero-tags">',
          '<span class="tag tag-ok">%d replicated</span>',
          '<span class="tag tag-partial">%d partial</span>',
          '<span class="tag tag-blocked">%d blocked</span>',
          '<span class="tag tag-idle">%d not yet replicated</span>',
        '</div>',
        '<div class="hero-sub">%d subject areas tracked &middot; %d awaiting replication &middot; %d folders still empty</div>',
      '</div>',
      '<div><div class="strip-label">Sectors &middot; click to open</div>',
        '<div class="sector-strip">%s</div>',
      '</div>',
    '</div>'),
    kpis$n_full, kpis$n_sectors, kpis$n_full, kpis$n_partial, kpis$n_blocked,
    kpis$n_not_repl, kpis$n_subjects, kpis$n_not_repl, kpis$n_empty, strip_html)

  # DW-Production activity: privacy-safe counts + links that open on GitHub
  # (they resolve for viewers with access; the repo stays private).
  dwc <- state$dw_production$counts %||% list()
  dw_html <- if (!isTRUE(state$dw_production$reachable)) {
    '<div class="muted">DW-Production data unavailable (DW_PROD_READ_TOKEN not set).</div>'
  } else {
    sprintf(paste0(
      '<div class="dw-stat-row">',
        '<a class="dw-stat" href="#tab-issues" data-jump="tab-issues" style="text-decoration:none"><div class="n">%d</div><div class="l">open PRs</div></a>',
        '<a class="dw-stat" href="#tab-issues" data-jump="tab-issues" style="text-decoration:none"><div class="n">%d</div><div class="l">open issues</div></a>',
        '<a class="dw-stat" href="#tab-branches" data-jump="tab-branches" style="text-decoration:none"><div class="n">%d</div><div class="l">branches</div></a>',
      '</div>',
      '<div style="display:flex;gap:18px;flex-wrap:wrap;margin-bottom:8px">',
        '<a class="ghlink" href="https://github.com/unicef-drp/DW-Production/pulls">PRs on GitHub</a>',
        '<a class="ghlink" href="https://github.com/unicef-drp/DW-Production/issues">Issues on GitHub</a>',
      '</div>',
      '<div class="lock">Private repo &mdash; counts shown here; the GitHub links open for users with access.</div>'),
      dwc$prs_open %||% 0L, dwc$issues_open %||% 0L, dwc$branches_total %||% 0L)
  }

  # Subject-area topic tags (grey metadata pills), generated from the
  # DW-Production 012_codes folders; dashed = work not started.
  topics <- state$topics %||% list()
  tags_html <- if (length(topics) == 0) "" else paste0(
    '<div class="topic-tags" title="Subject areas (DW-Production 012_codes) — dashed = work not started">',
    paste(vapply(topics, function(t) {
      cls <- if (isTRUE(t$started)) "" else " not-started"
      lab <- if (isTRUE(t$started)) "" else ' aria-label="not started"'
      sprintf('<span class="topic-tag%s"%s>%s</span>', cls, lab, htmlescape(t$code))
    }, character(1)), collapse = ""),
    '<span class="topic-tags-note">dashed = not started</span>',
    '</div>')

  paste0(
    '<section id="tab-landing" class="tab-pane active">',
    '<h2>Strategic overview</h2>',
    '<p class="section-lead">Live status of the nine DW-Production sector replications, the toolkit they depend on, and the open work.</p>',
    tags_html,
    hero_html,
    render_kpi_row(kpis),
    '<div class="row">',
      '<div class="panel"><h3>Pipeline phases</h3>', phase_html, '</div>',
      '<div class="panel"><div class="panel-head"><h3>Watch list</h3><span class="muted">stalled sectors</span></div>', watch_html, '</div>',
    '</div>',
    '<div class="row">',
      '<div class="panel"><div class="panel-head"><h3>Recent cso-toolkit activity</h3>',
        '<a class="ghlink" href="https://github.com/unicef-drp/cso-toolkit/pulls">all PRs</a></div>', feed_html, '</div>',
      '<div class="panel"><div class="panel-head"><h3>DW-Production activity</h3>',
        '<a class="ghlink" href="#tab-issues" data-jump="tab-issues">by sector</a></div>', dw_html, '</div>',
    '</div>',
    '<div class="panel"><h3>How the data flows</h3>',
      '<div class="diagram-frame">', read_svg("data_flow_diagram.svg"), '</div>',
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
  # Indicator count from the authoritative parity.json (replicated = max repo /
  # Teams), falling back to the snapshot field; not shown for BLOCKED sectors.
  ind_html <- ""
  ind_val  <- INDIC_BY_SECTOR[[s]] %||% r$indicators
  if (!is.null(ind_val) && !identical(r$status, "BLOCKED")) {
    ind_html <- sprintf(
      '<div class="card-stat"><span class="k">indicators</span> <span class="v">%s</span></div>',
      htmlescape(ind_val)
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

  # Full subject-area universe: the nine tracked replication sectors above, plus
  # every other DW-Production 012_codes subject (generated from state$topics so
  # the set can't drift). The not-yet-tracked subjects render as grey placeholder
  # cards, so the page shows the whole roadmap, not only the active sectors.
  topics <- state$topics %||% list()
  others <- Filter(function(t) !((t$code %||% "") %in% SECTOR_ORDER), topics)
  others_html <- if (length(others) == 0) "" else paste0(
    '<h3>Other subject areas <span class="h3-note">&mdash; not yet replicated</span></h3>',
    '<div class="sector-grid">',
    paste(vapply(others, function(t) {
      code     <- toupper(htmlescape(t$code %||% ""))
      has_code <- isTRUE(t$started)
      pill     <- if (has_code) "not replicated" else "not started"
      folder_v <- if (has_code) "has code" else "empty"
      note     <- if (has_code)
        "Subject folder has pipeline code, but no replication run is captured yet — no snapshot, indicators or wall-time."
      else
        "Subject folder is still empty — no replication pipeline code yet."
      sprintf(paste0('<div class="sector-card idle">',
        '<div class="card-head"><span class="sector-tag">%s</span> ',
        '<span class="pill pill-muted">%s</span></div>',
        '<div class="card-stats">',
          '<div class="card-stat"><span class="k">012_codes folder</span> <span class="v">%s</span></div>',
          '<div class="card-stat"><span class="k">replication</span> <span class="v">none</span></div>',
        '</div>',
        '<p class="idle-note">%s</p></div>'),
        code, pill, folder_v, note)
    }, character(1)), collapse = ""),
    '</div>')

  charts_html <- paste0(
    '<p class="chart-hint">Hover any bar, tile or point for the underlying figure.</p>',
    '<div class="chart-grid">',
      '<div class="chart"><h4>3-way parity (repo vs Teams vs Helix)</h4>',
        chart_frame("3way_parity.html", "Indicator coverage: repo-local vs Teams deposit vs SDMX-published"), '</div>',
      '<div class="chart"><h4>Coverage matrix</h4>',
        chart_frame("coverage_matrix.html", "Coverage matrix: pipeline stage reached per indicator set"), '</div>',
      '<div class="chart"><h4>Replication wall-time</h4>',
        chart_frame("walltime.html", "Replication wall-time by sector"), '</div>',
      '<div class="chart"><h4>PR funnel</h4>',
        chart_frame("pr_funnel.html", "DW-Production pull-request funnel: open vs merged vs closed-unmerged"), '</div>',
      '<div class="chart"><h4>cso-toolkit drift</h4>',
        chart_frame("toolkit_drift.html", "cso-toolkit version adopted per DW-Production sector replication"), '</div>',
    '</div>'
  )

  paste0(
    '<section id="tab-sectors" class="tab-pane">',
    '<h2>Per-sector status</h2>',
    '<div class="sector-grid">', cards, '</div>',
    others_html,
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
    '<p class="section-lead">Each sector sits in the furthest phase it has reached. ',
    '<strong>Live</strong> = published to the SDMX endpoint; that step is not yet ',
    'instrumented, so Live shows 0 &mdash; this means "not tracked yet", not a failed publish.</p>',
    '<div class="kanban">', cols, '</div>',
    '</section>'
  )
}

# ----- Tab 4: DW-Production Branches --------------------------------------- #

render_tab_branches <- function(state) {
  bysec <- state$dw_production$by_sector %||% list()
  total <- state$dw_production$counts$branches_total %||% 0L
  if (length(bysec) == 0) {
    body <- '<div class="muted">DW-Production data unavailable (DW_PROD_READ_TOKEN not set)</div>'
  } else {
    rows <- paste(vapply(SECTOR_ORDER, function(s) {
      sprintf('<tr><td>%s</td><td>%d</td></tr>',
              htmlescape(SECTOR_LABELS[[s]] %||% s),
              bysec[[s]]$branches %||% 0L)
    }, character(1)), collapse = "")
    body <- sprintf(
      paste0('<p class="muted">DW-Production is a private repo; branch <em>counts</em> are ',
             'shown by sector (no branch names are published). %d branches total ',
             '(sector-tagged subset listed; the remainder are cross-cutting / infra). ',
             'GitHub branches have no open/closed state &mdash; merged work removes the branch, ',
             'so this is the count of live branches per sector.</p>',
             '<div class="table-wrap"><table class="data-table"><thead><tr>',
             '<th>Sector</th><th>Branches</th></tr></thead><tbody>%s</tbody></table></div>'),
      total, rows
    )
  }
  paste0(
    '<section id="tab-branches" class="tab-pane">',
    '<div class="panel-head"><h2>DW-Production branches by sector</h2>',
      '<a class="ghlink" href="https://github.com/unicef-drp/DW-Production/branches">Branches on GitHub</a></div>',
    body,
    '</section>'
  )
}

# ----- Tab 5: Issues by milestone ------------------------------------------ #

render_tab_issues <- function(state) {
  bysec <- state$dw_production$by_sector %||% list()
  cnt   <- state$dw_production$counts %||% list()
  if (length(bysec) == 0) {
    body <- '<div class="muted">DW-Production data unavailable (DW_PROD_READ_TOKEN not set)</div>'
  } else {
    pct <- function(n, d) if (d > 0) round(100 * n / d) else 0L
    # ---- overall open-vs-closed bars (issues + PRs) ----
    io <- cnt$issues_open %||% 0L; ic <- cnt$issues_closed %||% 0L; it <- max(1L, io + ic)
    po <- cnt$prs_open %||% 0L; pm <- cnt$prs_merged %||% 0L
    pc <- (cnt$prs_total %||% 0L) - po - pm; pt <- max(1L, po + pm + pc)
    overview <- sprintf(paste0(
      '<div class="ovc"><span class="ovc-label">Issues</span><span class="ovc-bar">',
        '<span class="ovc-seg ovc-open" style="width:%d%%"></span>',
        '<span class="ovc-seg ovc-closed" style="width:%d%%"></span></span>',
        '<span class="ovc-nums">%d open &middot; %d closed</span></div>',
      '<div class="ovc"><span class="ovc-label">PRs</span><span class="ovc-bar">',
        '<span class="ovc-seg ovc-open" style="width:%d%%"></span>',
        '<span class="ovc-seg ovc-merged" style="width:%d%%"></span>',
        '<span class="ovc-seg ovc-closed" style="width:%d%%"></span></span>',
        '<span class="ovc-nums">%d open &middot; %d merged &middot; %d closed</span></div>'),
      pct(io, it), pct(ic, it), io, ic,
      pct(po, pt), pct(pm, pt), pct(pc, pt), po, pm, pc)

    # ---- per-sector table: counts + open/closed mini-bar + GitHub link ----
    rows <- paste(vapply(SECTOR_ORDER, function(s) {
      b <- bysec[[s]]
      so <- b$issues_open %||% 0L; sc <- b$issues_closed %||% 0L; stot <- max(1L, so + sc)
      gh <- sprintf("https://github.com/unicef-drp/DW-Production/issues?q=is%%3Aissue+%s",
                    utils::URLencode(s))
      sprintf(paste0('<tr><td>%s</td><td>%d</td><td>%d</td><td>%d</td><td>%d</td>',
        '<td><span class="mini-bar"><span class="mini-open" style="width:%d%%"></span>',
        '<span class="mini-closed" style="width:%d%%"></span></span></td>',
        '<td><a class="ghlink" href="%s">issues</a></td></tr>'),
        htmlescape(SECTOR_LABELS[[s]] %||% s),
        b$prs_open %||% 0L, b$prs_closed %||% 0L, so, sc,
        pct(so, stot), pct(sc, stot), gh)
    }, character(1)), collapse = "")
    body <- sprintf(paste0(
      '<p class="section-lead">Open vs closed across DW-Production (private repo &mdash; ',
      '<em>counts</em> only, no titles; click any "issues" link to open that sector\'s ',
      'real issues on GitHub). Per-sector rows cover sector-tagged PRs/issues; ',
      'cross-cutting and infrastructure items are counted in the totals above but ',
      'not attributed to a sector, so the rows need not sum to the bars.</p>%s',
      '<div class="table-wrap"><table class="data-table"><thead><tr>',
      '<th>Sector</th><th>Open PRs</th><th>Closed PRs</th><th>Open issues</th>',
      '<th>Closed issues</th><th>Issues (open/closed)</th><th>GitHub</th>',
      '</tr></thead><tbody>%s</tbody></table></div>'),
      overview, rows)
  }
  paste0(
    '<section id="tab-issues" class="tab-pane">',
    '<div class="panel-head"><h2>DW-Production PRs &amp; issues by sector</h2>',
      '<span><a class="ghlink" href="https://github.com/unicef-drp/DW-Production/pulls">PRs on GitHub</a>',
      ' &nbsp; <a class="ghlink" href="https://github.com/unicef-drp/DW-Production/issues">Issues on GitHub</a></span></div>',
    body,
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

  card_html <- function(a, home) {
    sev <- a$severity %||% "info"
    tag <- if (nzchar(a$sector %||% "")) sprintf('<span class="kc-tag">%s</span>', htmlescape(a$sector)) else ""
    own <- if (nzchar(a$owner  %||% "")) sprintf('<span>%s</span>', htmlescape(a$owner)) else ""
    sprintf(paste0(
      '<div class="kanban-card" draggable="true" data-aid="%s" data-home="%s">',
        '<div class="kc-title">%s</div>',
        '<div class="kc-meta">%s%s</div>',
        '<span class="sev sev-%s">%s</span>',
      '</div>'),
      htmlescape(a$id %||% a$title %||% ""), home,
      htmlescape(a$title %||% a$id %||% ""), tag, own,
      sev_class(sev), htmlescape(sev))
  }
  col_html <- function(name, items) {
    cards <- paste(vapply(items, function(a) card_html(a, name), character(1)), collapse = "")
    sprintf(paste0(
      '<div class="kanban-col" data-col="%s"><h3>%s <span class="kc-count">%d</span></h3>',
      '<div class="kanban-cards" data-col="%s">%s</div></div>'),
      name, htmlescape(name), length(items), name, cards)
  }

  paste0(
    '<section id="tab-actions" class="tab-pane">',
    '<div class="panel-head"><h2>DBM actions</h2>',
      '<span class="muted">Drag cards between columns &mdash; saved in your browser only ',
      '(canonical status lives in <code>data/actions/*.yml</code>). ',
      '<a href="#" id="kanban-reset">reset</a></span></div>',
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
  --navy: #002759;
  --navy-2: #0a3a73;
  --cyan: #1cabe2;
  --cyan-soft: #e7f6fc;
  --accent: #00689d;        /* cyan dark enough to pass AA as link text on white */
  --fg: #1a2230;
  --muted: #5a6573;
  --bg: #eef3f8;
  --card: #ffffff;
  --border: #dbe3ec;
  --ok: #1f8a4c;
  --partial: #b7791f;
  --blocked: #d3392a;
  --high: #9b2c2c;
  --info: #002759;
  --shadow: 0 1px 2px rgba(16,42,77,.06), 0 2px 8px rgba(16,42,77,.05);
}
* { box-sizing: border-box; }
body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, system-ui, sans-serif; color: var(--fg); background: var(--bg); }
a { color: var(--accent); }
h2 { margin: 0 0 4px; font-size: 20px; letter-spacing: -.2px; }
h3 { font-size: 15px; }

/* ---- branded header ---- */
header.app { background: var(--navy); color: #fff; padding: 14px 24px; display: flex; justify-content: space-between; align-items: center; gap: 16px; border-bottom: 3px solid var(--cyan); min-height: 58px; }
.brand { display: flex; align-items: center; gap: 14px; min-width: 0; }
.brand-mark { background: var(--cyan); color: var(--navy); font-weight: 800; font-size: 17px; letter-spacing: -.5px; padding: 5px 11px; border-radius: 4px; text-transform: lowercase; }
.brand-title { font-size: 18px; font-weight: 700; line-height: 1.15; }
.brand-sub { font-size: 12px; color: #a9c0da; }
header.app .meta { font-size: 12px; color: #a9c0da; text-align: right; white-space: nowrap; }

/* ---- nav ---- */
nav.tabs { display: flex; gap: 2px; padding: 0 24px; background: #fff; border-bottom: 1px solid var(--border); overflow-x: auto; box-shadow: var(--shadow); position: sticky; top: 0; z-index: 5; }
nav.tabs button { background: transparent; border: 0; padding: 13px 16px; font-size: 14px; color: var(--muted); cursor: pointer; border-bottom: 3px solid transparent; white-space: nowrap; }
nav.tabs button:hover { color: var(--navy); }
nav.tabs button.active { color: var(--navy); border-bottom-color: var(--cyan); font-weight: 600; }
nav.tabs button:focus-visible { outline: 2px solid var(--accent); outline-offset: -2px; }
main { padding: 18px 24px; max-width: 1380px; margin: 0 auto; }
.tab-pane { display: none; }
.tab-pane.active { display: block; }
.muted { color: var(--muted); font-size: 13px; }
.section-lead { color: var(--muted); font-size: 13px; margin: -2px 0 14px; }

/* ---- hero (landing) ---- */
.hero { background: linear-gradient(120deg, var(--navy) 0%, var(--navy-2) 100%); color: #fff; border-radius: 12px; padding: 18px 22px; margin-bottom: 16px; display: grid; grid-template-columns: minmax(220px, 320px) 1fr; gap: 22px; align-items: center; }
.hero-num { font-size: 52px; font-weight: 800; line-height: 1; }
.hero-den { font-size: 15px; color: #bcd2ea; margin-left: 6px; }
.hero-tags { margin-top: 12px; display: flex; flex-wrap: wrap; gap: 8px; }
.tag { font-size: 12px; font-weight: 600; padding: 4px 10px; border-radius: 20px; }
.tag-ok { background: rgba(46,204,113,.18); color: #b8f0cf; }
.tag-partial { background: rgba(247,184,1,.18); color: #ffe39a; }
.tag-blocked { background: rgba(231,76,60,.2); color: #ffc2bb; }
.tag-idle { background: rgba(255,255,255,.12); color: #cdd9e6; border: 1px dashed rgba(255,255,255,.3); }
.hero-sub { margin-top: 10px; font-size: 12px; color: #bcd2ea; }
.kpi.idle { background: #f5f7f9; border-style: dashed; }
.kpi.idle .kpi-value { color: #667085; }
.strip-label { font-size: 11px; text-transform: uppercase; letter-spacing: .6px; color: #91add0; margin-bottom: 8px; }
.sector-strip { display: grid; grid-template-columns: repeat(auto-fit, minmax(86px, 1fr)); gap: 8px; }
.s-dot { background: rgba(255,255,255,.07); border: 1px solid rgba(255,255,255,.12); border-radius: 8px; padding: 9px 8px; text-align: center; cursor: pointer; text-decoration: none; color: #fff; transition: transform .08s, background .12s; }
.s-dot:hover { transform: translateY(-2px); background: rgba(255,255,255,.13); }
.s-dot .s-code { font-size: 13px; font-weight: 700; }
.s-dot .s-state { display: block; height: 4px; border-radius: 3px; margin-top: 7px; }
.s-dot .s-meta { font-size: 10px; color: #b9cbe2; margin-top: 5px; }
.st-ok    { background: #2ecc71; }
.st-partial { background: #f7b801; }
.st-blocked { background: #e74c3c; }

/* ---- KPI tiles (clickable deep-dive links) ---- */
.kpi-row { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 12px; margin: 0 0 16px; }
a.kpi, .kpi { background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 15px 16px; display: block; text-decoration: none; color: inherit; box-shadow: var(--shadow); border-top: 3px solid var(--cyan); transition: transform .08s, box-shadow .12s; position: relative; }
a.kpi:hover { transform: translateY(-2px); box-shadow: 0 4px 14px rgba(16,42,77,.12); }
a.kpi:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
a.kpi::after { content: "\\2197"; position: absolute; top: 12px; right: 12px; color: var(--cyan); font-size: 13px; opacity: 0; transition: opacity .12s; }
a.kpi:hover::after { opacity: 1; }
.kpi-value { font-size: 30px; font-weight: 800; color: var(--navy); line-height: 1; }
.kpi-label { font-size: 12px; color: var(--muted); text-transform: uppercase; letter-spacing: .5px; margin-top: 6px; }
.kpi-sub { font-size: 11px; color: var(--muted); margin-top: 3px; }
.kpi.alert { border-top-color: var(--blocked); }
.kpi.alert .kpi-value { color: var(--blocked); }

/* ---- generic cards / panels ---- */
.row { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; margin: 16px 0; }
.panel { background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 14px 16px; box-shadow: var(--shadow); }
.panel h3 { margin: 0 0 10px; }
.panel-head { display: flex; justify-content: space-between; align-items: baseline; gap: 10px; margin: 0 0 10px; }
.panel-head h3 { margin: 0; }

/* ---- phase tiles ---- */
.phase-row { display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; }
.phase-tile { background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 14px; text-align: center; box-shadow: var(--shadow); }
.phase-tile.phase-production { border-top: 3px solid var(--info); }
.phase-tile.phase-review     { border-top: 3px solid var(--partial); }
.phase-tile.phase-live       { border-top: 3px solid var(--ok); }
.phase-name { font-size: 12px; color: var(--muted); text-transform: uppercase; }
.phase-count { font-size: 26px; font-weight: 800; color: var(--navy); }

/* ---- activity + watch ---- */
.activity-feed, .watch-list { list-style: none; padding: 0; margin: 0; }
.activity-feed li, .watch-list li { padding: 9px 0; border-bottom: 1px solid var(--border); font-size: 14px; }
.activity-feed li:last-child, .watch-list li:last-child { border-bottom: 0; }
.dw-stat-row { display: flex; gap: 10px; flex-wrap: wrap; margin-bottom: 12px; }
.dw-stat { background: var(--cyan-soft); border-radius: 8px; padding: 10px 14px; }
.dw-stat .n { font-size: 22px; font-weight: 800; color: var(--navy); }
.dw-stat .l { font-size: 11px; color: var(--muted); text-transform: uppercase; letter-spacing: .4px; }
.ghlink { display: inline-flex; align-items: center; gap: 5px; font-size: 13px; font-weight: 600; color: var(--accent); text-decoration: none; }
.ghlink:hover { text-decoration: underline; }
.ghlink::after { content: "\\2197"; font-size: 11px; }
.lock { font-size: 11px; color: var(--muted); }

/* ---- pills / sev ---- */
.pill { display: inline-block; padding: 2px 8px; font-size: 11px; border-radius: 10px; text-transform: uppercase; letter-spacing: .5px; }
.pill-open      { background: #fef3c7; color: #92400e; }
.pill-closed    { background: #e5e7eb; color: #374151; }
.pill-merged    { background: #e7e0fb; color: #5b3ea8; }
.pill-ok        { background: #d4f3e0; color: var(--ok); }
.pill-partial   { background: #fdf0c8; color: var(--partial); }
.pill-blocked   { background: #fbdcd8; color: var(--blocked); }
.pill-muted     { background: #e2e8f0; color: var(--muted); }
.sev { display: inline-block; padding: 2px 6px; font-size: 11px; border-radius: 4px; text-transform: uppercase; }
.sev-high { background: #fbdcd8; color: var(--high); }
.sev-info { background: #d6ecfa; color: var(--info); }
.sev-medium { background: #fdf0c8; color: var(--partial); }
.sev-low { background: #e5e7eb; color: var(--muted); }
.blocker { margin-top: 4px; font-size: 12px; color: var(--muted); }

/* ---- sector cards ---- */
.sector-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); gap: 16px; }
.sector-card { background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 15px; box-shadow: var(--shadow); }
.sector-card.idle { background: #f5f7f9; border-style: dashed; box-shadow: none; min-height: 150px; display: flex; flex-direction: column; }
.sector-card.idle .sector-tag { background: #e2e8ef; color: #667085; }
.sector-card.idle .card-stat .v { color: #8a93a0; }
.idle-note { margin: auto 0 0; font-size: 12px; color: var(--muted); }
.h3-note { font-weight: 400; font-size: 13px; color: var(--muted); }
.card-head { margin-bottom: 8px; display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
.sector-tag { display: inline-block; background: var(--navy); color: #fff; padding: 2px 7px; font-size: 11px; border-radius: 4px; text-transform: uppercase; font-weight: 700; }
.card-stats { display: flex; gap: 14px; flex-wrap: wrap; margin: 8px 0; font-size: 12px; }
.card-stat .k { color: var(--muted); margin-right: 4px; }
.card-stat .v { font-weight: 700; color: var(--navy); }
details { margin-top: 8px; font-size: 13px; }
details summary { cursor: pointer; color: var(--accent); }
.blocker-pre { white-space: pre-wrap; font-size: 12px; background: #f1f5fa; padding: 8px; border-radius: 6px; }

/* ---- charts / kanban / tables ---- */
.chart-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(360px, 1fr)); gap: 16px; margin-top: 12px; }
.chart { background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 12px 14px; box-shadow: var(--shadow); }
.chart h4 { margin: 0 0 8px; font-size: 14px; color: var(--navy); }
.chart svg { width: 100%; height: auto; }
.chart-frame { width: 100%; aspect-ratio: 7 / 4.5; border: 0; display: block; }
.chart-hint { font-size: 12px; color: var(--muted); margin: 4px 0 0; }
.chart-missing { font-size: 12px; color: var(--muted); font-style: italic; padding: 24px; text-align: center; }
.kanban { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; align-items: start; }
.kanban-col { background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 10px 12px; box-shadow: var(--shadow); }
.kanban-col h3 { margin: 0 0 8px; font-size: 12px; text-transform: uppercase; color: var(--muted); letter-spacing: .5px; }
.kc-count { display: inline-block; background: #eef3f9; color: var(--muted); border-radius: 10px; padding: 0 7px; font-size: 11px; font-weight: 700; vertical-align: middle; }
.kanban-cards { min-height: 36px; }
.kanban-card { background: #f7fafd; border: 1px solid var(--border); border-left: 3px solid var(--cyan); border-radius: 6px; padding: 8px 10px; margin-bottom: 7px; font-size: 13px; cursor: grab; }
.kanban-card:active { cursor: grabbing; }
.kanban-card.dragging { opacity: .45; }
.kanban-col.drop-target { outline: 2px dashed var(--cyan); outline-offset: -3px; background: var(--cyan-soft); }
.kc-title { font-weight: 600; font-size: 13px; line-height: 1.25; }
.kc-meta { font-size: 11px; color: var(--muted); margin: 3px 0 5px; display: flex; gap: 8px; flex-wrap: wrap; }
.kc-tag { background: var(--navy); color: #fff; border-radius: 3px; padding: 0 5px; text-transform: uppercase; font-weight: 700; }
.diagram-frame svg { width: 100%; height: auto; }
.data-table { width: 100%; border-collapse: collapse; font-size: 13px; background: var(--card); }
.data-table th, .data-table td { padding: 9px 12px; border-bottom: 1px solid var(--border); text-align: left; }
.data-table th { background: #eef3f9; color: var(--navy); font-size: 12px; text-transform: uppercase; letter-spacing: .4px; cursor: pointer; user-select: none; white-space: nowrap; }
.data-table th:hover { background: #e3ebf4; }
.data-table th.sort-asc::after { content: " \\25B2"; font-size: 9px; color: var(--cyan); }
.data-table th.sort-desc::after { content: " \\25BC"; font-size: 9px; color: var(--cyan); }
.data-table tbody tr:hover { background: #f6f9fc; }
.placeholder { padding: 24px; background: var(--card); border: 1px dashed var(--border); border-radius: 10px; }
code { background: #eef3f9; padding: 1px 5px; border-radius: 4px; font-size: 12px; }
.table-wrap { overflow-x: auto; }
.ovc { display: flex; align-items: center; gap: 10px; margin: 6px 0; max-width: 660px; }
.ovc-label { width: 56px; font-size: 12px; color: var(--muted); font-weight: 600; }
.ovc-bar { flex: 1; display: flex; height: 18px; border-radius: 5px; overflow: hidden; background: #eef3f9; }
.ovc-seg { height: 100%; }
.ovc-open { background: var(--cyan); }
.ovc-merged { background: var(--ok); }
.ovc-closed { background: #aab4c2; }
.ovc-nums { font-size: 12px; color: var(--muted); width: 180px; }
.mini-bar { display: inline-flex; width: 96px; height: 10px; border-radius: 3px; overflow: hidden; background: #eef3f9; vertical-align: middle; }
.mini-open { background: var(--cyan); }
.mini-closed { background: #c2cad6; }
.topic-tags { display: flex; flex-wrap: wrap; gap: 6px; margin: 2px 0 16px; }
.topic-tag { font-size: 11px; background: #eef2f6; color: #5a6573; border: 1px solid #e2e8ef; border-radius: 12px; padding: 2px 9px; text-transform: uppercase; letter-spacing: .3px; }
.topic-tag.not-started { background: #f5f7f9; color: #667085; border-style: dashed; }
.topic-tags-note { font-size: 10px; color: var(--muted); align-self: center; margin-left: 2px; font-style: italic; }

@media (max-width: 760px) {
  .hero { grid-template-columns: 1fr; }
  .row { grid-template-columns: 1fr; }
  .phase-row { grid-template-columns: repeat(3, 1fr); }
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
  // Clickable deep-dive elements (KPI tiles, sector dots, "by sector" / GitHub
  // links) anywhere on the page jump to their tab; the href is the no-JS fallback.
  document.addEventListener("click", function(e) {
    var el = e.target.closest && e.target.closest("[data-jump]");
    if (!el) { return; }
    e.preventDefault();
    activate(el.getAttribute("data-jump"));
    if (window.scrollTo) { window.scrollTo({ top: 0, behavior: "smooth" }); }
  });
  var hash = (location.hash || "").replace(/^#/, "");
  activate(hash && document.getElementById(hash) ? hash : "tab-landing");
})();

// ---- DBM kanban: HTML5 drag-drop with per-browser persistence ----
// Canonical status lives in data/actions/*.yml; moves here are a personal view
// saved to localStorage (they do not change the repo or other viewers boards).
(function() {
  var KEY = "dbm-kanban-v1";
  function cardsIn(col) { return document.querySelector(".kanban-cards[data-col=" + col + "]"); }
  function refreshCounts() {
    document.querySelectorAll(".kanban-col").forEach(function(c) {
      var n = c.querySelectorAll(".kanban-card").length;
      var badge = c.querySelector(".kc-count");
      if (badge) { badge.textContent = n; }
    });
  }
  function save() {
    var m = {};
    document.querySelectorAll(".kanban-card").forEach(function(card) {
      var holder = card.closest(".kanban-cards");
      if (!holder) { return; }
      var col = holder.getAttribute("data-col");
      if (col !== card.getAttribute("data-home")) { m[card.getAttribute("data-aid")] = col; }
    });
    try { localStorage.setItem(KEY, JSON.stringify(m)); } catch (e) {}
  }
  // restore saved positions
  var saved = {};
  try { saved = JSON.parse(localStorage.getItem(KEY) || "{}"); } catch (e) {}
  Object.keys(saved).forEach(function(aid) {
    var card = document.querySelector(".kanban-card[data-aid=" + aid + "]");
    var dest = cardsIn(saved[aid]);
    if (card && dest) { dest.appendChild(card); }
  });
  refreshCounts();

  var dragged = null;
  document.querySelectorAll(".kanban-card").forEach(function(card) {
    card.addEventListener("dragstart", function() { dragged = card; setTimeout(function(){ card.classList.add("dragging"); }, 0); });
    card.addEventListener("dragend", function() {
      card.classList.remove("dragging"); dragged = null;
      document.querySelectorAll(".kanban-col").forEach(function(c) { c.classList.remove("drop-target"); });
    });
  });
  document.querySelectorAll(".kanban-col").forEach(function(col) {
    col.addEventListener("dragover", function(e) { e.preventDefault(); col.classList.add("drop-target"); });
    col.addEventListener("dragleave", function(e) { if (e.target === col) { col.classList.remove("drop-target"); } });
    col.addEventListener("drop", function(e) {
      e.preventDefault(); col.classList.remove("drop-target");
      if (!dragged) { return; }
      col.querySelector(".kanban-cards").appendChild(dragged);
      save(); refreshCounts();
    });
  });
  var reset = document.getElementById("kanban-reset");
  if (reset) { reset.addEventListener("click", function(e) {
    e.preventDefault(); try { localStorage.removeItem(KEY); } catch (e2) {} location.reload();
  }); }
})();

// ---- Sortable data tables (vanilla, no deps) ----
(function() {
  function val(tr, i) {
    var td = tr.children[i];
    if (!td) { return ""; }
    var t = (td.getAttribute("data-sort") || td.textContent || "").trim();
    var n = parseFloat(t.replace(/[,\\s]/g, ""));
    return isNaN(n) ? t.toLowerCase() : n;
  }
  document.querySelectorAll("table.data-table").forEach(function(tbl) {
    var ths = Array.prototype.slice.call(tbl.querySelectorAll("thead th"));
    ths.forEach(function(th, i) {
      th.addEventListener("click", function() {
        var tbody = tbl.querySelector("tbody");
        if (!tbody) { return; }
        var rows = Array.prototype.slice.call(tbody.querySelectorAll("tr"));
        var asc = th.getAttribute("data-asc") !== "true";
        rows.sort(function(a, b) {
          var va = val(a, i), vb = val(b, i);
          return va < vb ? (asc ? -1 : 1) : va > vb ? (asc ? 1 : -1) : 0;
        });
        rows.forEach(function(r) { tbody.appendChild(r); });
        ths.forEach(function(h) { h.removeAttribute("data-asc"); h.classList.remove("sort-asc", "sort-desc"); });
        th.setAttribute("data-asc", asc ? "true" : "false");
        th.classList.add(asc ? "sort-asc" : "sort-desc");
      });
    });
  });
})();

// ---- External links open in a new tab (rel=noopener for safety) ----
// In-page links (data-jump "#tab-..." anchors) start with "#", so they are
// untouched; only http(s) links to other sites get target=_blank.
(function() {
  var links = document.querySelectorAll("a[href]");
  Array.prototype.forEach.call(links, function(a) {
    var h = a.getAttribute("href") || "";
    if (h.lastIndexOf("http", 0) === 0) {
      a.target = "_blank";
      a.rel = "noopener noreferrer";
    }
  });
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
  "<title>DW Operations Hub &middot; UNICEF</title>\n",
  '<meta name="viewport" content="width=device-width, initial-scale=1">\n',
  "<style>", CSS, "</style>\n",
  # No-JS fallback: reveal every pane so all content stays reachable.
  "<noscript><style>.tab-pane{display:block !important}</style></noscript>\n",
  "</head><body>\n",
  '<header class="app">',
    '<div class="brand">',
      '<span class="brand-mark">unicef</span>',
      '<div><div class="brand-title">DW Operations Hub</div>',
        '<div class="brand-sub">Data Warehouse &middot; sector-replication tracker</div></div>',
    '</div>',
    sprintf('<div class="meta">generated %s<br>%d sectors tracked</div>',
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
