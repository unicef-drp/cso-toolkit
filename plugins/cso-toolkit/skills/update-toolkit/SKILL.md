---
name: update-toolkit
description: Update the vendored cso-toolkit copy (00_functions/) in a consumer repository to a newer release, reading the release notes for breaking changes and re-running the checks. Use when cso_toolkit_check() reports a newer tag, or someone asks to update, refresh or upgrade the toolkit.
---

# Update the vendored toolkit

Handbook: "The vendoring model" (<https://unicef-drp.github.io/cso-toolkit/handbook/chapters/41-vendoring.html>) and "Vintage sync" (<https://unicef-drp.github.io/cso-toolkit/handbook/chapters/34-vintage-sync.html>).

An update is a producer decision, made by a person: nothing updates on its own, and a repository may stay on an older release on purpose. It needs network access, so it runs in a producer session.

1. **Where it stands:** `cso_toolkit_check()` names the pinned version (`pulled_version` in `00_functions/.toolkit_manifest.yml`) and the latest upstream tag.
2. **Read what changed:** the `NEWS.md` sections of cso-toolkit between the two tags. List every *Breaking*, *Changed* and *Fixed* entry that touches a vendored file, and tell the person before changing anything. Ask which tag to update to.
3. **Update on a branch** (`feature/toolkit-<tag>` off `develop`), from the release tag, never from a working tree or a branch:
   - `cso_toolkit_diff()` shows which vendored files differ;
   - `cso_toolkit_pull("<tag>")` is the intended command, but its final step (fetching and overwriting the files) is not implemented yet. Until it is, copy each file listed under `vendored:` from the tag, for example `git -C <cso-toolkit clone> show <tag>:r/R/<file> > 00_functions/<file>`;
   - leave files listed under `local_edits:` alone and tell the person;
   - update `pulled_version`, `pulled_date` and `pulled_by` in the manifest.
4. **Re-run the checks** (`Rscript --no-init-file tools/check.R`) and the pipeline's tests. A test that pins published numbers and now fails means the update moves numbers: report which, with `dw_compare()` where useful. Never re-pin to make it pass.
5. **Commit** the vendored files and the manifest together, in one commit naming the old and new tags. The pull request lists the NEWS entries that matter to this repository and what the checks showed.
