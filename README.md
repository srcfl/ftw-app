# FTW app

Your home's energy, on the phone.

Native iOS (SwiftUI) and Android (Jetpack Compose). Shared logic is Kotlin
Multiplatform: pairing, passkeys, Noise, the relay, the session. The box at
home is the record. This app is a cached projection of it. The cloud is blind.

Not a wrap of the [web app](https://github.com/srcfl/ftw-webapp). Same protocol,
same QR, same relay, same RP ID (`app.ftw.energy`).

## Shape

```
SwiftUI / Compose
        │
        ▼
   shared (KMP)  — enrollment, vault, Noise IK, frames, session, relay
        │
        ▼
  wss://relay.ftw.energy   (encrypted)
        │
        ▼
     FTW box
```

Two taps: scan the QR on the box, Face ID / biometrics, the house.

## Tests

JDK 21.

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

iOS: open `iosApp/iosApp.xcodeproj`. SwiftUI Pair (camera QR + paste) and Now.
Xcode 16+, iOS 18 for passkey PRF. A Run Script build phase compiles the
Shared framework with
`./gradlew :shared:embedAndSignAppleFrameworkForXcode`.

Android: `./gradlew :androidApp:assembleDebug` (minSdk 28). Pair uses CameraX
+ ML Kit for the QR. Passkeys go through Credential Manager.

RP ID `app.ftw.energy`. PRF salt `ftw.prf.v1.vault`. Reading uses a local
wrapping copy so Now paints without a passkey prompt.

## Layout

| Path | What |
|---|---|
| `shared/` | KMP: identity, crypto, protocol, relay, session |
| `androidApp/` | Compose UI |
| `iosApp/` | SwiftUI UI |
| `protocol/registry.yaml` | Names shared with the box |
| `scripts/e2e-ftw.sh` | Live box e2e |

## Licence

Apache-2.0. See [LICENSE](LICENSE).
