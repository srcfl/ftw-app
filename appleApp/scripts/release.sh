#!/usr/bin/env bash
# Ship the iPhone app from this Mac: test, archive, sign, upload to App Store
# Connect, and give the build to the public beta. No GitHub runner, and never
# an Apple Development certificate per release (Fredrik, 28 October 2026:
# every build is local).
#
#   appleApp/scripts/release.sh            the version in FTW.xcconfig, at origin/main
#   FTW_SKIP_TESTS=1 …                     skip swift test (it ran already)
#   FTW_SKIP_PILOT=1 …                     upload only; no public beta
#   FTW_XCODE_ACCOUNT=1 …                  upload through the account signed in to Xcode
#                                          when this Mac has no App Store Connect key
#   FTW_ARCHIVE=build/release/<v>-<b>/FTW.xcarchive …
#                                          export and upload an archive this script
#                                          made, without building again
#
# Run it on a clean checkout of origin/main: the store build must come from
# published source (RELEASING.md, Encryption and export).
#
# Signing. The team's Apple Development certificate in the login keychain
# signs the archive, with the profiles Xcode already holds. The archive runs
# without -allowProvisioningUpdates, so it can never create a certificate; a
# missing profile stops it with Xcode's own message. The export signs for the
# App Store with a distribution certificate Apple keeps (cloud-managed);
# Xcode renews that one when it expires, and makes no development
# certificate.
#
# The key. ASC_KEY_ID and ASC_ISSUER_ID come from the environment or else
# ~/.appstoreconnect/ftw.env (lines KEY=value), and the .p8 from ASC_KEY_PATH
# or else ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8, where
# altool looks too. The script checks for it before any slow work.
set -euo pipefail
cd "$(dirname "$0")/.."
app_dir=$PWD
top=$(git rev-parse --show-toplevel)
# A sleeping Mac would stall the upload or the public beta's wait.
caffeinate -i -w $$ &

say() { printf '\n== %s\n' "$*"; }
fail() { printf 'release: %s\n' "$*" >&2; exit 1; }
clean() {
  [[ -z $(git -C "$top" status --porcelain --untracked-files=all) ]] ||
    fail "the repository has uncommitted or untracked files; the build must be exactly $sha."
}

# --- How it reaches App Store Connect, checked first ------------------------

asc_env=${ASC_ENV:-$HOME/.appstoreconnect/ftw.env}
if [[ -f $asc_env ]]; then
  # The file fills what the environment leaves empty.
  while IFS='=' read -r name value; do
    case $name in
      ASC_KEY_ID|ASC_ISSUER_ID|ASC_KEY_PATH) [[ -n ${!name:-} ]] || export "$name=$value" ;;
    esac
  done < "$asc_env"
fi
key=${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID:-none}.p8}
auth=()
if [[ -n ${ASC_KEY_ID:-} && -n ${ASC_ISSUER_ID:-} && -f $key ]]; then
  auth=(-authenticationKeyPath "$key" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
  reach="App Store Connect key $ASC_KEY_ID"
elif [[ -n ${FTW_XCODE_ACCOUNT:-} ]]; then
  reach="the account signed in to Xcode"
else
  fail "no App Store Connect key on this Mac (RELEASING.md, The App Store Connect key on this Mac). To upload through Xcode's signed-in account instead, run with FTW_XCODE_ACCOUNT=1."
fi

# --- What ships -------------------------------------------------------------

git fetch --quiet origin main
if [[ -n ${FTW_ARCHIVE:-} ]]; then
  archive=$FTW_ARCHIVE
  [[ -d $archive ]] || fail "no archive at $archive"
  out=$(dirname "$archive")
  sha=$(cat "$out/source-revision" 2>/dev/null) || fail "$out has no source-revision; only an archive this script made can be sent."
  git -C "$top" merge-base --is-ancestor "$sha" origin/main || fail "the archive's commit $sha is not on origin/main."
  info=$archive/Products/Applications/FTW.app/Info.plist
  version=$(plutil -extract CFBundleShortVersionString raw "$info")
  build=$(plutil -extract CFBundleVersion raw "$info")
else
  sha=$(git rev-parse HEAD)
  [[ $sha == "$(git rev-parse origin/main)" ]] ||
    fail "HEAD ($sha) is not origin/main. Check out origin/main: a release ships its head."
  clean
  version=$(sed -n 's/^MARKETING_VERSION *= *//p' FTW.xcconfig)
  [[ $version =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || fail "MARKETING_VERSION '$version' is not a version App Store Connect accepts."
  # Date and time from one clock reading, so each upload is higher than the
  # last without asking Apple. No leading zero: 20261028.905, not .0905.
  now=$(date +%Y%m%d.%H%M)
  build=${FTW_BUILD:-${now%.*}.$((10#${now#*.}))}
  out=build/release/$version-$build
  archive=$out/FTW.xcarchive
fi
say "FTW $version ($build) from ${sha:0:8}, uploaded with $reach"

# --- The signing this Mac already has ---------------------------------------

team=L66M368PZ6
identity=
while IFS= read -r name; do
  if security find-certificate -c "$name" -p | openssl x509 -noout -subject | grep -q "OU *= *$team"; then
    identity=$name
    break
  fi
done < <(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p')
[[ -n $identity ]] ||
  fail "no Apple Development certificate for team $team in the login keychain. Do not let Xcode make one per release: restore the team's certificate (RELEASING.md, Signing on this Mac)."
echo "Archive signed by $identity"

# --- Test and archive -------------------------------------------------------

if [[ -z ${FTW_ARCHIVE:-} ]]; then
  if [[ -z ${FTW_SKIP_TESTS:-} ]]; then
    say "swift test"
    (cd FTWKit && swift test --quiet)
    clean
  fi
  say "Archive"
  mkdir -p "$out"
  xcodebuild archive -quiet -project FTW.xcodeproj -scheme FTW \
    -configuration Release -destination 'generic/platform=iOS' \
    -archivePath "$archive" -derivedDataPath build/release/derived -jobs 4 \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" FTW_SOURCE_REVISION="$sha"
  echo "$sha" > "$out/source-revision"
fi

say "Version in the app, its extensions and the watch app"
built=$archive/Products/Applications/FTW.app
for plist in "$built/Info.plist" "$built"/PlugIns/*.appex/Info.plist "$built"/Watch/*.app/Info.plist "$built"/Watch/*.app/PlugIns/*.appex/Info.plist; do
  [[ -f $plist ]] || fail "missing $plist"
  got=$(plutil -extract CFBundleShortVersionString raw "$plist")/$(plutil -extract CFBundleVersion raw "$plist")
  echo "$got  ${plist#"$built"/}"
  [[ $got == "$version/$build" ]] || fail "$plist has $got"
done

# --- Upload -----------------------------------------------------------------

say "Sign for the App Store and upload"
xcodebuild -exportArchive -archivePath "$archive" \
  -exportOptionsPlist ExportOptions.plist -exportPath "$out/export" \
  -allowProvisioningUpdates ${auth[@]+"${auth[@]}"}
echo "Uploaded FTW $version ($build). Apple processes it before TestFlight shows it."

# --- The public beta --------------------------------------------------------

pilot=(uv run --quiet --with pyjwt --with cryptography python "$app_dir/scripts/testflight-pilot.py" "$version" "$build")
if [[ -n ${FTW_SKIP_PILOT:-} ]]; then
  echo "Public beta skipped (FTW_SKIP_PILOT)."
elif (( ${#auth[@]} == 0 )); then
  echo "Public beta skipped: no App Store Connect key on this Mac. Run Actions → iOS public beta with $version and $build,"
  echo "or later, with the key: ASC_KEY_ID=… ASC_ISSUER_ID=… ASC_KEY_PATH=… ${pilot[*]}"
else
  say "Give it to Pilot and submit it for review"
  ASC_KEY_PATH=$key ASC_KEY_ID=$ASC_KEY_ID ASC_ISSUER_ID=$ASC_ISSUER_ID "${pilot[@]}"
fi
