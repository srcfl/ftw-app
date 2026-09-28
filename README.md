# FTW app

Your home's energy, on the phone.

Pure Swift on iPhone, iPad and Mac (FTWKit and SwiftUI). Jetpack Compose on
Android, with its logic in Kotlin Multiplatform. Both carry pairing,
passkeys, Noise, the relay and the session. The box at home is the record.
This app is a cached projection of it. The cloud is blind.

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
SwiftUI (iOS, macOS)          Compose (Android)
        │                            │
        ▼                            ▼
 FTWKit (Swift)                shared (KMP)
 enrollment, vault, escrow,    enrollment, vault,
 Noise IK, frames, session,    Noise IK, frames,
 relay, screen state           session, relay
        │                            │
        └─────────────┬──────────────┘
                      ▼
        wss://relay.ftw.energy   (encrypted)
                      │
                      ▼
                   FTW box
```

Two taps: scan the QR on the box, Face ID / biometrics, the house.

## Status: Apple (2026-09-25)

The Apple app is pure Swift and covers every screen of the web app. The
wrap key comes from HKDF over the PRF output, exactly as in the web app, so
one passkey opens a home in both. Native pairings made before this change
scan the QR again.

**In the app**

- Pair: camera QR, a picture of the QR on a Mac, passkey recovery from the
  sealed copy, a link arriving from outside shown before it is trusted, and
  the live demo against a simulated box.
- Now: one sentence, the energy flow, the price card with the cheapest two
  hours, what FTW does next, today's totals and savings, the fuse, a live
  line per part of the house, and the charger sheet (charge now, pause,
  battery level, goal, spare solar only, home battery boost, car battery
  size, charging windows).
- Plan: the headline, how the home is run, prices for today and tomorrow,
  and the next twelve hours.
- History: energy per day for today, 7 and 30 days, and power over 24 h to
  a year from cached tiles.
- Box: identity, who can see this home and viewer invites, notification
  rules and history, restart, the sealed copy, sign out.
- The freshness band above every screen, with carrier and source state kept
  apart. A Mac also gets a menu bar glance.

**Proven**

| Check | Result |
|---|---|
| `swift test` in `appleApp/FTWKit`, Linux (Swift 6.3) and macOS (CryptoKit) | 95 tests green |
| Cross implementation vectors from the web app and the box | Noise, frames, rendezvous handles, recovery blob, escrow ids and write keys, vault copy all match |
| Live box through the production relay | `hello_ok`, snapshot, `streaming`, history tiles |
| Unsigned app build in CI | iOS Simulator and macOS |

**Needs a device or an owner decision**

- Passkeys on a real phone or Mac need a signing team and an
  `apple-app-site-association` file on `app.ftw.energy` that names the app
  (`<TEAM>.energy.ftw.app` under `webcredentials` and `applinks`).
- Nobody has reviewed the screens in a simulator or on a device yet.
- Notifications: the box reaches phones through web push and ntfy. This app
  manages the box's rules and shows what was sent, but cannot receive them
  until the box and relay learn to send to APNs.

## Status: Android (2026-08-22)

V1 is Pair + Now. Not a wrap of the web app. Not Flutter, not React Native.

**In the app today**

- Scan or paste a v2 pairing QR (`https://app.ftw.energy/p#v2.…`).
- One passkey prompt at enroll. RP ID `app.ftw.energy`. PRF salt `ftw.prf.v1.vault`.
- Noise_IK_25519_ChaChaPoly_SHA256 to the box through `wss://relay.ftw.energy`.
- Now shows headline plus grid / solar / battery / house from frozen field ids.
- Vault, site and last readings live in Android EncryptedSharedPreferences.
  Cold start paints from cache, then reconnects without biometrics. Forget
  wipes the store.

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
  not open in the PWA, and the other way around.
- `PasskeyHost.enroll` from Kotlin still blocks. The UI calls the async
  ceremony and skips that path.
- Field ids in `Explanation.kt` are still hand-written; they should come from
  `protocol/registry.yaml`.

## Tests

Apple, on macOS or Linux (Swift 6.1 or newer):

```bash
cd appleApp/FTWKit && swift test
```

Android, JDK 21.

```bash
export JAVA_HOME="$(brew --prefix openjdk@21)/libexec/openjdk.jdk/Contents/Home"
./gradlew :shared:jvmTest
```

That suite covers enrollment URLs, Cacophony Noise IK, hello/sub CBOR matching
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

iOS and macOS: open `appleApp/FTW.xcodeproj`, pick your team under Signing,
and run the FTW scheme on a simulator, a device or My Mac. Xcode 16 or
newer; iOS 18 and macOS 15 for passkey PRF. The demo on the pairing screen
runs without a box, a passkey or a network.

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
| `appleApp/FTWKit/` | Swift: identity, crypto, protocol, relay, session, screen state |
| `appleApp/FTW/` | SwiftUI for iOS and macOS |
| `shared/` | KMP for Android: identity, crypto, protocol, relay, session |
| `androidApp/` | Compose UI |
| `protocol/registry.yaml` | Names shared with the box |
| `scripts/e2e-ftw.sh` | Live box e2e |

## Licence

AGPL-3.0-only with the Energyplan combination permission. See
[LICENSE](LICENSE), [LICENSING.md](LICENSING.md) and [NOTICE](NOTICE).
Earlier Apache-licensed versions retain their earlier grants.
