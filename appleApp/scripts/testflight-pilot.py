#!/usr/bin/env python3
"""Give a TestFlight build to the Pilot group, FTW's public beta.

    testflight-pilot.py <version> <build>

The App Store Connect key comes from ASC_KEY_ID, ASC_ISSUER_ID and
ASC_KEY_PATH (the .p8 file). The script waits until Apple has processed the
build, writes What to Test from appleApp/store/<locale>/release-notes.txt,
adds the build to Pilot and submits it for Beta App Review. A step that is
already done is skipped, so a second run is safe.
"""

import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

import jwt

API = "https://api.appstoreconnect.apple.com/v1"
BUNDLE_ID = "energy.ftw.app"
GROUP = "Pilot"
STORE = Path(__file__).resolve().parent.parent / "store"
# Apple processes most builds within the hour.
WAIT_S = 90 * 60
# Beta review states that need nothing more from this script.
SUBMITTED = ("WAITING_FOR_BETA_REVIEW", "IN_BETA_REVIEW", "BETA_APPROVED", "READY_FOR_BETA_TESTING", "IN_BETA_TESTING")


def fail(message):
    """Stop with a reason the run's summary shows too."""
    print(message)
    sys.exit(1)


def token():
    now = int(time.time())
    claims = {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}
    key = Path(os.environ["ASC_KEY_PATH"]).read_text()
    return jwt.encode(claims, key, algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})


def call(method, path, body=None, query=None):
    """One API call. A busy or unreachable API is tried three more times."""
    url = API + path + ("?" + urllib.parse.urlencode(query) if query else "")
    data = json.dumps(body).encode() if body is not None else None
    for attempt in range(4):
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", "Bearer " + token())
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                raw = r.read()
            return json.loads(raw) if raw else None
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")
            if (e.code == 429 or e.code >= 500) and attempt < 3:
                time.sleep(10 * 2 ** attempt)
                continue
            fail(f"{method} {path}: HTTP {e.code}\n{detail}")
        except (urllib.error.URLError, TimeoutError) as e:
            if attempt < 3:
                time.sleep(10 * 2 ** attempt)
                continue
            fail(f"{method} {path}: {e}")


def one(rows, what):
    if len(rows) != 1:
        fail(f"Expected one {what}, found {len(rows)}.")
    return rows[0]


def processed_build(app_id, version, build):
    """The build's id once Apple has processed it."""
    deadline = time.time() + WAIT_S
    while True:
        rows = call("GET", "/builds", query={
            "filter[app]": app_id,
            "filter[version]": build,
            "filter[preReleaseVersion.version]": version,
            # Without it a refused build may never show.
            "filter[processingState]": "PROCESSING,FAILED,INVALID,VALID",
            "fields[builds]": "processingState,version",
        })["data"]
        if rows:
            b = one(rows, f"build {version} ({build})")
            state = b["attributes"]["processingState"]
            if state == "VALID":
                return b["id"]
            if state in ("FAILED", "INVALID"):
                fail(f"Apple refused {version} ({build}): {state}. GET /v1/apps/{app_id}/buildUploads gives the reason.")
            print(f"{version} ({build}): {state}, waiting")
        else:
            print(f"{version} ({build}) is not in App Store Connect yet, waiting")
        if time.time() > deadline:
            fail(f"{version} ({build}) was not processed within {WAIT_S // 60} minutes.")
        time.sleep(60)


def store_dir(locale):
    """appleApp/store's folder for an App Store Connect locale: en-US is
    en-US, sv is sv-SE."""
    exact = STORE / locale
    if exact.is_dir():
        return exact
    language = locale.split("-")[0]
    return next((d for d in sorted(STORE.iterdir()) if d.is_dir() and d.name.split("-")[0] == language), None)


def beta_state(build_id, deadline):
    """The build's external beta state once TestFlight has finished with it."""
    while True:
        state = call("GET", f"/builds/{build_id}/buildBetaDetail")["data"]["attributes"]["externalBuildState"]
        if state != "PROCESSING":
            return state
        if time.time() > deadline:
            fail(f"TestFlight was still processing the build after {WAIT_S // 60} minutes.")
        print("TestFlight: PROCESSING, waiting")
        time.sleep(30)


def write_what_to_test(app_id, build_id):
    locales = [r["attributes"]["locale"] for r in call("GET", f"/apps/{app_id}/betaAppLocalizations")["data"]]
    if not locales:
        fail("The app has no TestFlight Test Information, so What to Test has nowhere to go (RELEASING.md, External TestFlight).")
    matched = {store_dir(locale) for locale in locales}
    for folder in sorted(STORE.iterdir()):
        if folder.is_dir() and (folder / "release-notes.txt").is_file() and folder not in matched:
            print(f"What to Test: {folder.name}/release-notes.txt has no language in Test Information, skipped")
    have = {r["attributes"]["locale"]: r["id"] for r in call("GET", f"/builds/{build_id}/betaBuildLocalizations")["data"]}
    for locale in locales:
        folder = store_dir(locale)
        if folder is None or not (folder / "release-notes.txt").is_file():
            print(f"What to Test, {locale}: no release notes in appleApp/store, left as it is")
            continue
        text = (folder / "release-notes.txt").read_text().strip()
        if locale in have:
            call("PATCH", f"/betaBuildLocalizations/{have[locale]}", {"data": {
                "type": "betaBuildLocalizations", "id": have[locale], "attributes": {"whatsNew": text}}})
        else:
            call("POST", "/betaBuildLocalizations", {"data": {
                "type": "betaBuildLocalizations",
                "attributes": {"locale": locale, "whatsNew": text},
                "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}})
        print(f"What to Test, {locale}: from {folder.name}/release-notes.txt")


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    version, build = sys.argv[1:3]
    if not re.fullmatch(r"[0-9]+(\.[0-9]+){0,2}", version) or not re.fullmatch(r"[0-9]+(\.[0-9]+)?", build):
        fail(f"'{version}' ({build}) is not a version and build App Store Connect uses.")

    deadline = time.time() + WAIT_S
    app_id = one(call("GET", "/apps", query={"filter[bundleId]": BUNDLE_ID})["data"], f"app {BUNDLE_ID}")["id"]
    build_id = processed_build(app_id, version, build)
    write_what_to_test(app_id, build_id)

    group = one(call("GET", "/betaGroups", query={"filter[app]": app_id, "filter[name]": GROUP})["data"], f"group {GROUP}")
    if group["attributes"].get("isInternalGroup"):
        fail(f"{GROUP} is an internal group; the public beta needs the external one.")
    groups = {g["id"] for g in call("GET", f"/builds/{build_id}/betaGroups")["data"]}
    if group["id"] not in groups:
        call("POST", f"/betaGroups/{group['id']}/relationships/builds", {"data": [{"type": "builds", "id": build_id}]})
    print(f"{version} ({build}) is in {GROUP}")

    state = beta_state(build_id, deadline)
    if state in SUBMITTED:
        print(f"Beta App Review: {state}, nothing to submit")
    elif state == "READY_FOR_BETA_SUBMISSION":
        call("POST", "/betaAppReviewSubmissions", {"data": {
            "type": "betaAppReviewSubmissions",
            "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}})
        print(f"Submitted for Beta App Review: {beta_state(build_id, deadline)}")
    else:
        fail(f"Beta App Review: the build is {state}, which this script does not submit. App Store Connect → TestFlight shows why.")


if __name__ == "__main__":
    main()
