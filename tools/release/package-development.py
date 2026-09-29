#!/usr/bin/env python3
"""Prepare a local review bundle. This command never creates a GitHub release."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parents[2]
EXCLUDED = {".build", ".swiftpm", ".local", "DerivedData", "xcuserdata", "__pycache__", ".DS_Store"}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_files():
    files = [ROOT / name for name in [".gitattributes", ".gitignore", "LICENSE", "PLAN.md", "README.md"]]
    for directory in [".github", "apps/macos", "packages", "tools", "docs"]:
        for path in (ROOT / directory).rglob("*"):
            relative = path.relative_to(ROOT)
            if any(part in EXCLUDED for part in relative.parts):
                continue
            if path.is_symlink():
                raise ValueError(f"Unexpected source symlink: {relative}")
            if path.is_file():
                if path.suffix in {".p12", ".mobileprovision", ".provisionprofile", ".pem", ".key"}:
                    raise ValueError(f"Signing material cannot enter a review bundle: {relative}")
                files.append(path)
    return sorted(files, key=lambda path: str(path.relative_to(ROOT)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--products", type=Path, required=True, help="Validated Xcode Release products directory")
    parser.add_argument("--output", type=Path, required=True, help="New output directory; existing directories are rejected")
    args = parser.parse_args()
    products, output = args.products.resolve(), args.output.absolute()
    if output.exists() or output.is_symlink():
        parser.error("Output already exists; choose a new directory")
    app = products / "PullockDevelopment.app"
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "app.pullock.development":
        parser.error("Only the explicitly labelled development app is accepted")
    version = info.get("CFBundleShortVersionString", "")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        parser.error("Unexpected version")
    subprocess.run(["python3", str(ROOT / "tools/validation/check_binaries.py"), str(products)], check=True)
    executable = app / "Contents/MacOS/PullockDevelopment"
    architectures = subprocess.check_output(["lipo", "-archs", str(executable)], text=True).strip()
    if architectures != "arm64":
        parser.error("Unexpected development architecture")
    files = source_files()
    sources = [{"path": str(path.relative_to(ROOT)), "sha256": digest(path)} for path in files]
    source_tree_digest = hashlib.sha256(json.dumps(sources, sort_keys=True).encode()).hexdigest()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="pullock-review-", dir=output.parent) as temporary:
        staging = Path(temporary) / "bundle"
        staging.mkdir()
        app_zip = staging / f"PullockDevelopment-{version}-macos-arm64.zip"
        subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(app_zip)], check=True)
        extracted = Path(temporary) / "extracted"
        subprocess.run(["ditto", "-x", "-k", str(app_zip), str(extracted)], check=True)
        subprocess.run(["codesign", "--verify", "--strict", str(extracted / app.name)], check=True, capture_output=True)
        source_zip = staging / f"PullockDevelopment-{version}-source.zip"
        with zipfile.ZipFile(source_zip, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for path in files:
                entry = zipfile.ZipInfo(f"pullock-source/{path.relative_to(ROOT)}", date_time=(2026, 1, 1, 0, 0, 0))
                entry.compress_type = zipfile.ZIP_DEFLATED
                entry.external_attr = (0o100755 if os.access(path, os.X_OK) else 0o100644) << 16
                archive.writestr(entry, path.read_bytes())
        manifest = {
            "schemaVersion": 1, "version": version, "buildKind": "development",
            "protection": "unavailable", "realActions": False,
            "distributionQualification": "not_qualified",
            "minimumMacOS": info.get("LSMinimumSystemVersion"), "architecture": architectures,
            "sourceTreeSHA256": source_tree_digest, "sources": sources,
            "artifacts": [{"name": path.name, "sha256": digest(path), "bytes": path.stat().st_size}
                          for path in [app_zip, source_zip]],
        }
        (staging / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        (staging / "READ-ME-FIRST.txt").write_text(
            "Pullock Development — LOCAL REVIEW ONLY — NO PROTECTION\n\n"
            "This build shows passive USB diagnostics and labelled simulations.\n"
            "It cannot lock or shut down your Mac and installs no services.\n"
            "It is ad-hoc signed, not Developer-ID signed or notarized.\n"
            "Do not disable Gatekeeper to distribute it.\n"
            "This bundle is not the finished security release.\n\n"
            "Sources and the repository's GPL-v3 license are in the source archive.\n"
            "See docs/release/README.md and docs/test-reports/M3.md there.\n"
        )
        artifacts = sorted(staging.iterdir())
        (staging / "SHA256SUMS").write_text("".join(f"{digest(path)}  {path.name}\n" for path in artifacts))
        # Renaming a fully prepared directory avoids partial output on failure.
        staging.rename(output)
    print(f"Prepared local development review bundle: {output}")
    print("No tag or GitHub release was created. Distribution remains unqualified.")


if __name__ == "__main__":
    main()
