#!/usr/bin/env bash
# Photographs every screen of the demo in an iOS Simulator, for review.
# Boots the newest iPhone simulator, so run it where no one else is using
# one. Needs a Debug build in build/ios, as the Apple workflow makes:
#   xcodebuild build -project FTW.xcodeproj -scheme FTW \
#     -destination 'generic/platform=iOS Simulator' -derivedDataPath build/ios
set -euo pipefail
cd "$(dirname "$0")/.."
app=build/ios/Build/Products/Debug-iphonesimulator/FTW.app
out=${1:-build/screenshots}
mkdir -p "$out"

udid=$(xcrun simctl list devices available --json | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
phones = [d for runtime, ds in sorted(devices.items()) if "iOS" in runtime for d in ds if d["name"].startswith("iPhone")]
print(phones[-1]["udid"])')

xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b
xcrun simctl install "$udid" "$app"

# name, appearance, then the app's launch arguments
shoot() {
  local name=$1 look=$2
  shift 2
  xcrun simctl ui "$udid" appearance "$look"
  # The app opens dark by its own setting; `system` lets the look above decide.
  xcrun simctl launch --terminate-running-process "$udid" energy.ftw.app -appearance system "$@" >/dev/null
  sleep 8
  xcrun simctl io "$udid" screenshot "$out/$name.png" >/dev/null
  echo "$out/$name.png"
}

shoot pair dark
shoot now dark -FTWDemo YES -FTWTab now
shoot now-light light -FTWDemo YES -FTWTab now
