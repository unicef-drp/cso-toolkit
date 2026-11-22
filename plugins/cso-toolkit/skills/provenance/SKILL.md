---
name: provenance
description: Add a data input to a cso-toolkit repository with its provenance, or explain a provenance problem (a hash mismatch, a missing sidecar, an output that did not reproduce). Use when someone adds, replaces or updates an input file, or asks why a sidecar or input check fails.
---

# Inputs and provenance

The rules: data never enter git; the provenance sidecars that say exactly which bytes each result came from always do. Handbook: "Continuous integration and repository hygiene" (<https://unicef-drp.github.io/cso-toolkit/handbook/chapters/45-ci-cd.html>), the IO chapter (<https://unicef-drp.github.io/cso-toolkit/handbook/chapters/31-io.html>) and Appendix B (the sidecar schema).

**Never print rows of the data** while doing any of this: what you read is sent to the AI service. Names, sizes, hashes and counts are fine.

## Adding an input

1. **Where the file lives.** The canonical copy is in the deposit (Teams and its Z: mirror, the microdata archive, Gitea LFS), not in git. The local copy goes in the repository's gitignored inputs folder (`data/` or `inputs/`), or stays outside the repository.
2. **Check it stays out of git:** `git check-ignore -v <file>` must name a rule. If it prints nothing, stop and fix the `.gitignore` first.
3. **Record it.**
   - Inputs that mirror a deposit folder: read them through `dw_fetch_inputs(local_root, rel_dir, pattern)` (R or Python). It copies and SHA-256-verifies deposit files and returns the input manifest.
   - Otherwise: add a row to the folder's `input_manifest.csv` (file, sha256, bytes, source, retrieved date), using the repository's own convention if its README describes one.
4. **Carry it into the outputs.** Pass the manifest to every `dw_save()` that uses the input: `metadata = list(inputs = manifest[, c("file", "sha256", "origin")])` in R, `metadata={"inputs": manifest[["file", "sha256", "origin"]]}` in Python.
5. **Commit** the manifest row and the code that reads the input together, staged by path. Never the data file.

## Explaining a problem

- **`sidecars` check fails:** the sidecar is not valid JSON, lacks a core key, or has no 64-hex `sha256`. Re-write the output with `dw_save()`; never edit a sidecar by hand.
- **Hash mismatch on an input:** the local file is not the deposited one. Do not update the hash to match. Ask the person which copy is right; `dw_check_deposit()` shows where the copies differ.
- **Did a rerun reproduce?** Read the previous sidecar with `dw_read_provenance()` before the rerun, then `dw_provenance_diff(previous, path)`:
  - `reproduced`: same inputs, byte-identical output;
  - `inputs_changed`: report the added, removed and changed inputs;
  - `output_changed`: same inputs, different output; only code or environment can explain it, so find which;
  - `first_run`, `no_input_record`: say so.
  Then `dw_compare(..., diagnose = TRUE)` record by record if the person wants detail.
