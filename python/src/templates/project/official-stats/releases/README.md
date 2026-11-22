# releases/

The release record: what was deposited for each published vintage.
**Commit it in the release pull request, after the publication date and
never before**: its hashes describe figures that are embargoed until then.

One folder per vintage, `releases/<vintage>/`, holding:

- `output_manifest.csv`, one row per deposited file:

  | Column | Content |
  |---|---|
  | `file` | file name |
  | `sha256` | SHA-256 of the deposited bytes |
  | `bytes` | size |
  | `deposited_at` | ISO-8601 time of the deposit |
  | `deposit_path` | path relative to the deposit root, e.g. `01_dw_prep/013_wrkdata/ed/dw_ed.csv` |

- copies of the deposited files' `.provenance.json` sidecars.

`.gitignore` re-includes only these files (and `README.md`, `.gitkeep`)
under `releases/`; a data file copied here by mistake stays ignored.
