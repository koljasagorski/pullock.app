"""Check development executables without opening a UI or using real system actions."""
import json
import hashlib
from pathlib import Path
import plistlib
import subprocess
import sys


products = Path(sys.argv[1])
binaries = {
    "app": products / "PullockDevelopment.app/Contents/MacOS/PullockDevelopment",
    "sessionAgent": products / "PullockSessionAgent",
    "daemon": products / "PullockDaemon",
}
forbidden = {
    "_SACLockScreenImmediate",
    "_IOCreatePlugInInterfaceForService", "_posix_spawn", "_posix_spawnp",
    "_reboot", "_system", "_execve", "_SMJobBless",
}
for component, binary in binaries.items():
    output = subprocess.run([str(binary), "--self-check"], check=True, capture_output=True, text=True, timeout=15)
    report = json.loads(output.stdout)
    assert report["component"] == component
    assert report["realActions"] == 0
    assert report["protocolVersion"] == 3
    if component == "app":
        assert report["simulationScenarios"] == 6
    else:
        assert report["listenerStarted"] is False
    if component == "daemon":
        assert report["status"] == "error"
    if component == "sessionAgent":
        assert report["lockQualified"] is False
    symbols = subprocess.check_output(["nm", "-u", str(binary)], text=True)
    imports = {line.split()[-1] for line in symbols.splitlines() if line.strip()}
    assert not (imports & forbidden), f"{component}: forbidden imports {imports & forbidden}"
    if component == "daemon":
        assert not (imports & {"_CGEventPost", "_CGRequestPostEventAccess"}), "The root daemon must not post input"
    subprocess.run(["codesign", "--verify", "--strict", str(binary)], check=True, capture_output=True, timeout=10)
    print(f"PASS {component}: self-check, code signature, direct symbol audit")

app = products / "PullockDevelopment.app"
app_info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
assert app_info.get("CFBundleIconName") == "AppIcon"
assert (app / "Contents/Resources/AppIcon.icns").is_file()
assert (app / "Contents/Resources/Assets.car").is_file()
print("PASS app branding: AppIcon declaration, ICNS and asset catalog embedded")
for executable in ["PullockSessionAgent", "PullockDaemon"]:
    embedded = app / "Contents/Library/LaunchServices" / executable
    assert hashlib.sha256(embedded.read_bytes()).digest() == hashlib.sha256((products / executable).read_bytes()).digest()
    subprocess.run(["codesign", "--verify", "--strict", str(embedded)], check=True, capture_output=True)
for directory, label, executable, argument in [
    ("LaunchDaemons", "app.pullock.daemon.development", "PullockDaemon", "--serve-health"),
    ("LaunchAgents", "app.pullock.session-agent.development", "PullockSessionAgent", "--monitor-health"),
]:
    definition = plistlib.loads((app / "Contents/Library" / directory / f"{label}.plist").read_bytes())
    assert definition["Label"] == label
    assert definition["BundleProgram"] == f"Contents/Library/LaunchServices/{executable}"
    assert definition["ProgramArguments"] == [executable, argument]
    assert not (set(definition) & {"Program", "UserName", "EnvironmentVariables", "StandardOutPath", "StandardErrorPath"})
print("PASS embedded helpers: signatures, exact executable content and fixed launch definitions")

# A direct-import audit supplements tests/review; it is not a proof about every
# function in linked system frameworks or a future dynamically loaded adapter.
