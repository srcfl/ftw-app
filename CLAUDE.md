# FTW native app — project guide

Two native apps. iPhone: pure Swift in `appleApp/` (FTWKit, FTWShared,
FTWDemo, SwiftUI, a WidgetKit extension). Android: Jetpack Compose on Kotlin
Multiplatform shared logic in `shared/`.
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

**iPhone (`appleApp/`).** On 2026-10-12 Fredrik approved M1 for an
iPhone-only app on iOS 26: pairing, a lean Now, a car view and price
widgets. The car view sets the level with 20/40/60/80 and ±5 through
`loadpoint.soc.set`, the goal through the schedule PUT, and has Charge now,
Pause and Back to the plan. M1 needs no server and no change in Core.
His decisions:

- iOS 26 is the minimum. iPhone only, no macOS.
- Notification text is written on the phone, in Swedish and English.
- Commands from the lock screen, Siri and notifications require unlock.
- Charge now runs with no time limit.

Do not add Plan, History, Box admin, escrow, LAN, push or the store listing
in M1. FTW Cloud (an opt-in state cache, push and statistics, readable by
Sourceful rather than end-to-end encrypted) is designed separately; nothing
in M1 may depend on it.

**Android (`androidApp/`, `shared/`).** Pair + Now, shipped on `main` as of
2026-08-22. Do not add Energy / History / Plan / EV, commands, escrow, LAN,
push, or store listing on Android until Pair + Now is solid there, including
wrap-key parity with the web app.

Both: persist vault, site and last readings on the phone. Cold start paints
the cache, then reconnects without a passkey. README Status lists what was
proven and what is still open.

The protocol, the QR, the relay and the identity model are specified in
[ftw-webapp](https://github.com/srcfl/ftw-webapp) `docs/architecture.md` and
`docs/protocol.md`. Read those before changing anything structural.

## Product principle

**Lean, snappy, just works.** Same constraint as the web app.

- Nothing blocks the first frame. Paint from cache, catch up.
- Few required choices. Hide transport setup; expose useful household goals
  and expert controls when their flows are implemented.
- Failures heal themselves. A dropped connection reconnects on its own.
  There is no reconnect button. A relay that is full (4429) says FTW is
  busy, not that something broke.
- Errors say what happens now, not what broke inside.
- Least code that does the whole job.

## Feel and speed

Fredrik's bar for the iPhone app (2026-10-12): modern, very fast, truly
native, and smooth enough to impress.

- **First frame from the cache.** No network wait and no spinner before
  it. While nothing is known, show the shape of the screen
  (`.redacted(reason: .placeholder)`), not a spinner. `LaunchClock` logs
  the time from process start to the first frame and the first content;
  quote the numbers in any PR that touches launch.
- **The handshake runs beside the first frame, never ahead of it.**
- **No timer loops.** Lane 0 drives Now. Until the box streams charger
  state (M5, or FTW Cloud C3), the chargers are read when a screen that
  shows them appears, after a command, and when the stream says the car
  started or stopped drawing. The plan's shortfall is read when the car
  view opens and when the car's plan changes.
- **A frame redraws what moved.** Small views that read only what they
  show, value inputs, and `Equatable` with `.equatable()` where a frame
  would otherwise redraw a whole section. A clock on screen ticks by the
  minute unless the second matters.
- **Modern Swift.** Swift 6 strict concurrency, `@Observable`,
  async/await and structured concurrency. No Combine, no GCD, no
  `ObservableObject`, and no UIKit except the camera. Colours live in
  asset catalogs, not `UIColor`.
- **iOS 26's design.** System components (`List`, `Form`,
  `NavigationStack`, system button styles), so Liquid Glass appears where
  the system puts it. SF Symbols with symbol effects.
- **Feel.** Numbers change with `.contentTransition(.numericText())`.
  Motion uses one spring, `Theme.spring`. The car row on Now zooms into
  the car view (`navigationTransition(.zoom)`). `.sensoryFeedback` marks
  commands and their outcomes.
- **A command answers at once.** Tap, haptic and "Sent" in under 100 ms,
  then the box's receipt (`cmd.ack`), then the outcome (`cmd.result`).
  Show the intent at once; never show a result the box has not confirmed.
- **The largest text size and dark mode** look as good as the default.
  Review all three in the simulator.

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
- **Widgets read the App Group cache and nothing else.** No key from the
  Keychain, no relay stream. Every record carries `carrier`, `srcState` and
  the time it was read, and reads back as `cache`.
- **The session closes in the background.** iOS freezes the app anyway,
  and an open socket holds one of the relay's four streams per home.
- **Never hand-write a name shared with the box.** Scopes, capabilities,
  field ids come from `protocol/registry.yaml`, the same file as in
  srcfl/ftw and srcfl/ftw-webapp.

## Shared vs UI

On iPhone, one Swift package in `appleApp/FTWKit` holds three modules:

- `FTWKit` owns everything that is not a pixel: enrollment parse,
  rendezvous handles, Noise IK, frames, the relay and Noise carriers, the
  session, vault wrap/unwrap and the state each screen reads. The app alone
  links it. It writes the App Group cache.
- `FTWShared` holds plain `Sendable` values for the app's extensions: the
  App Group cache (`prices-<site>`, `car-<site>`), the price and freshness
  formatters, and their Swedish and English words. Nothing on the main
  actor, no keys. A copy from FTW Cloud would be one more
  `CacheSource` here, not a new model.
- `FTWDemo` is the simulated box. The app links it for the demo and App
  Review; FTWKit never does.

`appleApp/FTW` owns the camera, the passkey ceremony, the Keychain and every
pixel. `appleApp/FTWWidgets` owns the widgets. Keep logic out of views: if a
sentence or a rule can be tested, it belongs in a package module with a
test. The App Group name is written once, in `appleApp/FTW.xcconfig`; the
entitlements and Info.plists read it from there.

On Android, `shared/` owns the same logic in Kotlin. Inject `PasskeyHost`,
`KeyValueStore` and `SocketFactory`. Do not call Credential Manager from
commonMain. Android uses EncryptedSharedPreferences + a Keystore master key.

## Crypto

Noise_IK_25519_ChaChaPoly_SHA256, Cacophony-tested, must stay byte-identical
to the TypeScript client and the Go box. Do not swap the primitives for a
library that has not passed `NoiseTest` (Kotlin) or `NoiseTests` (Swift).
FTWKit uses CryptoKit.

## RP ID

`app.ftw.energy`. Subdomain, never the registrable domain. Changing it
strands every passkey.

## Tests

```bash
./gradlew :shared:jvmTest          # Android shared logic
cd appleApp/FTWKit && swift test   # iPhone logic, on a Mac with Xcode 27
```

`ContractTests` reads `protocol/registry.yaml` and fails when `Contract.swift`
drifts from it. Update `Contract.swift` by hand, never with a name the
registry does not have. The Apple workflow also builds the app and widget
for the iOS Simulator. Review UI changes in the simulator or on a device;
reading the source is not enough.

Green before every handoff. New protocol code needs a vector, not only a
round-trip against itself.
