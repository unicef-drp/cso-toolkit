# The two .gitignore templates under templates/gitignore/ share blocks
# (data and cache formats, secrets and personal configuration, language
# noise, OS and editors). People copy a single file, so each template stays
# complete, and this test keeps the shared blocks identical: a block whose
# header ends in "[shared]" must exist in both files with the same rules in
# the same order (order matters for `!` re-includes).
#
# The templates live at the repository root, outside the R package. The test
# looks for them via CSO_TOOLKIT_ROOT, then GITHUB_WORKSPACE (set on GitHub
# Actions), then by walking up from the working directory (devtools::test()
# and R CMD check run under ./r both reach the root that way). Off CI it
# skips when the templates cannot be found; on CI it fails instead.

gitignore_templates_dir <- function() {
  rel <- file.path("templates", "gitignore")
  candidates <- c(Sys.getenv("CSO_TOOLKIT_ROOT"), Sys.getenv("GITHUB_WORKSPACE"))
  candidates <- candidates[nzchar(candidates)]
  dir <- normalizePath(getwd(), winslash = "/", mustWork = FALSE)
  for (i in seq_len(10)) {
    candidates <- c(candidates, dir)
    parent <- dirname(dir)
    if (identical(parent, dir)) break
    dir <- parent
  }
  for (root in candidates) {
    p <- file.path(root, rel)
    if (file.exists(file.path(p, "research-project.gitignore")) &&
        file.exists(file.path(p, "official-stats.gitignore"))) {
      return(p)
    }
  }
  NULL
}

# A block starts at a header line such as
#   "# ---- 5. Secrets and personal configuration [shared] -----"
# and runs to the next header. Returns a named list, block title (number and
# trailing dashes stripped) -> its rule lines (comments and blanks dropped).
gitignore_blocks <- function(path) {
  lines <- sub("[[:space:]]+$", "", readLines(path, warn = FALSE))
  starts <- which(grepl("^# ---- ", lines))
  titles <- sub("^# ---- ([0-9]+\\.[[:space:]]*)?", "", lines[starts])
  titles <- sub("[[:space:]]*-*$", "", titles)
  ends <- c(starts[-1] - 1L, length(lines))
  blocks <- lapply(seq_along(starts), function(i) {
    body <- if (ends[i] > starts[i]) lines[(starts[i] + 1L):ends[i]] else character()
    body[nzchar(body) & !startsWith(body, "#")]
  })
  names(blocks) <- titles
  blocks
}

find_templates_or_skip <- function() {
  dir <- gitignore_templates_dir()
  if (is.null(dir)) {
    if (identical(Sys.getenv("CI"), "true")) {
      stop("templates/gitignore/ not found from the test directory on CI; ",
           "set CSO_TOOLKIT_ROOT to the repository root.")
    }
    skip("templates/gitignore/ not found (set CSO_TOOLKIT_ROOT to the repository root)")
  }
  dir
}

test_that("the [shared] blocks of the two .gitignore templates are identical", {
  dir <- find_templates_or_skip()
  research <- gitignore_blocks(file.path(dir, "research-project.gitignore"))
  official <- gitignore_blocks(file.path(dir, "official-stats.gitignore"))

  shared_r <- grep("\\[shared\\]$", names(research), value = TRUE)
  shared_o <- grep("\\[shared\\]$", names(official), value = TRUE)

  # Data and cache formats, secrets, language noise, OS and editors.
  expect_gte(length(shared_r), 4L)
  expect_setequal(shared_o, shared_r)
  expect_equal(anyDuplicated(shared_r), 0L)
  expect_equal(anyDuplicated(shared_o), 0L)

  for (title in intersect(shared_r, shared_o)) {
    expect_gt(length(research[[title]]), 0L)
    expect_identical(
      official[[title]], research[[title]],
      label = sprintf("official-stats block '%s'", title),
      expected.label = "the research-project copy"
    )
  }
})

test_that("the embargo and release-record rules stay in official-stats only", {
  dir <- find_templates_or_skip()
  official <- unlist(gitignore_blocks(file.path(dir, "official-stats.gitignore")),
                     use.names = FALSE)
  research <- unlist(gitignore_blocks(file.path(dir, "research-project.gitignore")),
                     use.names = FALSE)

  embargo <- c("**/output/**", "**/outputs/**", "**/results/**", "**/wrk/**")
  release <- c("releases/**", "!releases/**/", "!releases/**/output_manifest.*",
               "!releases/**/*.provenance.json")
  expect_true(all(embargo %in% official))
  expect_true(all(release %in% official))
  expect_false(any(c(embargo, release) %in% research))

  # The release record is re-included after the embargo, or block 1 would
  # swallow sidecars kept in an output/ sub-folder of a release.
  expect_gt(max(match(release, official)), max(match(embargo, official)))
  expect_gt(match("releases/**", official), max(match(embargo, official)))
})
