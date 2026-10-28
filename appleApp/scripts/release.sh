#!/usr/bin/env bash
# Ship the iPhone app from this Mac: test, archive, sign, upload to App Store
# Connect, and give the build to the public beta. No GitHub runner and no new
# certificate (Fredrik, 28 October 2026: every build is local).
#
#   appleApp/scripts/release.sh          the version in FTW.xcconfig
#   FTW_SKIP_TESTS=1 …                   skip swift test (it ran already)
#   FTW_SKIP_PILOT=1 …                   upload only; no public beta
#
# Run it on a clean checkout of a commit that is on origin/main: the store
# build must come from published source (RELEASING.md, Encryption and export).
#
# Signing. The team's Apple Development certificate in the login keychain
# signs the archive, with the profiles Xcode already holds. The archive runs
# without -allowProvisioningUpdates, so it can never create a certificate; a
# missing profile stops it with Xcode's own message. The export signs for the
# App Store with Apple's cloud-managed distribution certificate, which nobody
# creates or keeps on a disk, through the App Store Connect key below or else
# the account signed in under Xcode, Settings, Accounts.
#
# The key. ASC_KEY_ID and ASC_ISSUER_ID come from the environment or from
# ~/.appstoreconnect/ftw.env, and the .p8 from ASC_KEY_PATH or
# ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8, where altool looks
# too. Without a key the upload uses the Xcode account and the public beta
# step is skipped, with a line saying how to run it.
set -euo pipefail
cd "$(dirname "$0")/.."
app_dir=$PWD

say() { printf '\n== %s\n' "$*"; }
fail() { printf 'release: %s\n' "$*" >&2; exit 1; }

# --- What ships -------------------------------------------------------------

git fetch --quiet origin main
sha=$(git rev-parse HEAD)
git merge-base --is-ancestor "$sha" origin/main ||
  fail "HEAD ($sha) is not on origin/main. Release only published commits."
[[ -z $(git status --porcelain --untracked-files=all -- .) ]] ||
  fail "appleApp has uncommitted or untracked files; the build must be exactly $sha."

version=$(sed -n 's/^MARKETING_VERSION *= *//p' FTW.xcconfig)
[[ $version =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || fail "MARKETING_VERSION '$version' is not a version App Store Connect accepts."
# Date and time, so each upload is higher than the last without asking Apple.
build=${FTW_BUILD:-$(date +%Y%m%d).$(date +%H%M)}
out=build/release/$version-$build
say "FTW $version ($build) from ${sha:0:8}"

# --- The signing this Mac already has ---------------------------------------

team=L66M368PZ6
identity=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)
[[ -n $identity ]] || fail "no Apple Development certificate in the login keychain. Do not let Xcode make one per release: restore the team's certificate (RELEASING.md, Signing on this Mac)."
security find-certificate -c "$identity" -p | openssl x509 -noout -subject | grep -q "OU *= *$team" ||
  fail "'$identity' is not team $team's."
echo "Signs with $identity"

asc_env=${ASC_ENV:-$HOME/.appstoreconnect/ftw.env}
# shellcheck disable=SC1090
[[ -f $asc_env ]] && source "$asc_env"
key=${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID:-none}.p8}
auth=()
if [[ -n ${ASC_KEY_ID:-} && -n ${ASC_ISSUER_ID:-} && -f $key ]]; then
  auth=(-authenticationKeyPath "$key" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
  echo "Uploads with App Store Connect key $ASC_KEY_ID"
else
  echo "Uploads with the account signed in to Xcode (no App Store Connect key found)"
fi

# --- Test, archive, check, upload -------------------------------------------

if [[ -z ${FTW_SKIP_TESTS:-} ]]; then
  say "swift test"
  (cd FTWKit && swift test --quiet)
fi

say "Archive"
mkdir -p "$out"
xcodebuild archive -quiet -project FTW.xcodeproj -scheme FTW \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$out/FTW.xcarchive" -derivedDataPath build/release/derived -jobs 4 \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" FTW_SOURCE_REVISION="$sha"

say "Version in the app, its extensions and the watch app"
built=$out/FTW.xcarchive/Products/Applications/FTW.app
for plist in "$built/Info.plist" "$built"/PlugIns/*.appex/Info.plist "$built"/Watch/*.app/Info.plist "$built"/Watch/*.app/PlugIns/*.appex/Info.plist; do
  got=$(plutil -extract CFBundleShortVersionString raw "$plist")/$(plutil -extract CFBundleVersion raw "$plist")
  echo "$got  ${plist#"$built"/}"
  [[ $got == "$version/$build" ]] || fail "$plist has $got"
done

say "Sign for the App Store and upload"
xcodebuild -exportArchive -archivePath "$out/FTW.xcarchive" \
  -exportOptionsPlist ExportOptions.plist -exportPath "$out/export" \
  -allowProvisioningUpdates ${auth[@]+"${auth[@]}"}
echo "Uploaded FTW $version ($build). Apple processes it before TestFlight shows it."

# --- The public beta --------------------------------------------------------

if [[ -n ${FTW_SKIP_PILOT:-} ]]; then
  echo "Public beta skipped (FTW_SKIP_PILOT)."
elif (( ${#auth[@]} == 0 )); then
  echo "Public beta skipped: no App Store Connect key on this Mac (see the top of this script)."
  echo "Later, with the key: ASC_KEY_PATH=… uv run --with pyjwt --with cryptography scripts/testflight-pilot.py $version $build"
else
  say "Give it to Pilot and submit it for review"
  ASC_KEY_PATH=$key ASC_KEY_ID=$ASC_KEY_ID ASC_ISSUER_ID=$ASC_ISSUER_ID \
    uv run --quiet --with pyjwt --with cryptography python "$app_dir/scripts/testflight-pilot.py" "$version" "$build"
fi
