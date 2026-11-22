---
name: check
description: Run a cso-toolkit repository's local checks (sh tools/check), explain each failure, fix the routine ones, and record a passing run before a push. Use before a push or pull request, when the pre-push hook refuses a push, or when someone asks whether the repository is clean.
---

# Run the local checks

Handbook: "Continuous integration and repository hygiene", <https://unicef-drp.github.io/cso-toolkit/handbook/chapters/45-ci-cd.html>, section "Check records".

1. **Run** from the repository root:
   ```sh
   sh tools/check                 # every default check
   sh tools/check --list          # the check names
   sh tools/check --only tests    # one check, while fixing
   ```
   `tools/check` runs `Rscript --no-init-file tools/check.R` with R set up right (on Windows it starts R so it finds the user's `.Renviron` and library). Without the wrapper, use `Rscript --no-init-file tools/check.R`, never `--vanilla`.
2. **Read each FAIL line.** Each failure prints what failed, why it matters and how to fix it. Report them to the person in that order. A `[WARN] contract-audit` in a research project is advisory: report it, it does not fail the run.
3. **Fix the routine ones**, each as its own commit, staged by path:

   | Check | Routine fix |
   |---|---|
   | `tracked-data` | `git rm --cached -- <path>` (the file stays on disk) and add the rule to `.gitignore`. In official statistics, an output folder entry is an embargo breach: tell the person before anything else. |
   | `large-files` | Move the file to the deposit, commit its sidecar instead, `git rm --cached -- <path>`. |
   | `sidecars` | Re-write the output with `dw_save()`; never edit a sidecar by hand. |
   | `vintage` | Report the mismatch between `00_functions/` and `.toolkit_manifest.yml`; do not edit either to make it pass. To update the toolkit, use the `update-toolkit` skill. |
   | `tests` | Run the failing test alone and find the cause. Never change an expected value without the person's agreement. |

4. **Not routine, so stop and tell the person:**
   - **`secret-scan`:** treat the secret as compromised. The person rotates it first; removing it from history is their decision.
   - **`contract-audit`** (blocking): a direct read, write or HTTP call bypasses the `dw_*` wrappers. Propose the wrapper the message names. A `# cso-allow: <rule>` exception needs the person's agreement and a reason in the comment.
5. **Record before pushing.** When every check passes and everything is committed: `sh tools/check --record`. It commits `.checks/<content-hash>.json`; the pre-push hook refuses a push without it, and the pull request's `check-record` status checks it again. After merging `develop` into the branch, record again. Never write or edit a record by hand, and never push with `--no-verify` or `CHECK_SKIP=1` on your own; if the person decides to, the pull request must say why.
