# data/provenance/

Sidecars of inputs kept outside the repository. Each sits at a path that
mirrors where its file lives, so a sidecar for
`S:\datalib-edu\KEN\2022\hh.dta` is committed as
`data/provenance/S/datalib-edu/KEN/2022/hh.dta.provenance.json`, and one for
`../_pisa-data/2025/student.sav` as
`data/provenance/_pisa-data/2025/student.sav.provenance.json`.

Only `*.provenance.json`, `README.md` and `.gitkeep` files are tracked
here; anything else is git-ignored.
