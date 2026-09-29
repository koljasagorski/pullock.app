#!/usr/bin/env python3
"""Render the supplied vectors into macOS icons and website assets.

Requires macOS with Xcode Swift and Pillow. Paths/gradients stay in the SVG
masters; raster sizes are generated from 1024px masters using Lanczos sampling.
"""
from pathlib import Path
import json
import io
import shutil
import subprocess
import tempfile
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
BRAND = ROOT / "assets/brand"
CATALOG = ROOT / "apps/macos/PullockApp/Assets.xcassets"
WEB = ROOT / "apps/web/public"


def write(path, data):
    if not path.exists() or path.read_bytes() != data:
        path.write_bytes(data)


def save_image(path, image, format="PNG", **options):
    buffer = io.BytesIO()
    image.save(buffer, format=format, **options)
    write(path, buffer.getvalue())


def main():
    subprocess.run(["python3", str(ROOT / "tools/brand/export.py")], check=True)
    output = BRAND / "png"
    output.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="pullock-vector-render.") as temporary:
        for theme in ["dark", "light"]:
            for kind in ["app", "symbol"]:
                filename = f"pullock-{kind}-{theme}-1024.png"
                rendered = Path(temporary) / filename
                subprocess.run(["swift", str(ROOT / "tools/brand/render.swift"),
                    str(BRAND / f"svg/pullock-{kind}-{theme}.svg"), str(rendered), "1024"], check=True)
                write(output / filename, rendered.read_bytes())
    iconset = CATALOG / "AppIcon.appiconset"
    iconset.mkdir(parents=True, exist_ok=True)
    write(CATALOG / "Contents.json", (json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n").encode())
    images = []
    icon = Image.open(output / "pullock-app-dark-1024.png").convert("RGBA")
    assert icon.size == (1024, 1024) and icon.getpixel((0, 0))[3] == 0
    assert icon.getpixel((512, 512))[3] == 255
    for size in [16, 32, 128, 256, 512]:
        for scale in [1, 2]:
            filename = f"icon_{size}x{size}" + ("@2x" if scale == 2 else "") + ".png"
            save_image(iconset / filename, icon.resize((size * scale, size * scale), Image.Resampling.LANCZOS))
            images.append({"filename": filename, "idiom": "mac", "scale": f"{scale}x", "size": f"{size}x{size}"})
    write(iconset / "Contents.json", (json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n").encode())
    symbolset = CATALOG / "PullockSymbol.imageset"
    symbolset.mkdir(exist_ok=True)
    symbols = []
    for theme in ["light", "dark"]:
        filename = f"pullock-symbol-{theme}.png"
        save_image(symbolset / filename, Image.open(output / f"pullock-symbol-{theme}-1024.png").resize((256, 256), Image.Resampling.LANCZOS))
        entry = {"filename": filename, "idiom": "mac", "scale": "2x"}
        if theme == "dark": entry["appearances"] = [{"appearance": "luminosity", "value": "dark"}]
        symbols.append(entry)
    write(symbolset / "Contents.json", (json.dumps({"images": symbols, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n").encode())
    with tempfile.TemporaryDirectory(prefix="pullock-iconset.") as temporary:
        standalone = Path(temporary) / "Pullock.iconset"
        standalone.mkdir()
        for entry in images: shutil.copyfile(iconset / entry["filename"], standalone / entry["filename"])
        generated = Path(temporary) / "Pullock.icns"
        subprocess.run(["iconutil", "-c", "icns", str(standalone), "-o", str(generated)], check=True)
        write(BRAND / "Pullock.icns", generated.read_bytes())
    (WEB / "brand").mkdir(parents=True, exist_ok=True)
    for path in (BRAND / "svg").glob("*.svg"): write(WEB / "brand" / path.name, path.read_bytes())
    write(WEB / "favicon.svg", (BRAND / "svg/pullock-app-dark.svg").read_bytes())
    save_image(WEB / "favicon.ico", icon, format="ICO", sizes=[(16, 16), (32, 32), (48, 48)])
    for size in [192, 512]: save_image(WEB / f"icon-{size}.png", icon.resize((size, size), Image.Resampling.LANCZOS))
    save_image(WEB / "apple-touch-icon.png", icon.resize((180, 180), Image.Resampling.LANCZOS))
    print("Exported both logo themes, macOS AppIcon/PullockSymbol, ICNS and website favicons.")


if __name__ == "__main__":
    main()
