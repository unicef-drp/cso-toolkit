<!-- vendored from datalib-unicef config/grammar.md @ v0.7.0 (§ Shared semantics, item 6) — do not hand-edit; refresh via _manifest.yml -->

| Contract error | Stata | R class | Python |
|---|---|---|---|
| invalid input | 198 | `datalib_error_input` | `InvalidArgumentError` |
| not found (country/survey/vintage/file) | 198/601 | `datalib_error_input` | `NotFoundError` |
| config file missing | 601 | `datalib_error_config_missing` | `ConfigFileNotFound` |
| user block missing | 459 | `datalib_error_user_missing` | `UserBlockNotFound` |
| library root unset | 198 | `datalib_error_input` | `DatalibRootNotSet` |
