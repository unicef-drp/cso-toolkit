---
name: new-project
description: Start a new repository with the cso-toolkit scaffolders (research project or official statistics). Use when someone wants to create, scaffold or set up a new analysis, paper or statistics-production repository that follows the cso-toolkit conventions.
---

# Start a new cso-toolkit repository

The rules are in the handbook chapter "Starting a new repository": <https://unicef-drp.github.io/cso-toolkit/handbook/chapters/40-new-repository.html>. Follow it; this is the procedure.

1. **Ask which kind,** unless the person already said:
   - **research project:** a paper or study; git holds the small result tables and figures with their provenance sidecars;
   - **official statistics:** a production pipeline (a DW sector, an SDMX or data.unicef.org publication, survey processing); outputs are embargoed until publication and never enter git.
   Also ask for the project name (it becomes the folder and `profile_<name>.R`), where to create it, and whether it is single- or multi-producer (one person writes the outputs, or several).
2. **Create it** from R, with the toolkit loaded from a cso-toolkit clone:
   ```r
   create_research_project("<path>/<name>", collaboration = "single-producer", git = TRUE)
   # or
   create_official_stats_project("<path>/<name>", collaboration = "multi-producer",
                                 members = c("<user>", "<user>"), git = TRUE)
   ```
   Show the person the arguments the function takes (`?create_research_project`) before choosing any that are not defaults. Do not vendor the toolkit (`vendor = TRUE`) or add GitHub workflows (`workflows = TRUE`) unless they ask. With `git = TRUE` the function also sets `core.hooksPath` to `.githooks`, so the pre-push hook runs the checks.
3. **The person's own configuration:** the profile reads `user_config.yml` from their configuration folder. Never create or edit it for them. If the first `source("profile_<name>.R")` stops, show them its exact message: it names the YAML to add.
4. **Checks:** run `Rscript --no-init-file tools/check.R` from the new repository's root. A co-author's fresh clone runs `git config core.hooksPath .githooks` once.
5. **First commit:** stage by path (never `git add -A`), read `git diff --cached --stat`, and commit. Do not create the GitHub repository or push unless the person asks; ask whether it should be private (official statistics: always private).

Report what was created, the check result, and the steps left to the person (their `user_config.yml`, the GitHub repository, branch protection).
