#!/usr/bin/env bash
# Build and open the distribution design study in its own iPhone simulator.
set -euo pipefail
cd "$(dirname "$0")/.."

prototype_device=${1:-}
if [[ -z "$prototype_device" ]]; then
  prototype_device=$(xcrun simctl list devices available --json | python3 -c '
import json,sys
for devices in json.load(sys.stdin)["devices"].values():
    for device in devices:
        if device["name"] == "FTW Fördelning B":
            print(device["udid"]); sys.exit(0)
')
fi
if [[ -z "$prototype_device" ]]; then
  prototype_runtime=$(xcrun simctl list runtimes --json | python3 -c '
import json,sys
items=[r for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")]
items.sort(key=lambda r: tuple(map(int,r["version"].split("."))))
if not items: sys.exit("No iOS Simulator runtime is installed")
print(items[-1]["identifier"])
')
  prototype_device=$(xcrun simctl create 'FTW Fördelning B' com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro "$prototype_runtime")
fi

xcodebuild build -quiet -project FTW.xcodeproj -scheme 'FTW Distribution' \
  -destination "platform=iOS Simulator,id=$prototype_device" \
  -derivedDataPath build/distribution ONLY_ACTIVE_ARCH=YES

prototype_state=$(xcrun simctl list devices --json | python3 -c '
import json,sys
print(next(d["state"] for ds in json.load(sys.stdin)["devices"].values() for d in ds if d["udid"]==sys.argv[1]))
' "$prototype_device")
if [[ "$prototype_state" != Booted ]]; then xcrun simctl boot "$prototype_device"; fi
xcrun simctl bootstatus "$prototype_device" -b
xcrun simctl install "$prototype_device" build/distribution/Build/Products/Debug-iphonesimulator/FTW.app
xcrun simctl launch --terminate-running-process "$prototype_device" energy.ftw.app \
  -FTWDistributionDemo YES -FTWDistributionScreen now -AppleLanguages '(sv)' -AppleLocale sv_SE

prototype_developer=$(xcode-select -p)
if [[ -d "$prototype_developer/Applications/Simulator.app" ]]; then
  open "$prototype_developer/Applications/Simulator.app" --args -CurrentDeviceUDID "$prototype_device"
elif [[ -d "$prototype_developer/../Applications/DeviceHub.app" ]]; then
  open "$prototype_developer/../Applications/DeviceHub.app"
fi
printf 'FTW Fördelning B: %s\n' "$prototype_device"
