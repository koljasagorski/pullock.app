"""Check development executables without opening a UI or using real system actions."""
import json
from pathlib import Path
import subprocess
import sys


products = Path(sys.argv[1])
binaries = {
    "app": products / "PullockDevelopment.app/Contents/MacOS/PullockDevelopment",
    "sessionAgent": products / "PullockSessionAgent",
    "daemon": products / "PullockDaemon",
}
forbidden = {
    "_CGEventPost", "_CGRequestPostEventAccess", "_SACLockScreenImmediate",
    "_IOCreatePlugInInterfaceForService", "_posix_spawn", "_posix_spawnp",
    "_reboot", "_system", "_execve", "_SMJobBless",
}
for component, binary in binaries.items():
    output = subprocess.run([str(binary), "--self-check"], check=True, capture_output=True, text=True, timeout=15)
    report = json.loads(output.stdout)
    assert report["component"] == component
    assert report["realActions"] == 0
    assert report["protocolVersion"] == 1
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
    subprocess.run(["codesign", "--verify", "--strict", str(binary)], check=True, capture_output=True, timeout=10)
    print(f"PASS {component}: self-check, code signature, direct symbol audit")

# A direct-import audit supplements tests/review; it is not a proof about every
# function in linked system frameworks or a future dynamically loaded adapter.
