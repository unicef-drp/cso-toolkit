---
name: review
description: Review a cso-toolkit pipeline or paper in reviewer mode, reproducing its outputs in a sandbox and comparing them with the canonical ones, then write the review note. Use when someone asks to review, reproduce, validate or sign off outputs, a deposit or a pull request that changes results.
---

# Review in reviewer mode

Handbook: "Roles and the mode contract" (<https://unicef-drp.github.io/cso-toolkit/handbook/chapters/21-roles-and-modes.html>) and the IO chapter's comparison helpers (<https://unicef-drp.github.io/cso-toolkit/handbook/chapters/31-io.html>).

A reviewer reads the canonical deposit, writes only to its own sandbox and calls no live API; the toolkit refuses canonical writes and API calls in reviewer mode. A review never changes the canonical outputs, and it never uses `takeover = TRUE`.

1. **Confirm the mode.** After sourcing the profile, `dw_mode` must be `reviewer`. If it is `producer`, stop and ask the person to switch it in their `user_config.yml`; do not edit it yourself.
2. **Pin what is reviewed:** the branch or pull request and its head commit, and the toolkit version (`dw_toolkit_version()`).
3. **Reproduce.** Run the pipeline or the scripts under review as the README says. Outputs go to the sandbox.
4. **Compare, for each output:**
   - `dw_provenance_diff(previous, current)` where sidecars exist: `reproduced`, `inputs_changed` or `output_changed`;
   - `dw_compare(current, reference, by = <key>, value_cols = ..., tol = ...)` against the canonical file: the rows added, removed and changed.
   Use the key the producer's script declares (`isid`). Do not loosen `tol` to make a difference disappear.
5. **Run the local checks** (`Rscript --no-init-file tools/check.R`).
6. **Write the review note** where the repository keeps them (the pull request, or the folder its README names):
   - what was reviewed (commit, toolkit version, date, reviewer);
   - one line per output with its status;
   - for every difference, the records and size, and the explanation if known;
   - the check result;
   - a verdict: reproduced, reproduced with explained differences, or not reproduced.
   Quote numbers from the comparison reports, not from memory. For official statistics, the note stays inside the repository: no pre-release figure goes into a public issue or an external service.
