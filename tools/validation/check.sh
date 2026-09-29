#!/bin/bash
set -euo pipefail

project_root=$(cd "$(dirname "$0")/../.." && pwd)
validation_root=${PULLOCK_VALIDATION_ROOT:-$(mktemp -d "${TMPDIR%/}/pullock-check.XXXXXX")}
mkdir -p "$validation_root"
printf 'Build artifacts: %s\n' "$validation_root"

swift test --package-path "$project_root/packages/PullockCore" --scratch-path "$validation_root/core"
swift test --package-path "$project_root/packages/PullockUSB" --scratch-path "$validation_root/usb"
swift test --package-path "$project_root/packages/PullockIPC" --scratch-path "$validation_root/ipc"
swift test --package-path "$project_root/packages/PullockServices" --scratch-path "$validation_root/services"
swift test --package-path "$project_root/packages/PullockActions" --scratch-path "$validation_root/actions"
swift test --package-path "$project_root/tools/hardware-harness" --scratch-path "$validation_root/probe"

for configuration in Debug Release; do
    xcodebuild -quiet -project "$project_root/apps/macos/Pullock.xcodeproj" \
        -scheme PullockDevelopment -configuration "$configuration" \
        -destination 'generic/platform=macOS' -derivedDataPath "$validation_root/xcode" build
    python3 "$project_root/tools/validation/check_binaries.py" \
        "$validation_root/xcode/Build/Products/$configuration"
done

printf 'All safe development checks passed. No hardware/action tests were run.\n'
