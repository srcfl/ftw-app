#!/usr/bin/env bash
# App Store screenshots: the demo on a 6.9" iPhone (1320 x 2868), in Swedish
# and English, ready for App Store Connect (RELEASING.md, step 10).
#
# Makes its own simulator and deletes it afterwards, so it leaves anyone
# else's alone. Needs a Debug build in build/ios, as for demo-screenshots.sh:
#   xcodebuild build -project FTW.xcodeproj -scheme FTW \
#     -destination 'generic/platform=iOS Simulator' -derivedDataPath build/ios
#
#   scripts/store-screenshots.sh [out]   default build/store-screenshots
#   FTW_STORE_DEVICE=iPhone-17-Pro       another size (6.3", 1206 x 2622)
#   FTW_STORE_LOOK=light                 light instead of dark
set -euo pipefail
cd "$(dirname "$0")/.."
app=build/ios/Build/Products/Debug-iphonesimulator/FTW.app
out=${1:-build/store-screenshots}
device=com.apple.CoreSimulator.SimDeviceType.${FTW_STORE_DEVICE:-iPhone-17-Pro-Max}
look=${FTW_STORE_LOOK:-dark}

runtime=$(xcrun simctl list runtimes available --json | python3 -c '
import json, sys
ios = [r for r in json.load(sys.stdin)["runtimes"] if r["platform"] == "iOS"]
print(max(ios, key=lambda r: [int(p) for p in r["version"].split(".")])["identifier"])')

udid=$(xcrun simctl create "FTW store screenshots" "$device" "$runtime")
trap 'xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true; xcrun simctl delete "$udid"' EXIT
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl ui "$udid" appearance "$look"
# The status bar Apple's own pictures show.
xcrun simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi \
  --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4 \
  --batteryState charged --batteryLevel 100
xcrun simctl install "$udid" "$app"

# folder, language, name, then the app's launch arguments
shoot() {
  local dir=$1 lang=$2 name=$3
  shift 3
  mkdir -p "$out/$dir"
  # The app opens dark by its own setting; `system` lets FTW_STORE_LOOK decide.
  xcrun simctl launch --terminate-running-process "$udid" energy.ftw.app \
    -AppleLanguages "($lang)" -AppleLocale "${dir/-/_}" -appearance system "$@" >/dev/null
  sleep 12
  xcrun simctl io "$udid" screenshot "$out/$dir/$name.png" >/dev/null 2>&1
  echo "$out/$dir/$name.png $(sips -g pixelWidth -g pixelHeight "$out/$dir/$name.png" | awk '/pixel/ {printf "%s ", $2}')"
}

# -FTWTab and -FTWDemoCar only work in a Debug build with the car view. No
# pairing screen: in the simulator it shows a button a phone does not have.
for pair in sv-SE:sv en-US:en; do
  dir=${pair%%:*} lang=${pair##*:}
  shoot "$dir" "$lang" 1-now -FTWDemo YES
  shoot "$dir" "$lang" 2-car -FTWDemo YES -FTWTab car
  shoot "$dir" "$lang" 3-charging -FTWDemo YES -FTWTab car -FTWDemoCar charging
done
