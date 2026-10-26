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
On a box that lists `der.car` (docs/cars.md in srcfl/ftw) the car is its
own entity: the app reads `GET /api/cars`, draws the car before the
charger, sets its level and goal with `car.soc.set` and `car.goal.set`, and
answers "Which car?" with `session.car.set`. A box without `der.car` keeps
the charger view.
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
and the price, Charge now, Pause and Back to the plan, and complications.
The watch shows how the home is run but does not change it: the mode and
the planning style change in Plan on the iPhone alone (Fredrik, 25 October
2026). watchOS 26 is the minimum. watchOS gives an ordinary app no
WebSocket (TN3135), so the watch reads and commands through the iPhone
(`WatchBridge`, WatchConnectivity) when it can. The app stands alone
(`WKRunsIndependentlyOfCompanionApp`): it opens on its own cache, makes its
own key and its own `cmdId`, and reads and sends through two seams,
`ReadPath` and `CommandPath`. `PathChooser` puts `PhonePath` and
`CloudPath` behind them: with the phone away the watch reads FTW Cloud's
copy and sends charger commands through the box's exchange, each one
HTTPS request (srcfl/ftw ADR 0009, "Through FTW Cloud"). Their rules
live in the package with tests: `WatchRoute` (FTWShared) picks the path,
and `WatchCommander` (FTWWire) runs a command through FTW Cloud. An owner's phone
adds the watch to the box by its key first (`WatchAccess`). FTW Cloud
carries the exchange and reads none of it; the box decides. "Which car?"
goes through the phone alone. An unlocked watch on the wrist
counts as unlocked for commands.

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
- **No timer loops.** Lane 0 drives Now. The box pushes its plan, with
  each charger's windows, cable and shortfall, whenever it replans, and Now,
  the plan, the car view and the watch redraw from that push. The chargers
  are read when someone starts looking and the last read is over a minute
  old, after a command, when the stream says the car started or stopped
  drawing, when FTW Cloud or a pushed plan says a cable went in or out, and
  when a pushed plan says a goal changed elsewhere.
  A box whose plan comes without chargers pushes none: its chargers are also
  read each quarter while a car is plugged in and every 15 s while its plan
  is being made or for a minute after a cable moved, and its shortfall
  when the car view opens and when the car's plan changes.
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
- **The flow is a ring of light** (Ring / Quiet, chosen by Fredrik on 24
  Oct 2026 from the design canvas; it replaces the beams of 13 Oct). The
  home's use sits in the middle; each node has the quarter of the ring
  that faces its corner. Its arc lights from the quarter's middle out,
  longer with more power (`Flow.ringFill`: a fifth at 0.6 kW, half at
  1.8 kW, nine tenths at 6 kW, never past the quarter), in the node's
  colour, and a soft wave of light runs along it, faster with more power:
  clockwise for power coming into the home, the other way for power
  leaving it (`Flow.RingMotion` over `Flow.BeamMotion`, tested). The light
  runs at the display's rate while an arc is live and Now is on screen in
  an active app, ignites on the first live frame and decays when live
  ends, and the arc's colour crosses to ink as it cools; otherwise the
  timeline rests. Under Reduce Motion it holds still and a still chevron
  on the arc shows the direction; in Low Power Mode it drops to 20 fps. A
  node at 42 W or less lights nothing; only its quarter's track shows.
  The corner labels sit as close to the ring as clears it by 10 pt
  (`RingGeometry`), and the car's goal and level are one row under it.
  The live curve glides over each second, except under Reduce Motion or
  in Low Power Mode.
- **Four tabs** (Ring / Quiet step 3, 24 Oct 2026), the system's
  `TabView`: Now, Plan, History and Home (`HomeTab`). Each keeps its own
  stack, and a second tap on a tab takes it to its top. History tells
  today: the savings, then a row per node with its energy in words and
  its day drawn midnight to midnight on one shared axis, each into that
  node's view on Today. Home holds what the title's menu and the
  settings sheet held: the cars, assistants, the watch, the homes, this
  phone and About. Now's title is the home's name and opens nothing. The
  mode and the planning style change in Plan alone (Fredrik, 25 October
  2026): its mode row opens the mode sheet, and its scale runs from
  Careful to Bold.
  In their own views the battery's and the car's levels are rings
  (`LevelRing`): lit clockwise from twelve to the level, in the node's
  colour only while live (the car's level is a fact, violet without
  glow, ink when FTW assumes it), with the car's goal as a mark across
  the ring. The car view opens on the large one; the node views carry a
  small one beside the figure.
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
- **A node has one timeline** (Fredrik, 18 and 24 Oct 2026). No
  Live/Today/48 h/Ahead picker. It opens on today, midnight to midnight
  on the household's clock, from the phone's cached box history; the live
  readings build on that history at now, and the box's plan or forecast
  carries on after it. Drag to move through time (two days back, one
  ahead), pinch around the fingers to zoom (5 min to 72 h), and hold to
  read: the finger runs on across now into the plan. A window with now in
  it follows now, so a view pinched in on the last minutes is live; one
  dragged off now stays put while data lands; "Today" goes back. Under it,
  two lines: what the window shows ("Today", "Yesterday 18:00 – Today
  06:00") and what its past adds up to. Compact and enlarged share it,
  and the car view draws the car on it too, opening on the six hours
  behind and eighteen ahead, since the night's charge is the point there.
- **Keep the evidence distinct.** Closed history means keep the interval
  the box returned; the car's ledger means stay hourly. An unfinished bucket is not
  instantaneous power: wait for it to close, with actual source readings
  drawn beside the stored past. A lone live point hides no history, source
  silences and confirmed history holes stay open, and fetched means never
  become synthetic second-by-second values. Only a fresh observed head
  glows. A forecast stays dashed and a plan stays ghost bars after now.
- **Visible energy follows visible time.** Sum only closed recorded
  intervals in the shown past; never add live and forecast energy to it.
  A cut through a stored interval is an estimate, and missing or unfinished
  time is explicit. A held point names its source granularity.
- **History sits small and grows.** A node's chart is compact; a tap opens
  it on the whole screen. Chips keep the chosen series per viewer; the
  last one stays, and a hidden series changes no other series' values.
- **One material for every power trace.** The node timeline uses
  `TraceInk`, `ChartAxes` and `LockOn`. Other charts keep their own scrub
  and two-finger span where those describe the data they show.
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
- **The app opens dark** (Fredrik, 26 Oct 2026). Home's Appearance row
  picks Light or Match iPhone, kept on this phone; the launch screen is
  dark in both looks to match. The widgets and the watch follow the
  iPhone. **The largest text size and light mode** look as good as the
  default: review all three in the simulator, with `-appearance light`
  (or `system`) as a launch argument. The screenshot scripts pass
  `-appearance system`, so the simulator's look applies.
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
   Since 24 Oct 2026 it is the ring (Ring / Quiet).
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
  | 10-cell meter | A grid phase against its fuse | Share in tenths, readable at 4 pt |
  | Receipt log `SENT ▸ ACCEPTED ▸ MEASURED ▸ CONFIRMED` | Car commands | How far the box has confirmed a command |
  | Phosphor ignite and decay | The ring's arcs, the trace's head, the status dot | When live starts and when it stops |

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
| A level that fills with a spring, one hue per kind | Fitness | Battery and car levels, as a ring (`LevelRing`) with the car's goal marked |
| Big state, three fixed controls, receipt under them | Tesla, Rivian | The car view's Plan · Charge now · Pause bar and its receipt log |
| A plain "what happens next" timeline with times | Flighty | Now's plan sentence, plan view, plan widget |
| Price as bars by level, with the cheap window marked | Tibber, Octopus | Price chart: ink bars by thirds and a cheapest bracket, never red and green |
| Calm lists, one prominent action, a quiet second one | Things, Apple Home | Pairing, mode sheet |
| A control with a few stops: a tick at each, one command when the finger lets go | Camera's zoom control | The planning style scale, in the mode sheet and under the plan |
| Liquid Glass only where the system puts it (bars, sheets, buttons) | iOS 26 | Toolbars, sheets, glass buttons; no custom glass panels |
| A trace that burns at its head and fades when the signal stops | Oscilloscopes, CRT terminals | Beams on Now, the live trace, the status dot |
| One mono status line, and an inverse-video tag for what is selected | Terminal tools | The status line under each title, the scrub tag |

### Plan dial

FTW's own form, from Fredrik's film (srcfl/sourceful-films,
`product/ftw-confirmed`). His rules, as he settled them on 2026-10-13:

1. One turn is the next 24 hours. Midnight sits at the bottom and noon at
   the top, so the day's light fills the upper half. It never reads as a
   12-hour clock.
2. One tick per quarter hour, as long as the price in eight levels. Its
   colour is what the plan does with the battery: `Theme.stores` stores,
   `Theme.ink` gives power, `Theme.ink3` waits. On the dial, gold is the
   sun's and never the battery's.
3. A dotted arc in `Theme.car` marks when the car charges, with its goal
   at the end.
4. A hand marks now. A 2° gap in the rim marks the seam where +24 h meets
   now, and the ticks fade toward it.
5. Never a tick without a price: a quarter the market has not priced is a
   stub.
6. The sun's arc on the rim comes from the box's own solar forecast, never
   from astronomy or the phone's location. No forecast, no arc.
7. The middle holds the time and the price, and a third line kept for
   what the plan does under a finger. No battery ring and no glass disc in
   the app; the widget keeps a dark ground so it reads on any wallpaper.

`FTWShared/Charts/PlanDial.swift` holds the quarters, the sun, the words
and the rule for a finger; `FTWCharts/PlanDialFace.swift` draws. The
phone's plan view, its `energy.ftw.plan-dial` widget (StandBy small and
the lock screen's circle), the watch app and the watch's complication all
draw that one face. The plan view opens on the dial; the lanes are one
tap away in the toolbar, and the phone keeps the viewer's choice. A drag
round the ring costs one lookup per event, and only a change of quarter
redraws, and then only the hand and the middle. Now keeps its straight
strip, with gold for the battery giving power.

## Non-negotiable invariants

- **Never fake live.** Every reading carries its age.
- **Freshness is two fields.** `carrier` (tunnel, relay, cloud, cache,
  none) and `srcState` (live, lagging, stale, down, never) stay orthogonal.
- **The app expresses intent; the box decides.**
- **Positive watts flow into the site, negative out.** The UI never shows a
  raw minus sign.
- **Lane 0 frames are byte-identical in length.** A test enforces this.
  Over the relay they also keep a constant cadence. Through FTW Cloud the
  box sends each reading as it lands, and a beat once per subscribed
  period when nothing moves, so nothing may assume one frame a second.
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

On iPhone, one Swift package in `appleApp/FTWKit` holds four modules:

- `FTWKit` owns everything that is not a pixel: enrollment parse,
  rendezvous handles, the tunnel, relay and Noise carriers, the session,
  vault wrap/unwrap and the state each screen reads. The app alone links
  it. It writes the App Group cache, and re-exports `FTWWire`.
- `FTWWire` is the wire the phone and the watch both speak: Noise IK,
  frames, CBOR, the app protocol's messages and history chunks, FTW
  Cloud's envelopes, tiles and freshness rules (`CloudView`), the
  one-shot request and the box's
  exchange, and what one read of FTW Cloud becomes on the wrist
  (`WatchCloud`). No state, no main actor.
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
both draw (the dial). The watch links `FTWShared`, `FTWWire` and
`FTWCharts`, never FTWKit. What the phone and the watch say to each other lives in
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
FTWWire uses CryptoKit.

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
