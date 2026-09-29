import { createServer } from "node:http";
import { readFile, stat } from "node:fs/promises";
import { resolve, extname, sep } from "node:path";
import { gzipSync } from "node:zlib";

const root = resolve("out");
const port = Number(process.env.PORT || 4173);
const base = process.env.NEXT_PUBLIC_BASE_PATH || "";
const mime = { ".html": "text/html; charset=utf-8", ".css": "text/css", ".js": "text/javascript", ".json": "application/json", ".txt": "text/plain", ".xml": "application/xml", ".svg": "image/svg+xml", ".png": "image/png", ".webp": "image/webp", ".ico": "image/x-icon", ".woff2": "font/woff2", ".woff": "font/woff" };
const server = createServer(async (req, res) => {
  try {
    const pathname = decodeURIComponent(new URL(req.url || "/", "http://localhost").pathname);
    if (base && pathname === base) { res.writeHead(308, { Location: `${base}/` }); res.end(); return; }
    if (base && !pathname.startsWith(`${base}/`)) { res.writeHead(404); res.end(); return; }
    let path = resolve(root, `.${pathname.slice(base.length)}`);
    if (path !== root && !path.startsWith(root + sep)) { res.writeHead(403); res.end(); return; }
    let code = 200;
    try { if ((await stat(path)).isDirectory()) path = resolve(path, "index.html"); await stat(path); }
    catch { path = resolve(root, "404.html"); code = 404; }
    let content = await readFile(path);
    const compressed = /\bgzip\b/.test(req.headers["accept-encoding"] || "") && /\.(html|css|js|json|txt|xml|svg)$/.test(path);
    if (compressed) content = gzipSync(content);
    res.writeHead(code, { "Content-Type": mime[extname(path)] || "application/octet-stream", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", "Vary": "Accept-Encoding", ...(compressed ? { "Content-Encoding": "gzip" } : {}) });
    res.end(req.method === "HEAD" ? undefined : content);
  } catch { res.writeHead(400); res.end(); }
});
server.listen(port, "127.0.0.1", () => console.log(`Pullock preview: http://127.0.0.1:${port}${base}/`));
for (const signal of ["SIGINT", "SIGTERM"]) process.on(signal, () => server.close(() => process.exit(0)));
