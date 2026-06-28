# Handbook cover

`cover-A.png` is the cover of *The CSO Toolkit Handbook*, wired into the book via
`cover-image: images/cover-A.png` in [`../_quarto.yml`](../_quarto.yml).

| File | Role |
|---|---|
| `cover-A.svg` | Vector source. |
| `cover-A.png` | Rendered raster used by Quarto (HTML cover). |
| `generate-cover.js` | Regenerates both from the title / subtitle / version. |

Regenerate after editing the title, subtitle, or version chip:

```sh
node generate-cover.js
```

Keep the version chip in step with the release tag (it currently reads
`v0.5.0`). To use a different cover, replace `cover-A.png` (portrait) or point
`cover-image` at another file.
