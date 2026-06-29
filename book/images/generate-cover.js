/* ------------------------------------------------------------------ *
 *  generate-cover.js
 *  Generates an SVG of "The CSO Toolkit Handbook" cover — option A
 *  (UNICEF-cyan, official). Pure vector, no external assets.
 *
 *  Usage:
 *     node generate-cover.js                 -> writes cover-A.svg
 *     node generate-cover.js out.svg         -> writes out.svg
 *
 *  Everything is driven by CONFIG below — edit text / colours / sizes
 *  there and re-run. Coordinates live in a 640 x 853.33 design space
 *  (3:4, matched to the DW-Handbook cover at 1200 x 1600); outputScale
 *  only changes the rendered pixel size. The earlier A4-proportioned
 *  cover is preserved as cover-A-alt.{svg,png} (1280 x 1810).
 * ------------------------------------------------------------------ */

const CONFIG = {
  width: 640,
  height: (640 * 4) / 3,          // exact 3:4 (width*4/3); rendered at 1200 x 1600 (DW-Handbook cover size)
  outputScale: 1.875,             // px multiplier on the root <svg> -> 1200 x 1600
  cyan: '#1CABE2',
  ink: '#ffffff',
  fontSans: "'Helvetica Neue', Helvetica, Arial, sans-serif",

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
  version: 'v0.5.1',
};

// approximate pill width (px) for a chip label at 13px/600 Helvetica
function chipWidth(label) {
  return Math.round(label.length * 8.2) + 28;
}

function esc(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

function buildSVG(cfg = CONFIG) {
  const { width: W, height: H, outputScale: S, cyan, ink, fontSans } = cfg;

  // --- chips: lay them out left-to-right with a 9px gap ---
  const chipY = 763, chipH = 32, chipGap = 9;
  let cx = 52;
  const chipEls = cfg.chips.map((label) => {
    const w = chipWidth(label);
    const el =
      `<rect x="${cx}" y="${chipY}" width="${w}" height="${chipH}" rx="${chipH / 2}" ` +
      `fill="none" stroke="${ink}" stroke-opacity="0.75"/>` +
      `<text x="${cx + w / 2}" y="${chipY + 21}" text-anchor="middle" ` +
      `font-size="13" font-weight="600" fill="${ink}">${esc(label)}</text>`;
    cx += w + chipGap;
    return el;
  }).join('\n    ');

  // --- title: 3 lines, 65px leading, bottom-anchored block ---
  const titleBaselines = [458, 523, 588];
  const titleEls = cfg.title.map((line, i) =>
    `<text x="52" y="${titleBaselines[i]}">${esc(line)}</text>`
  ).join('\n    ');

  // --- subtitle: pre-wrapped lines, 27px leading ---
  const subBaselines = [654, 681, 708];
  const subEls = cfg.subtitle.map((line, i) =>
    `<text x="52" y="${subBaselines[i]}">${esc(line)}</text>`
  ).join('\n    ');

  return `<svg xmlns="http://www.w3.org/2000/svg" width="${Math.round(W * S)}" height="${Math.round(H * S)}" viewBox="0 0 ${W} ${H}" font-family="${fontSans}">
  <rect width="${W}" height="${H}" fill="${cyan}"/>

  <!-- three translucent language bands -->
  <g fill="${ink}">
    <rect x="476" y="0" width="30" height="${H}" opacity="0.10"/>
    <rect x="520" y="0" width="30" height="${H}" opacity="0.14"/>
    <rect x="564" y="0" width="30" height="${H}" opacity="0.10"/>
  </g>

  <!-- masthead -->
  <text x="52" y="80" font-size="24" font-weight="800" letter-spacing="4.8" fill="${ink}">${esc(cfg.org)}</text>
  <text x="52" y="101" font-size="11" font-weight="600" letter-spacing="1.98" fill="${ink}" opacity="0.92">${esc(cfg.unit)}</text>
  <text x="588" y="80" text-anchor="end" font-size="11" font-weight="700" letter-spacing="2.42" fill="${ink}" opacity="0.9">${esc(cfg.flag)}</text>

  <!-- kicker -->
  <text x="52" y="390" font-size="12" font-weight="700" letter-spacing="3.6" fill="${ink}" opacity="0.85">${esc(cfg.kicker)}</text>

  <!-- title -->
  <g fill="${ink}" font-size="67" font-weight="800" letter-spacing="-1.675">
    ${titleEls}
  </g>

  <!-- subtitle -->
  <g fill="${ink}" font-size="18" font-weight="400" opacity="0.95">
    ${subEls}
  </g>

  <!-- footer -->
  <line x1="52" y1="745" x2="588" y2="745" stroke="${ink}" stroke-opacity="0.4" stroke-width="1"/>
  <g>
    ${chipEls}
  </g>
  <text x="588" y="784" text-anchor="end" font-size="13" font-weight="700" fill="${ink}">${esc(cfg.version)}</text>
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
