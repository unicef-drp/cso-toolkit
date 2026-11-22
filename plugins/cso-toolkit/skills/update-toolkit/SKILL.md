---
name: update-toolkit
description: Update the vendored cso-toolkit copy (00_functions/) in a consumer repository to a newer release with cso_toolkit_sync(), reading the release notes for breaking changes and re-running the checks. Use when cso_toolkit_check() reports a newer tag, or someone asks to update, refresh or upgrade the toolkit.
---

# Update the vendored toolkit

Handbook: "The vendoring model" (<https://unicef-drp.github.io/cso-toolkit/handbook/chapters/41-vendoring.html>) and "Vintage sync" (<https://unicef-drp.github.io/cso-toolkit/handbook/chapters/34-vintage-sync.html>).

An update is a producer decision, made by a person: nothing updates on its own, and a repository may stay on an older release on purpose. `cso_toolkit_sync()` refuses in reviewer mode. If the session is a reviewer, tell the person, who decides whether to run this one call as producer; never edit their `user_config.yml`.

1. **Where it stands:** `cso_toolkit_check()` names the pinned version (`pulled_version` in `00_functions/.toolkit_manifest.yml`) and the latest upstream tag.
2. **Work on a branch:** `feature/toolkit-<tag>` off `develop`, with `00_functions/` committed and clean (the sync refuses uncommitted changes there).
3. **Read what changes, writing nothing:**
   ```r
   cso_toolkit_sync(target_version = "<tag>", dry_run = TRUE)
   ```
   It prints the upstream `NEWS.md` sections since the pinned version, marking with `!!` the entries under *Breaking* or *Changed*, then the file-by-file comparison (`changed`, `unchanged`, `local_edit`, `missing_local`, `missing_upstream`). Tell the person every `!!` entry and every local edit before going on, and ask which tag to update to. With a local cso-toolkit clone, pass `toolkit_source = "<clone>"` (no network needed); otherwise it reads the tag from GitHub.
4. **Update:**
   ```r
   cso_toolkit_sync(target_version = "<tag>")   # asks per file; confirm = FALSE in a script
   ```
   It writes each changed file from the release tag, never from a working tree, skips local edits (it says which), keeps files gone upstream with a warning, and re-pins the manifest (`pulled_version`, `pulled_commit`, the date, `pulled_by`, the `files:` hashes). A `README.md` listed under `vendored:` is updated too. In Python: `cso_toolkit.cso_toolkit_sync(...)`, the same arguments.
5. **Re-run the checks** (`sh tools/check`) and the pipeline's tests. A test that pins published numbers and now fails means the update moves numbers: report which, with `dw_compare(..., diagnose = TRUE)` where useful. Never re-pin to make it pass.
6. **Commit** the vendored files and the manifest together, in one commit naming the old and new tags ("Update cso-toolkit v0.10.0 -> v0.11.0"). Then `sh tools/check --record`, and push. The pull request lists the NEWS entries that matter to this repository and what the checks showed.
