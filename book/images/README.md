# Handbook cover

`cover-A.png` is the cover of *The CSO Toolkit Handbook*, wired into the book via
`cover-image: images/cover-A.png` in [`../_quarto.yml`](../_quarto.yml).

| File | Role |
| --- | --- |
| `cover-A.svg` | Vector source — the canonical cover. |
| `cover-A.png` | Raster export of `cover-A.svg` (the format Quarto embeds for the HTML cover). |
| `generate-cover.js` | Regenerates **`cover-A.svg`** from the title / subtitle / version config. |

Regenerate after editing the title, subtitle, or version chip:

```sh
node generate-cover.js          # writes cover-A.svg only
```

`generate-cover.js` produces the **SVG only**. After regenerating, export
`cover-A.svg` → `cover-A.png` (e.g. with `rsvg-convert`, Inkscape, or any
SVG→PNG tool) so the raster the book embeds stays in sync. Keep the version
chip (currently `v0.5.0`) in step with the release tag.
