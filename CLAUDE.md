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

**Apple Watch (`appleApp/FTWWatch*`).** W1, asked for by Fredrik on
2026-10-14: Now, the plan dial (the Crown steps it by quarter hour), the car
and the price, Charge now, Pause, Back to the plan and the mode, and
complications. watchOS 26 is the minimum. watchOS gives an ordinary app no
WebSocket (TN3135), so in W1 the watch reads and commands through the iPhone
(`WatchBridge`, WatchConnectivity); FTW Cloud never controls. The app is
built to stand alone (`WKRunsIndependentlyOfCompanionApp`): it opens on its
own cache, makes its own key and its own `cmdId`, and reads and sends
through two seams, `ReadPath` and `CommandPath`. `PhonePath` is the only
path now; FTW Cloud reads and the relay's exchange (ADR 0009) come later.
An unlocked watch on the wrist counts as unlocked for commands.

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
  state (M5, or FTW Cloud C3), the chargers are read when someone starts
  looking and the last read is over a minute old, after a command, and
  when the stream says the car started or stopped drawing. The plan's
  shortfall is read when the car view opens and when the car's plan
  changes.
- **Ask by the data's age.** `LiveAsk` names what it wants by how old the
  data is (the five minutes, the quarter, the day) and keeps an answer
  while that name holds. A view appearing or a redial asks only when the
  answer is older than its time to live. Reads wait for the box's one API
  slot in `ReadOrder`: chargers, prefs, plan, status, the rest.
- **A frame redraws what moved.** Small views that read only what they
  show, value inputs, and `Equatable` with `.equatable()` where a frame
  would otherwise redraw a whole section. A clock on screen ticks by the
  minute unless the second matters.
- **Modern Swift.** Swift 6 strict concurrency, `@Observable`,
  async/await and structured concurrency. No Combine, no GCD, no
  `ObservableObject`, and no UIKit except the camera. Colours live in
  one asset catalog, not in code (see The look).
- **iOS 26's design.** System components (`List`, `Form`,
  `NavigationStack`, system button styles), so Liquid Glass appears where
  the system puts it. SF Symbols with symbol effects.
- **Feel.** Data glides in and never jumps. Numbers change with
  `.contentTransition(.numericText(value:))`, new points animate in, and
  everything that moves uses one spring, `Theme.spring`. The car row on
  Now zooms into the car view (`navigationTransition(.zoom)`).
- **The flow moves at the display's rate** while Now is on screen in an
  active app. Under Reduce Motion it stops and a still arrow shows the
  direction; in Low Power Mode it drops to 20 fps. The live curve glides
  over each second, except under Reduce Motion or in Low Power Mode.
- **No layout jumps.** Reserve room for receipts, labels and pending
  marks, so a row never moves under the finger. Freshness and state
  changes cross-fade, and a transition can be interrupted.
- **Gaps in a time series.** Points sit on a fixed grid, each with a
  stable identity. A gap being fetched shows as a faint band, "fetching…"
  and a dashed estimate, never as a value. When the data comes it
  replaces the estimate and grows into shape (spring response 0.55,
  damping 0.72, 6–10 ms stagger per point). A gap the box confirms as
  empty stays a visible break. Lines use `.monotone`, so they invent no
  peaks. Under Reduce Motion the data shows at once. Animate only what
  changed, and compute the points once per change.
- **The live trace joins short silences** (Fredrik, 14 Oct 2026). A
  silence up to three of the device's own read periods is joined; only a
  longer one, or one the box confirms empty, breaks the line, and no
  "no data" ever sits over a joined span. What this phone did not see
  live is drawn in ink on the same curve. No dot travels along a line.
- **Every chart takes a finger.** The point under it is marked, and the
  line under the chart says what was there. Two fingers give the span.
- **History sits small and grows** (Fredrik, 14 Oct 2026). A node's chart
  is compact, so the view never scrolls for it; a tap opens it on the
  whole screen, growing out of the small one. Chips add or take away
  series, kept per viewer; the last one stays, and a hidden series never
  changes what the others say.
- **One material for every power trace** (Fredrik, 14 Oct 2026). Live,
  Today and 48 h, small and enlarged, draw through `TraceInk` (band,
  body, line, glow only while live), `ChartAxes`, `LockOn` and
  `SlidingSurface` (a slide of 0.25 s, a spring of 0.35 s), and the hero
  follows the finger on each. Going from Live to Today changes the time,
  never the material. A new chart starts from these.
- **Charts draw on the engine.** Geometry is a value built once per data
  change (`FTWShared/Charts`, tested). A chart is one Canvas
  (`ChartSurface`) that never sees the finger and a small `ScrubOverlay`
  that alone redraws under it, reading a `ScrubModel`. About one point
  per 6 pt of width, and every stroke joins round (`ChartStrokeTests`).
  Widgets draw the same shapes as still paths.
- **Haptics are sparse.** `.selection` per slot while scrubbing, at most
  about 25 a second. `.impact(weight: .light)` at now, the edges of the
  cheapest window, the day's high and low, the car's goal and the ends of
  a range. Nothing on data updates.
- **A command answers at once.** Tap and "Sent" in under 100 ms, then the
  box's receipt (`cmd.ack`), then the outcome (`cmd.result`). The outcome
  alone plays a haptic, once: `.success`, `.warning` or `.error`. Show the
  intent at once; never show a result the box has not confirmed.
- **The largest text size and dark mode** look as good as the default.
  Review all three in the simulator.
- **Evidence for feel work:** a screen recording, and an Animation Hitches
  measurement from a device.

## The look: Phosphor

Fredrik chose this look for the polish release on 13 Oct 2026. Read it
before you change a colour, a font or a mark.

His standing rules from that day outlive the release:

1. The phone keeps its own cache of the whole home and opens on it. FTW
   Cloud only speeds things up and holds state; the app works when the
   cloud is gone. Robust, fast, smooth.
2. The fastest live path wins. Which path does not matter, only that it is
   fast. Push, never poll.
3. Freshness has no ticking seconds. A quiet mark says live the moment you
   lift the phone: light means live.
4. "FTW in control" is a small mark: green when FTW controls, a warning
   when it does not. One tap gives the full detail, as the box's own page
   does. Never a big banner.
5. Charts are never angular and never hairlines; they have volume. On/off
   loads (0 ↔ 1 kW) draw as bucket means with a range, and the scrub still
   gives exact values.
6. The flow on Now is small and smooth: continuous light, not jumping dots.
7. TUI and retro are welcome, never bloated: Swedish simplicity.

The rules below put these into practice.

- **Light means live.** Only a reading the box has confirmed live glows or
  moves: a live carrier (relay, WebRTC or graded-live FTW Cloud) and
  `srcState` live. The cache, the past, the plan and a quiet stream are
  ink and hold still. Light mode has no glow; motion and full colour alone
  say live. Every glow call takes `isLive`, and a test proves that a cache
  never glows.
- **Three tenses, one grammar.** A glowing line is now. A solid line with a
  filled body is what the box measured. A ghost (low fill, thin cap, dashed
  line) is what it plans or forecasts. A hatch means "on its way"; a dotted
  baseline means the box confirms nothing was there. Bars only where a
  value holds across its slot (price, plan). No other marks.
- **Colour is energy; the interface is ink.** One hue per kind: `solar`;
  the battery's `gives` (gold) and `stores` (cyan); `grid`, magenta both
  ways, where the side of zero and the word say buying or selling; `car`
  (violet). The home is ink. `live` and `alarm` are states, never levels.
  A price is ink by its level, never red and green. No orange anywhere;
  the system tint is ink.
- **Space, not boxes.** No cards and no borders: 24 to 32 pt between
  groups, and a hairline only where two lists meet. `Card` keeps its
  spacing and draws nothing.
- **Type.** Figures are SF Pro with even digits (`Theme.figure`), never
  mono. `Theme.mono` (SF Mono) is the terminal layer alone: the status
  line, kickers, axis labels, footers, receipts and the scrub tag. Sizes
  follow Dynamic Type; mono caps stop growing at accessibility1.
- **Six TUI details, no more.** A pull request that adds a seventh names
  the reading it carries, or it goes. Out: scanlines, glitch, grain,
  braille dots, typed-in text and any pulsing icon.

  | Detail | Where | The reading it carries |
  |---|---|---|
  | Mono status line, `● LIVE · FTW IN CONTROL` | Under every title | Whether this is now, and who controls the home |
  | 8-level block price bars (▁▂▃▄▅▆▇█) | Now's strip, dial ticks, lock-screen widget | Price per slot at a glance |
  | Lock-on: corner brackets and an inverse-video tag | Under a finger, on a pressed node | What the finger is on, and its value |
  | 10-cell meter | Battery and car level | Level in tenths, readable at 4 pt |
  | Receipt log `SENT ▸ ACCEPTED ▸ MEASURED ▸ CONFIRMED` | Car commands | How far the box has confirmed a command |
  | Phosphor ignite and decay | Beams, the trace's head, the status dot | When live starts and when it stops |

- **One palette source.** The roles live in `appleApp/FTWCharts/Theme.xcassets`,
  in Display P3, one colour set per role with its dark variant: `ground`,
  `raised`, `hairline`; `ink`, `ink2`, `ink3`; `solar`, `gives`, `stores`,
  `grid`, `car`; `live`, `alarm`. The app and the widgets both build that
  folder, and `Theme` in `FTWCharts/Palette.swift` names them for both.
  `ThemeTests` holds the contrast (text 4.5:1 on ground and raised; energy
  4.5:1 in light and 7:1 in dark) and fails on any colour written in code.
  Increase Contrast turns ink3 into ink2 and hairlines into 2 px; Reduce
  Transparency drops the glow. watchOS compiles no dark appearance and a
  watch is always dark, so each set also has a `watch` variant that equals
  its dark one; `ThemeTests` holds them equal.
- **Widgets and the Live Activity** are the app's material, held still.
  They read the same roles and draw the same geometry as still paths,
  never a Canvas or Swift Charts. They never glow and always say when:
  `AS OF 13:05`, `PLANNED 16:45`, `kl 16:55`. Grid today is one signed
  line with its body, as the grid's Today. The lock screen writes the price
  as block glyphs from `PriceBlocks`. Tinted and clear home screens draw in
  `.primary`, with the line or the now bar marked `.widgetAccentable()`.
- **The receipt log** (`ReceiptLog`, drawn by `ReceiptRow`) keeps four
  slots on one line and lights each on its own evidence: SENT on the local
  send, ACCEPTED on `cmd.ack`, MEASURED once the box has the command and
  lane 0 shows what it asked for while live (the car above 42 W for
  Charge now), CONFIRMED on `cmd.result`. A refusal takes the last slot in
  alarm red, with the box's reason.
- The 0.3 names in `FTW/UI/Theme.swift` (`fg`, `surface`, `accent` and the
  rest) point at these roles until each screen is rebuilt. New code reads
  the roles.
- The app's palette leaves the web tokens (`ftw-webapp/src/styles/tokens.css`
  and the box's `theme.css`) for now. The role names stay, so the web and
  the box can follow in paired PRs.

## Design references

Borrow patterns from the best iOS apps, and from terminals and instruments,
never their graphics or brands.

| Pattern | From | Where in FTW |
|---|---|---|
| Scrub a chart: the header gives way to the value under the finger, and comes back on release | Stocks | Every chart: price, node history, ahead |
| Hourly strip with a now marker | Weather | Now's plan strip, the price chart |
| A level that fills with a spring, one hue per kind | Fitness | Battery and car levels, as the 10-cell meter |
| Big state, three fixed controls, receipt under them | Tesla, Rivian | The car view's Plan · Charge now · Pause bar and its receipt log |
| A plain "what happens next" timeline with times | Flighty | Now's plan sentence, plan view, plan widget |
| Price as bars by level, with the cheap window marked | Tibber, Octopus | Price chart: ink bars by thirds and a cheapest bracket, never red and green |
| Calm lists, one prominent action, a quiet second one | Things, Apple Home | Pairing, mode sheet |
| Liquid Glass only where the system puts it (bars, sheets, buttons) | iOS 26 | Toolbars, sheets, glass buttons; no custom glass panels |
| A trace that burns at its head and fades when the signal stops | Oscilloscopes, CRT terminals | Beams on Now, the live trace, the status dot |
| One mono status line, and an inverse-video tag for what is selected | Terminal tools | The status line under each title, the scrub tag |

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
pixel. `appleApp/FTWWidgets` owns the widgets. `appleApp/FTWWatch` is the
watch app, `FTWWatchWidgets` its complications and `FTWWatchShared` what
both draw (the dial). The watch links `FTWShared` and `FTWCharts`, never
FTWKit. What the phone and the watch say to each other lives in
`FTWShared/Watch/`, and the phone's side of it in `FTWKit`'s `WatchShare`. Keep logic out of views: if a
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
