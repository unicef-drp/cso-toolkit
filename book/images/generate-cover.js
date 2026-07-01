/* ------------------------------------------------------------------ *
 *  generate-cover.js
 *  Generates an SVG of "The CSO Toolkit Handbook" cover — option A
 *  (UNICEF-cyan, official). Pure vector, no external assets.
 *
 *  Design: a full-frame faint "code rain" of the toolkit's own
 *  function names (the contract, written down) over a UNICEF-cyan
 *  gradient, with a large title block and R / Python / Stata chips —
 *  sized to fill the frame like the DW-Handbook cover.
 *
 *  Usage:
 *     node generate-cover.js                 -> writes cover-A.svg
 *     node generate-cover.js out.svg         -> writes out.svg
 *
 *  Coordinates live in a 640 x 853.33 design space (exact 3:4, matched
 *  to the DW-Handbook cover at 1200 x 1600); outputScale sets the
 *  rendered pixel size. Rasterise to PNG at 1200 x 1600 with cairosvg.
 *  The earlier minimal cover is preserved as cover-A-min.{svg,png};
 *  the A4-proportioned cover as cover-A-alt.{svg,png}.
 * ------------------------------------------------------------------ */

const CONFIG = {
  width: 640,
  height: (640 * 4) / 3,          // exact 3:4 (width*4/3); rendered at 1200 x 1600
  outputScale: 1.875,             // -> 1200 x 1600 (DW-Handbook cover size)
  cyan: '#1CABE2',
  cyanDark: '#1488bb',
  ink: '#ffffff',
  fontSans: "'Helvetica Neue', Helvetica, Arial, sans-serif",
  fontMono: "'SFMono-Regular', Consolas, 'Liberation Mono', Menlo, monospace",

  org: 'UNICEF',
  unit: 'CHIEF STATISTICIAN OFFICE',
  flag: 'HANDBOOK',
  kicker: 'REPRODUCIBLE ANALYTICS',
  title: ['The CSO', 'Toolkit', 'Handbook'],
  subtitle: [
    'One contract, three languages —',
    'reproducible analytics in R,',
    'Python, and Stata.',
  ],
  chips: ['R', 'Python', 'Stata'],
  version: 'v0.6.0',
};

// the toolkit's own vocabulary — the contract, written down
const FUNCS = [
  'dw_save', 'dw_use', 'dw_compare', 'dw_merge', 'dw_isid', 'dw_verify_z', 'dw_stage', 'dw_root',
  'dw_api_fetch', 'dw_api_cached', 'dw_api_inventory', 'aggregate_data_v2', 'apply_time_window',
  'generate_agg_footnote', 'dw_nestweight', 'dw_pop', 'dw_regions', 'cso_toolkit_check',
  'cso_toolkit_diff', 'cso_toolkit_pull', 'create_profile', 'create_sector_script',
  'review_profile', 'test_scripts',
];

// approximate pill width (px) for a chip label at 15px/600 Helvetica
function chipWidth(label) {
  return Math.round(label.length * 9.6) + 34;
}

function esc(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

// full-frame faint code-rain of the toolkit function names
function codeRain(W, H, ink, mono) {
  const rows = [];
  const rowH = 30, fs = 12.5, sep = '   ';
  let pi = 0;
  for (let y = 26; y < H - 6; y += rowH) {
    let line = '';
    while (line.length < 135) { line += FUNCS[pi % FUNCS.length] + sep; pi++; }
    const xoff = 14 - ((y * 7) % 40);
    rows.push(
      `<text x="${xoff}" y="${y}" font-family="${mono}" font-size="${fs}" ` +
      `letter-spacing="0.4" fill="${ink}" opacity="0.085">${esc(line.trim())}</text>`
    );
  }
  return rows.join('\n    ');
}

function buildSVG(cfg = CONFIG) {
  const { width: W, height: H, outputScale: S, cyan, cyanDark, ink, fontSans, fontMono } = cfg;

  // --- chips: lay them out left-to-right ---
  const chipY = 768, chipH = 36, chipGap = 11;
  let cx = 52;
  const chipEls = cfg.chips.map((label) => {
    const w = chipWidth(label);
    const el =
      `<rect x="${cx}" y="${chipY}" width="${w}" height="${chipH}" rx="${chipH / 2}" ` +
      `fill="none" stroke="${ink}" stroke-opacity="0.8" stroke-width="1.3"/>` +
      `<text x="${cx + w / 2}" y="${chipY + 24}" text-anchor="middle" ` +
      `font-size="15" font-weight="600" fill="${ink}">${esc(label)}</text>`;
    cx += w + chipGap;
    return el;
  }).join('\n    ');

  // --- title: 3 lines, large, 84px leading ---
  const titleBaselines = [440, 524, 608];
  const titleEls = cfg.title.map((line, i) =>
    `<text x="50" y="${titleBaselines[i]}">${esc(line)}</text>`
  ).join('\n    ');

  // --- subtitle: pre-wrapped lines, 28px leading ---
  const subBaselines = [666, 694, 722];
  const subEls = cfg.subtitle.map((line, i) =>
    `<text x="52" y="${subBaselines[i]}">${esc(line)}</text>`
  ).join('\n    ');

  return `<svg xmlns="http://www.w3.org/2000/svg" width="${Math.round(W * S)}" height="${Math.round(H * S)}" viewBox="0 0 ${W} ${H}" font-family="${fontSans}">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="${cyan}"/>
      <stop offset="1" stop-color="${cyanDark}"/>
    </linearGradient>
  </defs>
  <rect width="${W}" height="${H}" fill="url(#bg)"/>

  <!-- full-frame code-rain: the toolkit's own function names -->
  <g>
    ${codeRain(W, H, ink, fontMono)}
  </g>

  <!-- masthead -->
  <text x="50" y="82" font-size="27" font-weight="800" letter-spacing="5.2" fill="${ink}">${esc(cfg.org)}</text>
  <text x="50" y="104" font-size="11" font-weight="600" letter-spacing="2.0" fill="${ink}" opacity="0.92">${esc(cfg.unit)}</text>
  <text x="590" y="82" text-anchor="end" font-size="11" font-weight="700" letter-spacing="2.5" fill="${ink}" opacity="0.9">${esc(cfg.flag)}</text>

  <!-- kicker -->
  <text x="50" y="360" font-size="12.5" font-weight="700" letter-spacing="3.8" fill="${ink}" opacity="0.9">${esc(cfg.kicker)}</text>
  <line x1="50" y1="372" x2="120" y2="372" stroke="${ink}" stroke-opacity="0.7" stroke-width="2"/>

  <!-- title -->
  <g fill="${ink}" font-size="84" font-weight="800" letter-spacing="-2.1">
    ${titleEls}
  </g>

  <!-- subtitle -->
  <g fill="${ink}" font-size="18" font-weight="400" opacity="0.96">
    ${subEls}
  </g>

  <!-- footer -->
  <line x1="50" y1="752" x2="590" y2="752" stroke="${ink}" stroke-opacity="0.45" stroke-width="1"/>
  <g>
    ${chipEls}
  </g>
  <text x="590" y="812" text-anchor="end" font-size="14" font-weight="700" fill="${ink}">${esc(cfg.version)}</text>
</svg>`;
}

// --- Node entry point (no-op when imported elsewhere) ---
if (typeof module !== 'undefined' && require.main === module) {
  const fs = require('fs');
  const out = process.argv[2] || 'cover-A.svg';
  fs.writeFileSync(out, buildSVG(CONFIG));
  console.log('Wrote ' + out);
}

if (typeof module !== 'undefined') module.exports = { buildSVG, CONFIG };
