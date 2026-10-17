# FTW app

Your home's energy, on the phone.

Two native apps. The iPhone app is pure Swift in `appleApp/`. The Android app
is Jetpack Compose on Kotlin Multiplatform (`shared/`, `androidApp/`). Both
carry pairing, passkeys, Noise, the relay and the session. The box at home is
the record. This app is a cached projection of it. The cloud is blind.

Not a wrap of the [web app](https://github.com/srcfl/ftw-webapp). Same protocol,
same QR, same relay, same RP ID (`app.ftw.energy`).

## Product direction and contributions

Follow [FTW's shared vision](https://github.com/srcfl/ftw/blob/master/VISION.md) and
[roadmap](https://github.com/srcfl/ftw/blob/master/docs/roadmap.md). The target experience needs
few routine choices, honest live feedback and reliable daily charging.
The native status below is a dated record and its verification gates still
apply; the vision does not declare new native features shipped.

Sourceful develops this app. PRs are welcome, preferably based on
[issues](https://github.com/srcfl/ftw-app/issues). Share a short Markdown
proposal or a focused fix with relevant test evidence.
See [CONTRIBUTING.md](CONTRIBUTING.md).

## Shape

```
 iPhone (appleApp/)                         Android
 SwiftUI app ── widgets                     Compose
     │            │                            │
     ▼            ▼                            ▼
 FTWKit ──► FTWShared ◄── App Group      shared (KMP)
 session,     cache records,             enrollment, vault,
 Noise, vault formatters                 Noise IK, frames,
     │                                   session, relay
     └──────────────────┬──────────────────────┘
                        ▼
   iPhone: wss://cloud.ftw.energy/v1/app, the box session inside as tun
   The iPhone has no relay fallback. Android remains an unreleased prototype.
   The session stays encrypted end to end to the box
                        │
                        ▼
                     FTW box
```

Two taps: scan the QR on the box, Face ID / biometrics, the house.

The iPhone requires the Cloud home id from a v3 pairing QR or an earlier
box session. A saved home without it needs a new QR from an updated box.
Cloud loss leaves dated cached readings and retries the same Cloud route.
The relay carrier remains only in test fixtures; it is absent from FTWKit's
shipped sources. The Android prototype needs its own Cloud work before a
first release.

## Status: iPhone (2026-10-12)

M1 is pairing, a lean Now, a car view and price widgets. This is its
foundation, taken from the Swift draft in #5 and cut down to that scope.
iOS 26 is the minimum. iPhone only.

**In the app**

- Pair: camera QR, a link from outside shown before it is trusted (also a
  pairing QR scanned with the iOS camera, as a universal link), and the live
  demo against a simulated box. In the simulator, which has no camera, a
  picture of the QR from Photos takes the same path.
- Now: one sentence, the energy flow, the price card with the cheapest two
  hours, today's totals and the fuse. The freshness band above it keeps
  carrier and source state apart.
- A price widget that reads the App Group cache and nothing else.
- The app writes `prices-<site>` and `car-<site>` into the App Group after
  each read, with where each reading came from and when.
- The session closes when the app goes to the background and opens again
  on return, without a passkey.
- A relay that turns the phone away with 4429 shows "FTW is busy" ("FTW är
  upptaget") instead of an error.

**Proven**

| Check | Result |
|---|---|
| `swift test` in `appleApp/FTWKit` (Xcode 27, Swift 6.4) | 94 tests green, 1 live test skipped |
| Cross-implementation vectors from the web app and the box | Noise, frames, rendezvous handles and the vault copy match |
| `ContractTests` against `protocol/registry.yaml` | Scopes, ops, capabilities, modes, errors, states and frozen field ids match |
| App and widget for the iOS Simulator, signed ad hoc | Builds; both carry the App Group entitlement |
| Demo in the iOS Simulator (iPhone 17, iOS 26.5) | Launches and streams |
| A picture of a pairing QR, picked from Photos in that simulator | Read and paired; the home then dials the relay |

**Next in M1**

The car view (level presets 20/40/60/80 and ±5 through `loadpoint.soc.set`,
the goal through the schedule PUT, Charge now, Pause and Back to the plan),
the four price widget families, then tests and screenshots.

**Manual steps before a phone build**

The team is `L66M368PZ6`, set once in `appleApp/FTW.xcconfig` for the app and
the widget, with automatic signing. Nothing for signing is in the repository.
Someone in that team still has to:

- Register the App IDs `energy.ftw.app` and `energy.ftw.app.widgets`, the
  App Group `group.energy.ftw.app` on both, and Associated Domains on the
  app. Signing in to Xcode with the team and building for a phone does this
  through automatic signing; the developer portal works too.
- Publish `apple-app-site-association` on `app.ftw.energy` with
  `L66M368PZ6.energy.ftw.app` under `webcredentials` and `/p` under
  `applinks` (in ftw-webapp). Passkeys and the camera QR link need it.

Simulator builds sign ad hoc and need no Apple account.

**Not in M1 (do not start these next)**

Plan, History, Box admin, escrow and recovery, spoken box codes, macOS,
LAN, WebRTC, push and the store listing.

## Status: Android (2026-08-22)

V1 is Pair + Now. That is on `main` as of 2026-08-22. Not a wrap of the web
app. Not Flutter, not React Native. Android's KMP core stays as it is until
Android is back in scope.

**In the app today**

- Scan or paste a v2 pairing QR (`https://app.ftw.energy/p#v2.…`).
- One passkey prompt at enroll. RP ID `app.ftw.energy`. PRF salt `ftw.prf.v1.vault`.
- Noise_IK_25519_ChaChaPoly_SHA256 to the box through `wss://relay.ftw.energy`.
- Now shows headline plus grid / solar / battery / house from frozen field ids.
- Vault, site and last readings live in Android
  EncryptedSharedPreferences. Cold start paints from cache, then
  reconnects without Face ID. Forget wipes the store.

**Proven here**

| Check | Result |
|---|---|
| `./gradlew :shared:jvmTest` | Green |
| Live box e2e (`127.0.0.1:18080` + production relay) | `hello_ok` + snapshot, phase `streaming` |
| Android emulator `FTW_Phone` (API 35 ARM64) | APK installed, Pair shown twice |

Passkey PRF cannot run on the JVM. Live e2e uses a local wrapping key for the
ceremony and the real Noise / relay / box path. The Android emulator has no
camera feed — paste the pairing link.

**Not v1 on Android (do not start these next)**

Energy, History, Plan, EV, commands, escrow restore, spoken codes, LAN,
WebRTC, push, Play listing.

**Known holes**

- `srcState` should follow the Now fields' `srcId` in the dict, not every
  driver on the site.
- Wrap key is raw PRF bytes, not the web app's HKDF. An Android vault will
  not open in the PWA, and the other way around. The iPhone app uses the
  web app's HKDF.
- `PasskeyHost.enroll` from Kotlin still blocks. The UIs call the async
  ceremony and skip that path.
- Field ids in `Explanation.kt` are still hand-written; they should come from
  `protocol/registry.yaml`.

## Tests

iPhone, on a Mac with Xcode 27:

```bash
cd appleApp/FTWKit && swift test
```

Android, JDK 21:

```bash
export JAVA_HOME="$(brew --prefix openjdk@21)/libexec/openjdk.jdk/Contents/Home"
./gradlew :shared:jvmTest
```

The Android suite covers enrollment URLs, Cacophony Noise IK, hello/sub CBOR matching
the box's interop hex, 512-byte lane 0 frames, the vault, and a session that
turns hello_ok + snap into Now state.

## E2E against FTW

Start a box (`make dev` in [srcfl/ftw](https://github.com/srcfl/ftw), or
`go run ./cmd/ftw` with `app_link.enabled: true`). The box joins
`wss://relay.ftw.energy` — that origin is fixed on the box, so the client
meets it there.

```bash
export FTW_LIVE_BOX=127.0.0.1:8080   # or 18080 if the API port moved
export FTW_LIVE_RELAY=wss://relay.ftw.energy
./scripts/e2e-ftw.sh
```

The test mints `POST /api/app-link/pairing` with `{"role":"owner"}`, runs the
shipped `connectToSite` path (Noise IK, pairing code in handshake message 1,
prologue `ftw.session.v1:` + box static), and asserts `hello_ok` plus a
snapshot that includes the frozen field ids.

## Native apps

iPhone: open `appleApp/FTW.xcodeproj` in Xcode 27 and run the FTW scheme on
a simulator. The demo on the pairing screen runs without a box, a passkey or
a network; `-FTWDemo YES` opens it at launch in a debug build. From the
command line:

```bash
cd appleApp
xcodebuild build -project FTW.xcodeproj -scheme FTW -destination 'generic/platform=iOS Simulator'
```

Simulator builds sign ad hoc (`FTW.xcconfig`), so the App Group entitlement
travels with the app and its widget.

Android: `./gradlew :androidApp:assembleDebug` (minSdk 28). Pair uses CameraX
+ ML Kit for the QR. Passkeys go through Credential Manager.

Emulator (AVD `FTW_Phone`, API 35 ARM64 Google APIs):

```bash
export ANDROID_HOME="$HOME/Android/sdk"
"$ANDROID_HOME/emulator/emulator" -avd FTW_Phone
adb install -r androidApp/build/outputs/apk/debug/androidApp-debug.apk
adb shell am start -n energy.ftw.app/.MainActivity
```

RP ID `app.ftw.energy`. PRF salt `ftw.prf.v1.vault`. Reading uses a local
wrapping copy so Now paints without a passkey prompt.

## Layout

| Path | What |
|---|---|
| `appleApp/FTWKit/Sources/FTWKit` | Swift: identity, crypto, protocol, Cloud tunnel, session, screen state. The app alone links it. |
| `appleApp/FTWKit/Sources/FTWShared` | `Sendable` values for the app and its extensions: the App Group cache and the price and freshness formatters |
| `appleApp/FTWKit/Sources/FTWDemo` | The simulated box, for the demo, App Review and previews |
| `appleApp/FTW/` | SwiftUI for iPhone, Keychain, passkeys, camera |
| `appleApp/FTWWidgets/` | WidgetKit extension. Reads the cache; no key, no relay. |
| `appleApp/FTW.xcconfig` | Settings app and widget share: the App Group, versions, signing |
| `shared/` | KMP for Android: identity, crypto, protocol, relay, session |
| `androidApp/` | Compose UI |
| `protocol/registry.yaml` | Names shared with the box |
| `scripts/e2e-ftw.sh` | Live box e2e (Android shared logic) |

The Xcode project uses folders that Xcode keeps in step with the disk. A new
file under `FTW/`, `FTWWidgets/` or a package target needs no change to
`project.pbxproj`; only a new target does.

## Licence

AGPL-3.0-only with the Energyplan combination permission and an app store
distribution permission. See [LICENSE](LICENSE), [LICENSING.md](LICENSING.md)
and [NOTICE](NOTICE).
Earlier Apache-licensed versions retain their earlier grants.
