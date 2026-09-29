#!/usr/bin/env python3
"""Extract the user's SVG artwork, without changing paths or gradients.

Writes standalone web symbols and rounded app-icon canvases. The supplied
design-tool runtime is not needed or shipped. PNG/ICNS export is a separate
rendering step so no browser executable or local path enters the assets.
"""
from pathlib import Path
import math
import re

ROOT = Path(__file__).resolve().parents[2]
BRAND = ROOT / "assets/brand"


def write_if_changed(path, text):
    if not path.exists() or path.read_text() != text:
        path.write_text(text)


def main():
    source = (BRAND / "source/Pullock Logo Varianten.dc.html").read_text()
    definitions = re.search(r"<defs>(.*?)</defs>", source, re.S).group(1).strip()
    pieces = {}
    for variant in "abcdef":
        match = re.search(rf'<div id="1{variant}".*?<svg\b[^>]*>(.*?)</svg>', source, re.S)
        if not match:
            raise ValueError(f"Missing supplied variant 1{variant}")
        pieces[variant] = match.group(1).strip()
    if pieces["a"] != pieces["c"] or pieces["a"] != pieces["e"] or pieces["b"] != pieces["d"] or pieces["b"] != pieces["f"]:
        raise ValueError("Source variants differ in geometry; review before exporting")
    destination = BRAND / "svg"
    destination.mkdir(parents=True, exist_ok=True)
    previews = []
    for theme, variant, colors in [("dark", "a", ("#2a2a2a", "#0e0e0e")), ("light", "b", ("#ffffff", "#e6e6e6"))]:
        mark = pieces[variant]
        write_if_changed(destination / f"pullock-symbol-{theme}.svg",
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 240 240" role="img" aria-label="Pullock">\n'
            f'<defs>{definitions}</defs>\n{mark}\n</svg>\n')
        # Match the original 512px CSS linear-gradient(160deg, ...) exactly.
        ux = math.sin(math.radians(160)); uy = -math.cos(math.radians(160))
        half = (abs(512 * ux) + abs(512 * uy)) / 2
        gradient = (f'<linearGradient id="canvas" gradientUnits="userSpaceOnUse" '
                    f'x1="{256-ux*half:.6f}" y1="{256-uy*half:.6f}" x2="{256+ux*half:.6f}" y2="{256+uy*half:.6f}">'
                    f'<stop stop-color="{colors[0]}"/><stop offset="1" stop-color="{colors[1]}"/></linearGradient>')
        write_if_changed(destination / f"pullock-app-{theme}.svg",
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" role="img" aria-label="Pullock">\n'
            f'<defs>{definitions}{gradient}</defs>\n'
            '<rect width="512" height="512" rx="114" fill="url(#canvas)"/>\n'
            f'<svg x="56" y="56" width="400" height="400" viewBox="0 0 240 240">{mark}</svg>\n</svg>\n')
        previews.append(f'<figure><img width="512" height="512" src="svg/pullock-app-{theme}.svg" alt="Pullock {theme}"><figcaption>App icon · {theme}</figcaption></figure>')
    write_if_changed(BRAND / "preview.html", '<!doctype html><html lang="en"><meta charset="utf-8"><title>Pullock brand assets</title>'
        '<style>body{background:#d9d9d9;color:#141414;font:16px system-ui;margin:40px}main{display:flex;gap:40px;flex-wrap:wrap}figure{margin:0}figcaption{margin-top:16px}h1{font-size:32px}</style>'
        '<h1>Pull the key. Lock the Device.</h1><main>' + ''.join(previews) + '</main></html>\n')


if __name__ == "__main__":
    main()
