---
name: check
description: Run a cso-toolkit repository's local checks (tools/check.R), explain each failure and fix the routine ones. Use before a push or pull request, when the pre-push hook fails, or when someone asks whether the repository is clean.
---

# Run the local checks

Handbook: "Continuous integration and repository hygiene", <https://unicef-drp.github.io/cso-toolkit/handbook/chapters/45-ci-cd.html>.

1. **Run** from the repository root:
   ```sh
   Rscript --no-init-file tools/check.R          # every default check
   Rscript --no-init-file tools/check.R --list   # the check names
   Rscript --no-init-file tools/check.R --only tests
   ```
   Never `--vanilla` (it drops `.Renviron` and the user library). On Windows, Rscript may not be on the PATH: use the full path under `C:/Program Files/R/`.
2. **Read each FAIL line.** Each failure prints what failed, why it matters and how to fix it. Report them to the person in that order.
3. **Fix the routine ones**, each as its own commit, staged by path:

   | Check | Routine fix |
   |---|---|
   | `tracked-data` | `git rm --cached -- <path>` (the file stays on disk) and add the rule to `.gitignore`. In official statistics, an output folder entry is an embargo breach: tell the person before anything else. |
   | `large-files` | Move the file to the deposit, commit its sidecar instead, `git rm --cached -- <path>`. |
   | `sidecars` | Re-write the output with `dw_save()`; never edit a sidecar by hand. |
   | `vintage` | Report the mismatch between `00_functions/` and `.toolkit_manifest.yml`; do not edit either to make it pass. |
   | `tests` | Run the failing test alone and find the cause. Never change an expected value without the person's agreement. |

4. **Not routine, so stop and tell the person:**
   - **`secret-scan`:** treat the secret as compromised. The person rotates it first; removing it from history is their decision.
   - **`contract-audit`:** a direct read, write or HTTP call bypasses the `dw_*` wrappers. Propose the wrapper the message names. A `# cso-allow: <rule>` exception needs the person's agreement and a reason in the comment.
5. **Run the checks again** until they pass. Never push with `--no-verify` or `CHECK_SKIP=1` on your own; if the person decides to, the pull request must say why.
