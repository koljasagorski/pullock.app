import { chromium } from "@playwright/test";
import { readFile } from "node:fs/promises";

// Deterministic browser export of the existing vector identity, not a new logo.
const font = (await readFile("node_modules/@fontsource/poppins/files/poppins-latin-500-normal.woff2")).toString("base64");
const icon = (await readFile("public/brand/pullock-app-dark.svg")).toString("base64");
const browser = await chromium.launch();
try {
  const page = await browser.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 1 });
  await page.setContent(`<html><head><style>@font-face{font-family:Poppins;src:url(data:font/woff2;base64,${font})}*{box-sizing:border-box}body{margin:0;background:#f6f6f5;color:#19191b;font-family:Poppins;display:flex;align-items:center;justify-content:space-between;gap:50px;width:1200px;height:630px;padding:70px}h1{font-size:57px;letter-spacing:-3px;line-height:1.2;font-weight:500;margin:22px 0}p{font-size:24px;margin:0}.note{font-size:17px;color:#59595f;margin-top:24px}img{width:300px;height:300px}</style></head><body><div><p>Pullock</p><h1>Pull the key.<br>Lock the Device.</h1><p class="note">A USB connection killswitch for macOS.<br>In development.</p></div><img src="data:image/svg+xml;base64,${icon}" alt=""></body></html>`);
  await page.evaluate(() => document.fonts.ready);
  await page.screenshot({ path: "public/brand/social.png" });
} finally { await browser.close(); }
