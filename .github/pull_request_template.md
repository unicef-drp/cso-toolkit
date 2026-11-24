## What and why

<!-- What changed, which issue it closes, and why this approach. -->

## How it was checked

<!-- The commands you ran and what they reported. Tick what applies. -->

- [ ] `sh tools/check` passes (version stamps, parity case files, handbook tables, certificate)
- [ ] Tests in every language the change touches (R, Python, Stata)
- [ ] **A bug fix:** the new test failed on the code before the fix. Quote the failure, or point to the commit where the test fails:

  ```
  ```

- [ ] A parity case, if the three languages must agree on this behaviour
- [ ] A new parity certificate (`sh tools/certify --record`), if `r/R`, `python/src`, `stata/` or `conformance/` changed
- [ ] The handbook chapter that owns the behaviour, and `sh tools/docs-tables` if a function was added, removed or ported
- [ ] A `NEWS.md` entry under `## Unreleased`

See the handbook chapter "Contributing".
