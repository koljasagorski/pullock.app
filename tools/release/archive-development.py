#!/usr/bin/env python3
"""Build an Apple-signed local review archive; optionally try Developer ID export.

Never registers services, notarizes, installs, tags or publishes. Identities and
account information stay in a private output directory, never console output.
"""
import argparse
from pathlib import Path
import os
import plistlib
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path, help="New local directory, outside tracked source")
    parser.add_argument("--probe-binary", required=True, type=Path, help="Already validated development executable; signed but never executed")
    parser.add_argument("--export-developer-id", action="store_true", help="Allow Xcode automatic Developer ID provisioning using its configured account")
    args = parser.parse_args()
    output = args.output.absolute()
    if output.exists() or output.is_symlink():
        parser.error("Output must be a new directory")
    if not args.probe_binary.is_file():
        parser.error("Validated probe executable is missing")
    identities = subprocess.check_output(["security", "find-identity", "-v", "-p", "codesigning"], text=True)
    development = re.findall(r'\b([A-Fa-f0-9]{40})\s+"Apple Development:', identities)
    distribution = re.findall(r'\b([A-Fa-f0-9]{40})\s+"Developer ID Application:', identities)
    candidates = distribution or development
    if len(candidates) != 1:
        parser.error("Exactly one usable Apple signing identity is required; select the intended signing account in Xcode")
    identity = candidates[0]
    os.umask(0o077)
    output.mkdir(parents=True, mode=0o700)
    probe = output / "signing-probe"
    shutil.copyfile(args.probe_binary, probe)
    probe.chmod(0o700)
    subprocess.run(["codesign", "--force", "--sign", identity, "--identifier", "app.pullock.signing-probe",
                    "--options", "runtime", "--timestamp=none", str(probe)], check=True, capture_output=True)
    signature = subprocess.run(["codesign", "--display", "--verbose=4", str(probe)], check=True, capture_output=True, text=True)
    team = re.search(r"^TeamIdentifier=([A-Z0-9]{10})$", signature.stderr, re.MULTILINE)
    if not team:
        parser.error("The selected identity did not produce an Apple team identifier")
    archive = output / "PullockDevelopment.xcarchive"
    command = ["xcodebuild", "-quiet", "-project", str(ROOT / "apps/macos/Pullock.xcodeproj"),
        "-scheme", "PullockDevelopment", "-configuration", "Release", "-destination", "generic/platform=macOS",
        "-derivedDataPath", str(output / "DerivedData"), "-archivePath", str(archive),
        "CODE_SIGN_STYLE=Manual", f"CODE_SIGN_IDENTITY={identity}", f"DEVELOPMENT_TEAM={team[1]}", "archive"]
    with (output / "archive.log").open("w") as log:
        built = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
    if built.returncode:
        raise SystemExit("Archive build failed; inspect the private archive.log locally")
    app = archive / "Products/Applications/PullockDevelopment.app"
    subprocess.run(["codesign", "--verify", "--strict", "--deep", str(app)], check=True, capture_output=True)
    print(f"Apple-signed local review archive: {archive}")
    print("Development build. Automatic protection and distribution are not qualified.")
    if not args.export_developer_id:
        return
    options = output / "ExportOptions.plist"
    options.write_bytes(plistlib.dumps({"method": "developer-id", "signingStyle": "automatic", "teamID": team[1],
        "destination": "export", "stripSwiftSymbols": True}))
    with (output / "export.log").open("w") as log:
        exported = subprocess.run(["xcodebuild", "-exportArchive", "-archivePath", str(archive),
            "-exportOptionsPlist", str(options), "-exportPath", str(output / "Export"), "-allowProvisioningUpdates"],
            stdout=log, stderr=subprocess.STDOUT)
    if exported.returncode:
        text = (output / "export.log").read_text()
        if "No Accounts" in text:
            raise SystemExit("Developer ID export blocked: xcodebuild reports 'No Accounts'. If Xcode is already signed in, check the selected team and try this archive in Xcode Organizer; this error alone does not establish that the GUI is signed out.")
        if 'No signing certificate "Developer ID Application" found' in text:
            raise SystemExit("Developer ID export blocked: configure Developer ID Application in Xcode's certificate manager")
        raise SystemExit("Developer ID export failed; inspect the private export.log locally")
    print(f"Developer ID export: {output / 'Export'}")
    print("No notarization or publication was performed.")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError:
        # Subprocess exception repr includes identity/team command arguments.
        raise SystemExit("A local signing or signature verification command failed. No archive was published.") from None
