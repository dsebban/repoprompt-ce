// Renders public/icon.svg to the PNG icons iOS and the web manifest need.
//   node scripts/make-icons.mjs        (from web/; uses Playwright's Chromium)
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const pub = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../public");
const svg = readFileSync(path.join(pub, "icon.svg"), "utf8");
// iOS applies its own rounded mask, so the touch icon is a full-bleed square.
const square = svg.replace(/rx="\d+"/, 'rx="0"');
// Maskable: full-bleed background, glyph inside the 80% safe zone.
const maskable = square.replace(/<path/, '<g transform="translate(51.2 51.2) scale(0.8)"><path').replace(/<\/svg>/, "</g></svg>");

const targets = [
  ["apple-touch-icon.png", 180, square],
  ["icon-192.png", 192, svg],
  ["icon-512.png", 512, svg],
  ["icon-maskable-512.png", 512, maskable],
];

const browser = await chromium.launch({ executablePath: process.env.CHROMIUM_PATH || undefined });
for (const [name, size, markup] of targets) {
  const page = await browser.newPage({ viewport: { width: size, height: size } });
  await page.setContent(`<style>html,body{margin:0;background:transparent}svg{display:block;width:${size}px;height:${size}px}</style>${markup}`);
  await page.screenshot({ path: path.join(pub, name), omitBackground: true });
  await page.close();
  console.log(`wrote ${name}`);
}
await browser.close();
