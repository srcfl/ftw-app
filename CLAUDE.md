# FTW native app — project guide

Kotlin Multiplatform shared logic. SwiftUI on iOS. Jetpack Compose on Android.
Talks to an FTW box over an encrypted session; the box is the authority and
this app is a cached projection of it.

## Current v1

Pair + Now only. Shipped on `main` as of 2026-08-22. Persist vault, site and
last readings on the phone. Cold start paints the cache, then reconnects
without a passkey. README Status lists what was proven and what is still open.

Do not add Energy / History / Plan / EV, commands, escrow, LAN, push, or store
listing until Pair + Now is solid on both phones, including wrap-key parity
with the web app.

The protocol, the QR, the relay and the identity model are specified in
[ftw-webapp](https://github.com/srcfl/ftw-webapp) `docs/architecture.md` and
`docs/protocol.md`. Read those before changing anything structural.

## Product principle

**Lean, snappy, just works.** Same constraint as the web app.

- Nothing blocks the first frame. Paint from cache, catch up.
- No configuration. No server to choose, no transport to pick.
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

`shared/` owns enrollment parse, rendezvous handles, Noise IK, frames,
session, vault wrap/unwrap, freshness and explanations.

Platform UI owns the camera, the passkey ceremony, Keychain / Keystore,
and every pixel.

Inject `PasskeyHost`, `KeyValueStore` and `SocketFactory`. Do not call
AuthenticationServices or Credential Manager from commonMain. iOS uses
Keychain. Android uses EncryptedSharedPreferences + a Keystore master key.

## Crypto

Noise_IK_25519_ChaChaPoly_SHA256, Cacophony-tested, must stay byte-identical
to the TypeScript client and the Go box. Do not swap the primitives for a
library that has not passed `NoiseTest`.

## RP ID

`app.ftw.energy`. Subdomain, never the registrable domain. Changing it
strands every passkey.

## Tests

```bash
./gradlew :shared:jvmTest
```

Green before every handoff. New protocol code needs a vector, not only a
round-trip against itself.
