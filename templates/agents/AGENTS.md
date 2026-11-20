# Instructions for coding agents

This repository follows the cso-toolkit conventions: <https://unicef-drp.github.io/cso-toolkit/>. Read `README.md` and `decisions.md` before changing anything.

## Layout

- `profile_{{project_name}}.R`: the session profile. Every script sources it first. It reads the person's `user_config.yml`, sets `dw_mode`, and loads the toolkit copy in `00_functions/`.
- `00_functions/`: a copy of a cso-toolkit release, pinned in `.toolkit_manifest.yml`. **Never edit it.** Changes go to `unicef-drp/cso-toolkit`, and the copy is replaced by a newer release.
- `tools/check.R`: the local checks.
- `decisions.md`: the project's decisions and its record of AI use.

## Rules

- **R:** run scripts with `Rscript --no-init-file`, never `--vanilla` (it also drops `.Renviron` and the user library it sets).
- **The toolkit is already here.** Never clone, install or `library()` cso-toolkit to run anything in this repository; the profile loads the pinned copy. If a toolkit function seems wrong, describe what happened and propose an issue for `unicef-drp/cso-toolkit` to the person running the session. Never work around it by editing the copy.
- **Read and write through the toolkit:** `dw_use()` and `dw_save()`, so every output gets a provenance sidecar. No direct `read.csv()`, `haven::read_*()` or `write.csv()` on project data.
- **Session setup:** if the profile stops (missing `user_config.yml`, `dw_mode` or a package), report its exact message to the person. Never create or edit their `user_config.yml`, and never install packages without asking.
- **Session mode:** work as `dw_mode: reviewer` unless the person running the session sets `producer`. Never pass `takeover = TRUE` to `dw_save()` without their explicit approval, and never write to the canonical deposit (Teams, Z:) yourself.
- **No data in git.** Never commit microdata, extracts or caches. A new input gets a provenance sidecar and an `input_manifest.csv` row, committed with the code that uses it.
- **What you read leaves the machine.** Whatever you open is sent to the AI service. Never print rows of microdata or personal records (`head()`, `View()`, `cat` of a data file). Variable names, labels, counts and code are fine.
- **Before every push:** run `Rscript --no-init-file tools/check.R` from the repository root and fix what fails. Never skip it with `--no-verify`.
- **Git:** branch off `develop`; one logical change per commit, staged by path (never `git add -A`); pull requests into `develop`. Never force-push, and never push to `main`.
- **Tests:** a failing test means something changed. Find out why. Never change an expected value to make a test pass unless the person running the session agrees the change is intended, and list what moved in the pull request.
- **Numbers:** every number in a text traces to a file in `output/`. After a rerun, check comparative claims ("flat", "the same", "robust") against the new tables, not only the levels.
- **Decisions** go in `decisions.md` (dated, who decided, why), not in personal agent memory. Write an entry only after the person who decided confirms its wording.
- **Parallel sessions:** one git worktree per session. Never two sessions in the same folder, and never a second clone.
- **Ask before** adding collaborators, changing repository settings, sharing any file outside the team, or deleting anything you did not create.
