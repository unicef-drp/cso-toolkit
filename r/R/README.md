# r/R/ — R helpers

Three files. Vendored, not installed.

- [`dw_io.R`](dw_io.R) — uniform read / write / compare / merge / isid helpers.
  Auto-dispatch by extension. Writes `.provenance.json` sidecars.
- [`dw_api.R`](dw_api.R) — cached API fetcher with reviewer-mode no-API
  enforcement.
- [`cso_toolkit_sync.R`](cso_toolkit_sync.R) — version-drift detection +
  pull / diff against the upstream tag pinned in your consumer's
  `.toolkit_manifest.yml`.

## How a consumer vendors these

In the consumer repo's `00_functions/`:

```r
source(file.path(rootFolder, "00_functions", "dw_io.R"))
source(file.path(rootFolder, "00_functions", "dw_api.R"))
source(file.path(rootFolder, "00_functions", "cso_toolkit_sync.R"))
```

The consumer pins a version in `00_functions/.toolkit_manifest.yml`:

```yaml
source: "unicef-drp/cso-toolkit"
pulled_version: "v0.1.0-rc1"
pulled_date: "2026-05-24"
```

`cso_toolkit_check()` reads the manifest, asks the GitHub API for the latest
tag, and warns if the consumer is behind.
