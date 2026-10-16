# Se fördelningen — iOS design study

A native SwiftUI prototype of the reviewed energy-field design, with robot B.
It runs only in a Debug build on the iOS Simulator. It has its own local
state. It does not launch the real session, read a saved home, pair a box,
send commands, request camera access or register notifications.

## Run

Open `FTW.xcodeproj`, choose **FTW Distribution** and an iPhone simulator,
then Run. The material uses Metal; if Xcode has no Metal compiler, install
Apple’s component with `xcodebuild -downloadComponent MetalToolchain`.
Or, from this folder:

```sh
scripts/distribution-demo.sh
```

The script uses a separate simulator named **FTW Fördelning B**. An optional
first argument selects another simulator by its UDID. Xcode 27 calls its
simulator window Device Hub; the script also supports Simulator.app.

The standard FTW scheme keeps its existing entry screen. The design scheme
passes `-FTWDistributionDemo YES`. This flag has no effect in a Release
build or on a physical phone. `-FTWDistributionScreen car` opens a screen
for review. `-FTWDistributionScenario offline` selects a sample state.

## Try

- Drag anywhere in the material. Nearby colors stretch together and the
  light bends around the actual contact patch. Release to let it spring back.
  Tap a reading to open its detail view.
- Grab robot B and carry it through the site. All five light paths follow;
  the grid boundary remains fixed. Release to give it momentum and let it
  return. A new grip starts at its current position, even during the return.
  A tap gives it a small upward nudge.
- Open the slider button in the navigation bar to change the sample home,
  play a finite sequence, or start at pairing.
- Use Nu, Plan, Historik and Hemmet to review all 21 screens. The settings
  and sharing views are local examples; the displayed code cannot pair.
- Drag sideways across a detail header. Its fold stretches with the robot
  and returns with a spring, without changing a reading or goal. Vertical
  swipes still scroll the page.
- Drag directly across the plan, prices and power history. There is no
  separate scrub slider. The colored fold, readout and selected-time marker
  follow the finger. The plan has broad rounded volumes joined at zero;
  it does not invent narrow peaks between time slots.
  The plan and history hold still between touches. History's two fields show
  the source and use of energy; dragging changes the seam, not the totals.
- Follow robot B between tabs and detail views. One persistent robot travels
  between reserved places outside the navigation transitions. Its eyes keep
  moving through the journey; Reduce Motion changes its place at once.
- Open Hemmet, its settings, pairing, widgets and the goal sheet. They share
  the same soft seams, light and pressed controls. Forms keep native pickers,
  sliders and confirmation sheets. Widget previews remain still.
- Change the car's goal or level, pause it and return to its plan. The
  example confirms a command after showing sent and received. Old data and
  view-only access block these commands.
- The whole Now screen is one site. Sunlight grows into it as a warm field.
  Home, car and home battery share its material; the single grid throat
  crosses the site's boundary. Tap any of the five parts to open its view.
- Try Sol och köpt el, Köper från nätet and Kväll. The same grid connection
  reverses when buying or selling. The home battery stays in place when
  charging, discharging or idle, distinct from the car. The sun only supplies.
- L1, L2 and L3 belong to the grid connection. Their balanced example values
  derive from its signed net exchange at 230 V per phase. Home shows the
  load, excluding the separately shown car and battery charging.
- The home battery keeps its 68% stored level beside its signed kW figure.
  The words say whether it stores or supplies power. The other kW figures
  show present flow, not stored energy.

One GPU field blends every color across the screen. There is no enclosing
oval and no closed contour around an individual part. A shared height field
adds soft valleys, directional light and volume at the color boundaries. Power changes how far each
color reaches; it is a visual cue rather than an exact area chart. Solar
production spreads warmth and light through the whole field. The single grid
opening grows with the signed exchange and its light reverses with direction.
A grip changes no reading or control. Reduce Motion holds the scene still
and removes the release spring; words and a still grid arrow retain direction.
Hidden screens, old data and an inactive app stop their timelines. Low Power
Mode uses 20 frames per second. Large text gets a full-size list of all five
parts below a visual overview.

Power balances at the site boundary. Solar generation, grid imports and
battery discharge supply the demand. Home, car, battery charging and grid
exports use that power. The only grid field remains visible even with no
exchange, and the battery remains visible even when idle.

The study combines the mobile and web mockup's scope. It does not expand the
shipping iPhone release scope. The existing Phosphor palette remains in
place; the study's colors and their dark variants have their own catalog.

Robot B's transparent shell came from the approved generated design in this
chat. Its eyes, gaze, blink and movement are separate native layers.

## Check

```sh
cd FTWKit && swift test
```

`EnergyPartitionTests` checks area conservation through transitions and
under touches at several positions. `EnergyStreamlineTests` checks clearance
around the finger, material carried with the grip and fixed endpoints.
`EnergySiteLayoutTests` checks the single reversible grid boundary, the fixed
battery position, solar direction and fixed endpoints when the robot moves.
`EnergySiteSpringTests` checks release velocity, settling and an interrupted
return. `EnergySiteMixTests` checks the relative color areas against the
readings, including large values and idle equipment. `DistributionTour` exercises navigation,
goals, command guards, drag-versus-tap and large text in the simulator.
Simulator recordings show the proposed feel; device performance and real
hardware control are outside this design study.
