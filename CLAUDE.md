# FTW native app — project guide

Pure Swift on iPhone, iPad and Mac: FTWKit plus SwiftUI in `appleApp/`.
Kotlin Multiplatform shared logic with Jetpack Compose on Android.
Talks to an FTW box over an encrypted session; the box is the authority and
this app is a cached projection of it.

## Shared product direction

[FTW's vision](https://github.com/srcfl/ftw/blob/master/VISION.md) governs the native client.
Fredrik owns the direction and Sourceful develops it. External PRs are
welcome, preferably based on issues. Work is agentic first: state the problem,
scope and reproducible results. Code and short Markdown proposals follow
[CONTRIBUTING.md](CONTRIBUTING.md).

The full product aims for clear live command/outcome feedback, simple charging
and useful notifications. Those goals do not remove the current native release
gates below or claim features are present on either phone. Reuse Core's
contracts and authority as native scope expands.

## Current scope

**Apple (`appleApp/`).** On 2026-09-25 Fredrik chose a pure Swift app for
iOS and macOS that covers every screen of the web app: Pair, Now, Plan,
History with daily energy, the charger sheet, and Box (access,
notifications, restart, the sealed copy, sign out). It derives the wrap key
with HKDF exactly as the web app does, so one passkey opens a home in both.
README Status lists what is proven and what still needs a device.

**Android (`androidApp/`, `shared/`).** Pair + Now, shipped on `main` as of
2026-08-22. Do not add Energy / History / Plan / EV, commands, escrow, LAN,
push, or store listing on Android until Pair + Now is solid there, including
wrap-key parity with the web app.

Both: persist vault, site and last readings on the phone. Cold start paints
the cache, then reconnects without a passkey.

The protocol, the QR, the relay and the identity model are specified in
[ftw-webapp](https://github.com/srcfl/ftw-webapp) `docs/architecture.md` and
`docs/protocol.md`. Read those before changing anything structural.

## Product principle

**Lean, snappy, just works.** Same constraint as the web app.

- Nothing blocks the first frame. Paint from cache, catch up.
- Few required choices. Hide transport setup; expose useful household goals
  and expert controls when their flows are implemented.
- Failures heal themselves. A dropped connection reconnects on its own.
  There is no reconnect button.
- Errors say what happens now, not what broke inside.
- Least code that does the whole job.

## Non-negotiable invariants

- **Never fake live.** Every reading carries its age.
- **Freshness is two fields.** `carrier` (relay, cache, none) and `srcState`
  (live, lagging, stale, down, never) stay orthogonal.
- **The app expresses intent; the box decides.**
- **Positive watts flow into the site, negative out.** The UI never shows a
  raw minus sign.
- **Lane 0 frames are byte-identical in length and constant in cadence.**
  A test enforces this.
- **The cache is a cache, never the original.**
- **The cache key is not PRF-wrapped.** Cold start paints before Face ID.
  PRF gates enrollment and privileged commands, not reading.
- **Never hand-write a name shared with the box.** Scopes, capabilities,
  field ids come from `protocol/registry.yaml`, the same file as in
  srcfl/ftw and srcfl/ftw-webapp.

## Shared vs UI

On Apple, `appleApp/FTWKit` owns everything that is not a pixel: enrollment
parse, rendezvous handles, Noise IK, frames, the relay and Noise carriers,
the session, vault wrap/unwrap, escrow, freshness, explanations and the
state each screen reads. It builds and tests on Linux too. `appleApp/FTW`
owns the camera, the passkey ceremony, the Keychain and every pixel. Keep
logic out of the views: if a sentence or a rule can be tested, it belongs
in FTWKit with a test.

On Android, `shared/` owns the same logic in Kotlin. Inject `PasskeyHost`,
`KeyValueStore` and `SocketFactory`. Do not call Credential Manager from
commonMain. Android uses EncryptedSharedPreferences + a Keystore master key.

## Crypto

Noise_IK_25519_ChaChaPoly_SHA256, Cacophony-tested, must stay byte-identical
to the TypeScript client and the Go box. Do not swap the primitives for a
library that has not passed `NoiseTest` (Kotlin) or `NoiseTests` (Swift).
FTWKit uses CryptoKit on Apple platforms and swift-crypto on Linux.

## RP ID

`app.ftw.energy`. Subdomain, never the registrable domain. Changing it
strands every passkey.

## Tests

```bash
./gradlew :shared:jvmTest          # Android shared logic
cd appleApp/FTWKit && swift test   # Apple logic, on macOS or Linux
```

The Apple workflow also builds the app, unsigned, for the iOS Simulator and
for macOS. Review UI changes in the simulator or on a device; reading the
source is not enough.

Green before every handoff. New protocol code needs a vector, not only a
round-trip against itself.
