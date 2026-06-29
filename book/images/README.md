# Handbook cover

`cover-A.png` is the cover of *The CSO Toolkit Handbook*, wired into the book via
`cover-image: images/cover-A.png` in [`../_quarto.yml`](../_quarto.yml).

| File | Role |
| --- | --- |
| `cover-A.svg` | Vector source — the canonical cover (3:4, **1200×1600**, sized to match the DW-Handbook cover). |
| `cover-A.png` | Raster export of `cover-A.svg` (the format Quarto embeds for the HTML cover). |
| `cover-A-alt.svg` / `cover-A-alt.png` | The earlier A4-proportioned cover (1280×1810), kept as an alternate. |
| `generate-cover.js` | Regenerates **`cover-A.svg`** (the 3:4 cover) from the title / subtitle / version config. |

Regenerate after editing the title, subtitle, or version chip:

```sh
node generate-cover.js          # writes cover-A.svg
```

`generate-cover.js` produces the **SVG only**. After regenerating, export
`cover-A.svg` → `cover-A.png` at **1200×1600** with any SVG→PNG tool (e.g.
`cairosvg`, `rsvg-convert`, or Inkscape) so the raster the book embeds stays in
sync. Keep the version chip (currently `v0.5.1`) in step with the release tag.
