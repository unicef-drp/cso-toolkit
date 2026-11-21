# Project skeletons

The files that `create_research_project()` and
`create_official_stats_project()` (R and Python) write into a new
repository, besides the templates they copy from the sibling folders
(`gitignore/`, `hooks/`, `tools/`, `testthat/`, `workflows/`,
`cso_project.yml`). Guidance: The CSO Handbook, chapter "Starting a new
repository".

| Folder | Used for |
|---|---|
| `common/` | both kinds of project |
| `research/` | `create_research_project()` (papers, analysis, replication packages) |
| `official-stats/` | `create_official_stats_project()` (DW sector pipelines, SDMX / data.unicef.org publication, survey processing) |

A project gets `common/` and then its own folder, at the same relative
paths. Text files may carry placeholders, filled in when the project is
created: `{{project_name}}` (the folder name), `{{title}}`,
`{{collaboration}}`, `{{date}}` (YYYY-MM-DD) and `{{input_manifest}}` (the
path of the input manifest).

The R package and the Python package ship copies of these templates
(`r/inst/templates/`, `python/src/templates/`). Edit the files here, then
run `python tools/sync_templates.py` from the repository root; a test in
each suite fails while a copy differs.
