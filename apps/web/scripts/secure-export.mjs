import { readdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { createHash } from "node:crypto";

// GitHub Pages cannot set arbitrary response headers. Hash the fixed inline
// hydration scripts in each exported HTML page instead of enabling unsafe-inline.
async function secure(directory) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) { await secure(path); continue; }
    if (!entry.name.endsWith(".html")) continue;
    const html = await readFile(path, "utf8");
    if (html.includes('http-equiv="Content-Security-Policy"')) throw new Error(`Duplicate CSP: ${path}`);
    const hashes = new Set();
    for (const match of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)) {
      if (!/\bsrc\s*=/.test(match[1]) && match[2]) {
        hashes.add(`'sha256-${createHash("sha256").update(match[2]).digest("base64")}'`);
      }
    }
    const policy = ["default-src 'self'", `script-src 'self' ${[...hashes].join(" ")}`,
      "style-src 'self' 'unsafe-inline'", "img-src 'self' data:", "font-src 'self'",
      "connect-src 'self'", "object-src 'none'", "base-uri 'none'", "form-action 'none'"].join("; ");
    await writeFile(path, html.replace(/<head>/i, `<head><meta http-equiv="Content-Security-Policy" content="${policy}">`));
  }
}
await secure("out");
await writeFile("out/.nojekyll", "");
console.log("Static export secured with per-page script hashes.");
